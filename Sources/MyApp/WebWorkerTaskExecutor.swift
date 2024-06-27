import JavaScriptKit
import JavaScriptEventLoop
@preconcurrency import _CJavaScriptEventLoop
import Synchronization
import wasi_pthread

@_extern(c, "llvm.wasm.memory.atomic.notify")
fileprivate func _swift_stdlib_wake(on: UnsafePointer<UInt32>, count: UInt32) -> UInt32

@_extern(c, "llvm.wasm.memory.atomic.wait32")
fileprivate func _swift_stdlib_wait(
  on: UnsafePointer<UInt32>,
  expected: UInt32,
  timeout: Int64
) -> UInt32

public struct WebWorkerTaskExecutor {

    /// A job worker dedicated to a single Web Worker thread.
    private final class Worker: Sendable {
        enum State: UInt32, AtomicRepresentable {
            /// The worker is idle and waiting for a new job.
            case idle = 0
            /// The worker is processing a job.
            case running = 1
            /// The worker is terminated.
            case terminated = 2
        }
        let state: Atomic<State> = Atomic(.running)
        let jobQueue: Mutex<[UnownedJob]> = Mutex([])

        init() {}

        /// Enqueue a job to the worker.
        func enqueue(_ job: UnownedJob) {
            jobQueue.withLock { queue in
                queue.append(job)
            }

            // Wake up the worker to process a job.
            switch state.exchange(.running, ordering: .sequentiallyConsistent) {
            case .idle:
                wake()
            case .running: break
            case .terminated:
                preconditionFailure("The worker is already terminated and cannot accept new jobs.")
            }
        }

        /// Run the worker loop.
        ///
        /// NOTE: This function must be called from the worker thread.
        /// It will return when the worker is terminated.
        func run(executor: WebWorkerTaskExecutor.Executor) {
            while true {
                let job = jobQueue.withLock { queue -> UnownedJob? in
                    return queue.popLast()
                }
                if let job = job {
                    job.runSynchronously(
                        on: executor.asUnownedTaskExecutor()
                    )
                } else {
                    switch state.exchange(.idle, ordering: .sequentiallyConsistent) {
                    case .idle: continue // If it's already idle, continue the loop.
                    case .running: break
                    case .terminated: return
                    }
                    withUnsafePointer(to: state) { statePtr in
                        let rawPointer = UnsafeRawPointer(statePtr).assumingMemoryBound(to: UInt32.self)
                        // Wait for a new job to be enqueued.
                        // If a new job has been enqueued since the last pop check, it will wake up immediately.
                        // Otherwise, it will wait until a new job is enqueued.
                        _ = _swift_stdlib_wait(on: rawPointer, expected: State.idle.rawValue, timeout: -1)
                    }
                }
            }
        }

        /// Terminate the worker.
        func terminate() {
            switch state.exchange(.terminated, ordering: .sequentiallyConsistent) {
            case .idle:
                // Wake up the `run` loop to terminate the worker.
                wake()
            case .running:
                // The worker is running a job. It will terminate after the job is done.
                break
            case .terminated:
                // The worker is already terminated.
                return
            }
        }

        private func wake() {
            withUnsafePointer(to: state) { statePtr in
                let rawPointer = UnsafeRawPointer(statePtr).assumingMemoryBound(to: UInt32.self)
                _ = _swift_stdlib_wake(on: rawPointer, count: 1)
            }
        }
    }

    private final class Executor: TaskExecutor {
        private let numberOfThreads: Int
        private let workers: [Worker]
        private let roundRobinIndex: Mutex<Int> = Mutex(0)

        init(numberOfThreads: Int) {
            self.numberOfThreads = numberOfThreads
            var workers = [Worker]()
            for _ in 0..<numberOfThreads {
                let worker = Worker()
                workers.append(worker)
            }
            self.workers = workers
        }

        func start() {
            class Context: @unchecked Sendable {
                let executor: WebWorkerTaskExecutor.Executor
                let worker: Worker
                init(executor: WebWorkerTaskExecutor.Executor, worker: Worker) {
                    self.executor = executor
                    self.worker = worker
                }
            }
            for worker in workers {
                // NOTE: The context must be allocated on the heap because
                // `pthread_create` on WASI does not guarantee the thread is started
                // immediately. The context must be retained until the thread is started.
                let context = Context(executor: self, worker: worker)
                let ptr = Unmanaged.passRetained(context).toOpaque()
                let ret = pthread_create(nil, nil, { ptr in
                    let context = Unmanaged<Context>.fromOpaque(ptr!).takeRetainedValue()
                    context.worker.run(executor: context.executor)
                    return nil
                }, ptr)
                precondition(ret == 0, "Failed to create a thread")
            }
        }

        func terminate() {
            for worker in workers {
                worker.terminate()
            }
        }

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            roundRobinIndex.withLock { index in
                let worker = workers[index]
                worker.enqueue(job)
                index = (index + 1) % numberOfThreads
            }
        }
    }

    private let executor: Executor

    public init(numberOfThreads: Int) {
        self.executor = Executor(numberOfThreads: numberOfThreads)
    }

    /// Start child Web Worker threads.
    public func start() {
        executor.start()
    }

    /// Terminate child Web Worker threads.
    public func terminate() {
        executor.terminate()
    }

    private struct Installation {
        let swift_task_enqueueGlobal_hook_original: UnsafeMutableRawPointer?
        let task: UnsafeCurrentTask?
        let file: StaticString
        let line: UInt

        func restoreIfNeeded() {
            withUnsafeCurrentTask { currentTask in
                if let currentTask, let task, currentTask == task {
                    // Once we reached the end of the `withTaskExecutorPreference` block,
                    // the next continuation job will be enqueued to the global executor here.

                    // Write back the original hook
                    swift_task_enqueueGlobal_hook = swift_task_enqueueGlobal_hook_original
                }
            }
        }
    }

    private static let currentInstallation: Mutex<Installation?> = Mutex(nil)

    private func installHookIfNeeded(file: StaticString, line: UInt) -> Bool {
        let needGlobalExecutorHook = WebWorkerTaskExecutor.currentInstallation.withLock { installation in
            if let installation = installation {
                fatalError("""
                    WebWorkerTaskExecutor.withGlobalExecutor cannot be nested. \
                    It was already installed at \(installation.file):\(installation.line).
                """)
            }

            return withUnsafeCurrentTask { installingTask in
                let newInstallation = Installation(
                    swift_task_enqueueGlobal_hook_original: swift_task_enqueueGlobal_hook,
                    task: installingTask,
                    file: file,
                    line: line
                )
                installation = newInstallation
                // If the task doesn't have a parent preferred task executor, hook
                // the global executor to get back to the main thread.
                return installingTask?.unownedTaskExecutor == nil
            }
        }
        return needGlobalExecutorHook
    }

    public nonisolated(unsafe) func withGlobalExecutor<T>(
        _ body: () async throws -> T,
        file: StaticString = #fileID, line: UInt = #line
    ) async rethrows -> T {
        let needGlobalExecutorHook = installHookIfNeeded(file: file, line: line)

        typealias swift_task_enqueueGlobal_hook_Fn = @convention(thin) (UnownedJob, swift_task_enqueueGlobal_original) -> Void
        return try await withUnsafeCurrentTask { installedTask in
            return try await withTaskExecutorPreference(self.executor) {
                if needGlobalExecutorHook {
                    let swift_task_enqueueGlobal_hook_impl: swift_task_enqueueGlobal_hook_Fn = { job, _ in
                        WebWorkerTaskExecutor.currentInstallation.withLock { installation in
                            installation?.restoreIfNeeded()
                            installation = nil
                        }
                        // Notify the main thread to execute the job
                        let jobBitPattern = unsafeBitCast(job, to: UInt.self)
                        _ = JSObject.global.postMessage!(jobBitPattern)
                    }
                    swift_task_enqueueGlobal_hook = unsafeBitCast(swift_task_enqueueGlobal_hook_impl, to: UnsafeMutableRawPointer?.self)
                }
                return try await body()
            }
        }
    }
}

/// Enqueue a job scheduled from a Web Worker thread to the main thread.
/// This function is called when a job is enqueued from a Web Worker thread.
@_expose(wasm, "swjs_enqueue_main_job_from_worker")
func _swjs_enqueue_main_job_from_worker(_ job: UnownedJob) {
    JavaScriptEventLoop.shared.enqueue(ExecutorJob(job))
}
