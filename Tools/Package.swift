// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Tools",
    dependencies: [
        .package(url: "https://github.com/swiftwasm/WasmKit", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "Tools",
            dependencies: [
                .product(name: "WasmParser", package: "WasmKit"),
            ]
        ),
    ]
)
