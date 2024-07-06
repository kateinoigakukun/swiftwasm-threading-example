// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Example",
    dependencies: [
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", revision: "a4daecdede926f532cd7edfddb068ede1b6e26f2"), // branch: "yt/web-worker-executor"
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
