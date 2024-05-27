// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Example",
    dependencies: [
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", revision: "ea069824e205056292f6e50da995975477841432"),
        .package(url: "https://github.com/kateinoigakukun/chibi-ray", revision: "c8cab621a3338dd2f8e817d3785362409d3b8cf1"),
    ],
    targets: [
        .executableTarget(
            name: "MyApp",
            dependencies: [
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "ChibiRay", package: "chibi-ray"),
            ]
        ),
    ]
)
