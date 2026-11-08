// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NativePresentBench",
    platforms: [.iOS(.v17)],
    products: [.library(name: "NativePresentBench", targets: ["NativePresentBench"])],
    targets: [.target(name: "NativePresentBench", path: "App",
                      swiftSettings: [.swiftLanguageMode(.v5)])]
)
