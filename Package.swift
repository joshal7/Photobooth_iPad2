// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "PhotoboothApp2",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "PhotoboothApp2",
            targets: ["PhotoboothApp2"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PhotoboothApp2",
            dependencies: [],
            path: "Sources"),
    ]
)
