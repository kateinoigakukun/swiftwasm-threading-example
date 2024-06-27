import wasi_pthread
import ChibiRay
import JavaScriptKit
import Synchronization
import JavaScriptEventLoop
import _CJavaScriptEventLoop

JavaScriptEventLoop.installGlobalExecutor()

@_extern(c, "llvm.wasm.memory.atomic.notify")
internal func _swift_stdlib_wake(on: UnsafePointer<UInt32>, count: UInt32) -> UInt32

@_extern(c, "llvm.wasm.memory.atomic.wait32")
internal func _swift_stdlib_wait(
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
                withUnsafePointer(to: state) { statePtr in
                    let rawPointer = UnsafeRawPointer(statePtr).assumingMemoryBound(to: UInt32.self)
                    _ = _swift_stdlib_wake(on: rawPointer, count: 1)
                }
            case .running: break
            }
        }

        /// Run the worker loop.
        ///
        /// NOTE: This function must be called from the worker thread, and it
        ///       will never return.
        func run(executor: WebWorkerTaskExecutor.Executor) -> Never {
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
            for worker in workers {
                class Context: @unchecked Sendable {
                    let executor: WebWorkerTaskExecutor.Executor
                    let worker: Worker
                    init(executor: WebWorkerTaskExecutor.Executor, worker: Worker) {
                        self.executor = executor
                        self.worker = worker
                    }
                }
                // NOTE: The context must be allocated on the heap because
                // `pthread_create` on WASI does not guarantee the thread is started
                // immediately. The context must be retained until the thread is started.
                let context = Context(executor: self, worker: worker)
                let ptr = Unmanaged.passRetained(context).toOpaque()
                let ret = pthread_create(nil, nil, { ptr in
                    let context = Unmanaged<Context>.fromOpaque(ptr!).takeRetainedValue()
                    context.worker.run(executor: context.executor)
                }, ptr)
                precondition(ret == 0, "Failed to create a thread")
            }
        }

        public func enqueue(_ job: consuming ExecutorJob) {
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

    public func start() {
        executor.start()
    }

    private static var swift_task_enqueueGlobal_hook_original: UnsafeMutableRawPointer?

    public func withGlobalExecutor<T>(_ body: () async throws -> T) async rethrows -> T {
        typealias swift_task_enqueueGlobal_hook_Fn = @convention(thin) (UnownedJob, swift_task_enqueueGlobal_original) -> Void
        let needGlobalExecutorHook = withUnsafeCurrentTask { task in
            // If the task doesn't have a parent preferred task executor, hook
            // the global executor to get back to the main thread.
            return task?.unownedTaskExecutor == nil && WebWorkerTaskExecutor.swift_task_enqueueGlobal_hook_original == nil
        }

        return try await withTaskExecutorPreference(self.executor) {
            if needGlobalExecutorHook {
                WebWorkerTaskExecutor.swift_task_enqueueGlobal_hook_original = swift_task_enqueueGlobal_hook
                let swift_task_enqueueGlobal_hook_impl: swift_task_enqueueGlobal_hook_Fn = { job, _ in
                    // Once we reached the end of the `withTaskExecutorPreference` block,
                    // the next continuation job will be enqueued to the global executor here.

                    // Write back the original hook
                    swift_task_enqueueGlobal_hook = WebWorkerTaskExecutor.swift_task_enqueueGlobal_hook_original
                    WebWorkerTaskExecutor.swift_task_enqueueGlobal_hook_original = nil
                    // Enqueue the job to the main thread instead of the current thread.
                    JavaScriptEventLoop.enqueueMainJob(ExecutorJob(job))
                }
                swift_task_enqueueGlobal_hook = unsafeBitCast(swift_task_enqueueGlobal_hook_impl, to: UnsafeMutableRawPointer?.self)
            }
            return try await body()
        }
    }
}

@_expose(wasm, "swjs_enqueue_main_job")
func swjs_enqueue_main_job(_ job: UnownedJob) {
    JavaScriptEventLoop.shared.enqueue(ExecutorJob(job))
}

func renderInCanvas(ctx: JSObject, image: ImageView) {
    let imageData = ctx.createImageData!(image.width, image.height).object!
    let data = imageData.data.object!
    
    for y in 0..<image.height {
        for x in 0..<image.width {
            let index = (y * image.width + x) * 4
            let pixel = image[x, y]
            data[index]     = .number(Double(pixel.red * 255))
            data[index + 1] = .number(Double(pixel.green * 255))
            data[index + 2] = .number(Double(pixel.blue * 255))
            data[index + 3] = .number(Double(255))
        }
    }
    _ = ctx.putImageData!(imageData, 0, 0)
}

struct ImageView {
    let width, height: Int
    let buffer: UnsafeMutableBufferPointer<Color>

    subscript(x: Int, y: Int) -> Color {
        get {
            return buffer[y * width + x]
        }
        nonmutating set {
            buffer[y * width + x] = newValue
        }
    }
}

struct Work {
    let scene: Scene
    let imageView: ImageView
    let yRange: CountableRange<Int>

    init(scene: Scene, imageView: ImageView, yRange: CountableRange<Int>) {
        self.scene = scene
        self.imageView = imageView
        self.yRange = yRange
    }
    func run() {
        for y in yRange {
            for x in 0..<scene.width {
                let ray = Ray.createPrime(x: x, y: y, scene: scene)
                let color = castRay(scene: scene, ray: ray, depth: 0)
                imageView[x, y] = color
            }
        }
    }
}

func render(scene: Scene, ctx: JSObject, renderTime: JSObject, concurrency: Int, executor: WebWorkerTaskExecutor) async {

    let imageBuffer = UnsafeMutableBufferPointer<Color>.allocate(capacity: scene.width * scene.height)
    // Initialize the buffer with black color
    imageBuffer.initialize(repeating: .black)
    let imageView = ImageView(width: scene.width, height: scene.height, buffer: imageBuffer)

    let clock = ContinuousClock()
    let start = clock.now

    var checkTimer: JSValue?
    checkTimer = JSObject.global.setInterval!(JSClosure { _ in
        print("Checking thread work...")
        renderInCanvas(ctx: ctx, image: imageView)
        let renderSceneDuration = clock.now - start
        renderTime.textContent = .string("Render time: \(renderSceneDuration)")
        return .undefined
    }, 250)

    await executor.withGlobalExecutor {
        await withTaskGroup(of: Void.self) { group in
            let yStride = scene.height / concurrency
            for i in 0..<concurrency {
                let yRange = i * yStride..<(i + 1) * yStride
                let work = Work(scene: scene, imageView: imageView, yRange: yRange)
                group.addTask { work.run() }
            }
            // Remaining rows
            if scene.height % concurrency != 0 {
                let work = Work(scene: scene, imageView: imageView, yRange: (concurrency * yStride)..<scene.height)
                group.addTask { work.run() }
            }
        }
    }
    _ = JSObject.global.clearInterval!(checkTimer!)
    checkTimer = nil

    renderInCanvas(ctx: ctx, image: imageView)
    imageBuffer.deallocate()
    print("All work done")
}

func main() {
    let canvas = JSObject.global.document.getElementById("canvas").object!
    let renderButton = JSObject.global.document.getElementById("render-button").object!
    let renderTime = JSObject.global.document.getElementById("render-time").object!
    let concurrency = JSObject.global.document.getElementById("concurrency").object!
    concurrency.value = JSObject.global.navigator.hardwareConcurrency
    let scene = createDemoScene()
    canvas.width  = .number(Double(scene.width))
    canvas.height = .number(Double(scene.height))

    _ = renderButton.addEventListener!("click", JSClosure { _ in
        Task {
            let concurrency = max(Int(concurrency.value.string!) ?? 1, 1)
            let ctx = canvas.getContext!("2d").object!
            let executor = WebWorkerTaskExecutor(numberOfThreads: concurrency)
            executor.start()
            await render(scene: scene, ctx: ctx, renderTime: renderTime, concurrency: concurrency, executor: executor)
            withExtendedLifetime(executor) { }
            print("Render done")
        }
        return JSValue.undefined
    })
}

main()
