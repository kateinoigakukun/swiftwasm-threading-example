import wasi_pthread
import ChibiRay
import JavaScriptKit

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

func render(scene: Scene, ctx: JSObject, renderTime: JSObject, concurrency: Int) {

    var thread = pthread_t(bitPattern: 0)
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

    for work in works {
        let ret = pthread_create(&thread, nil, { ctx in
            print("Started thread work")
            let work = Unmanaged<Work>.fromOpaque(ctx!).takeUnretainedValue()
            work.run()
            return nil
        }, Unmanaged.passRetained(work).toOpaque())
        print("pthread_create: \(ret)")
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

    _ = renderButton.addEventListener!("click", JSClosure { _ in
        let concurrency = max(Int(concurrency.value.string!) ?? 1, 1)
        let ctx = canvas.getContext!("2d").object!
        render(scene: scene, ctx: ctx, renderTime: renderTime, concurrency: concurrency)
        return JSValue.undefined
    })
}

main()