// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "local_inference_flutter",
    platforms: [
        // llamadart's floors: the engine cannot run below them.
        .iOS("16.4"),
        .macOS("14.0")
    ],
    products: [
        .library(name: "local-inference-flutter", targets: ["local_inference_flutter"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "local_inference_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
