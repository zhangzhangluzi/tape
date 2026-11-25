// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TapeChinese",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Tape", targets: ["Tape"])],
    dependencies: [.package(path: "Packages/TapeCore")],
    targets: [
        .executableTarget(
            name: "Tape",
            dependencies: [.product(name: "TapeCore", package: "TapeCore")],
            path: "Sources"
        ),
    ]
)
