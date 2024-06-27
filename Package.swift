// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Example",
    dependencies: [
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", revision: "0d39aa77cb97e12e3e843254f8d17d6451172a88"),
        .package(url: "https://github.com/kateinoigakukun/chibi-ray", revision: "c8cab621a3338dd2f8e817d3785362409d3b8cf1"),
    ],
    targets: [
        .executableTarget(
            name: "MyApp",
            dependencies: [
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
                .product(name: "ChibiRay", package: "chibi-ray"),
            ]
        ),
    ]
)
