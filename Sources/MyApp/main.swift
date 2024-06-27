import wasi_pthread
import ChibiRay
import JavaScriptKit
import Synchronization
import JavaScriptEventLoop
import _CJavaScriptEventLoop

JavaScriptEventLoop.installGlobalExecutor()

public final class WebWorkerTaskExecutor: TaskExecutor {

    private final class Worker: Sendable {
        let jobQueue: Mutex<[UnownedJob]> = Mutex([])

        init() {}

        func enqueue(_ job: UnownedJob) {
            jobQueue.withLock { queue in
                queue.append(job)
            }
        }

        func run(executor: WebWorkerTaskExecutor) {
            while true {
                let job = jobQueue.withLock { queue -> UnownedJob? in
                    return queue.popLast()
                }
                if let job = job {
                    job.runSynchronously(
                        on: executor.asUnownedTaskExecutor()
                    )
                }
            }
        }
    }

    private let numberOfThreads: Int
    private let workers: [Worker]
    private let roundRobinIndex: Mutex<Int> = Mutex(0)

    public init(numberOfThreads: Int) {
        self.numberOfThreads = numberOfThreads
        var workers = [Worker]()
        for _ in 0..<numberOfThreads {
            let worker = Worker()
            workers.append(worker)
        }
        self.workers = workers
    }

    public func start() {
        for worker in workers {
            class Context: Sendable {
                let executor: WebWorkerTaskExecutor
                let worker: Worker
                init(executor: WebWorkerTaskExecutor, worker: Worker) {
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
                return nil
            }, ptr)
            precondition(ret == 0, "Failed to create a thread")
        }
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        roundRobinIndex.withLock { index in
            workers[index].enqueue(job)
            index = (index + 1) % numberOfThreads
        }
    }

    private static var swift_task_enqueueGlobal_hook_original: UnsafeMutableRawPointer?

    public func withGlobalExecutor<T>(_ body: () async throws -> T) async rethrows -> T {
        typealias swift_task_enqueueGlobal_hook_Fn = @convention(thin) (UnownedJob, swift_task_enqueueGlobal_original) -> Void
        let needGlobalExecutorHook = withUnsafeCurrentTask { task in
            // If the task doesn't have a parent preferred task executor, hook
            // the global executor to get back to the main thread.
            return task?.unownedTaskExecutor == nil
        }

        return try await withTaskExecutorPreference(self) {
            if needGlobalExecutorHook {
                print("Hooking the global executor to get back to the main thread")
                WebWorkerTaskExecutor.swift_task_enqueueGlobal_hook_original = swift_task_enqueueGlobal_hook
                let swift_task_enqueueGlobal_hook_impl: swift_task_enqueueGlobal_hook_Fn = { job, _ in
                    let hasPreferredTaskExecutor = withUnsafeCurrentTask { task in
                        // If the task doesn't have a parent preferred task executor, hook
                        // the global executor to get back to the main thread.
                        return task?.unownedTaskExecutor == nil
                    }
                    print("hasPreferredTaskExecutor: \(hasPreferredTaskExecutor)")
                    swift_task_enqueueGlobal_hook = WebWorkerTaskExecutor.swift_task_enqueueGlobal_hook_original
                    WebWorkerTaskExecutor.swift_task_enqueueGlobal_hook_original = nil
                    print("Enqueueing a global job back to the main thread")
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

class Work {
    let scene: Scene
    let imageView: ImageView
    let yRange: CountableRange<Int>
    var done: Bool = false

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
        done = true
    }
}

func render(scene: Scene, ctx: JSObject, renderTime: JSObject, concurrency: Int, executor: WebWorkerTaskExecutor) async {

    let imageBuffer = UnsafeMutableBufferPointer<Color>.allocate(capacity: scene.width * scene.height)
    // Initialize the buffer with black color
    imageBuffer.initialize(repeating: .black)
    let imageView = ImageView(width: scene.width, height: scene.height, buffer: imageBuffer)

    let clock = ContinuousClock()
    let start = clock.now
    var works = [Work]()

    let yStride = scene.height / concurrency
    for i in 0..<concurrency {
        let yRange = i * yStride..<(i + 1) * yStride
        let work = Work(scene: scene, imageView: imageView, yRange: yRange)
        works.append(work)
    }
    // Remaining rows
    if scene.height % concurrency != 0 {
        let work = Work(scene: scene, imageView: imageView, yRange: (concurrency * yStride)..<scene.height)
        works.append(work)
    }

    var checkTimer: JSValue?
    checkTimer = JSObject.global.setInterval!(JSClosure { _ in
        print("Checking thread work...")
        renderInCanvas(ctx: ctx, image: imageView)
        let renderSceneDuration = clock.now - start
        renderTime.textContent = .string("Render time: \(renderSceneDuration)")

        let numberOfDoneWorks = works.filter { $0.done }.count
        if numberOfDoneWorks == works.count {
            print("All threads are done")
            _ = JSObject.global.clearInterval!(checkTimer!)
            checkTimer = nil
            imageBuffer.deallocate()
        } else {
            print("Some threads are still working (\(numberOfDoneWorks)/\(works.count))")
        }
        return .undefined
    }, 250)

    // await withTaskExecutorPreference(executor) {
    await executor.withGlobalExecutor {
        await withTaskGroup(of: Void.self) { group in
            for work in works {
                group.addTask {
                    work.run()
                }
            }

            for await _ in group {
                print("Work done")
            }
        }
        // await _MainActor.run {
        //     print("Am I on the main thread?")
        // }
    }
    print("All work done")
}

func getStackTrace(demangle: Bool = true) -> [String] {
    let stack = JSObject.global.eval!("new Error().stack").string!
    let lines: [Substring] = stack.split(separator: "\n")
    if !demangle {
        return lines.map { String($0) }
    }
    return lines.map { line -> String in
        let pattern = #/    at (\$s.+) (.+)/#
        guard let match = line.firstMatch(of: pattern) else {
            return String(line)
        }
        var mangledName = match.output.1
        let demangled = mangledName.withUTF8 { buffer -> String? in
            @_extern(c, "swift_demangle")
            func swift_demangle(
                _ mangledName: UnsafePointer<UInt8>, _ mangledNameLength: Int,
                _ outputBuffer: UnsafeMutablePointer<Int8>?, _ outputBufferSize: UnsafeMutablePointer<Int>?,
                _ flags: UInt32
            ) -> UnsafePointer<Int8>?
            guard let cString = swift_demangle(buffer.baseAddress!, buffer.count, nil, nil, 0) else {
                return nil
            }
            return String(cString: cString)
        }
        return "    at " + (demangled ?? String(mangledName)) + " " + match.output.2
    }
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
    print(getStackTrace().joined(separator: "\n"))

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
