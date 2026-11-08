// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EternalMonitor",
    platforms: [.iOS(.v17)],
    products: [.library(name: "EternalMonitor", targets: ["EternalMonitor"])],
    dependencies: [.package(url: "https://github.com/alta/swift-opus.git", revision: "6f3cb6bd3ffed1fe5f06d00a962d5c191a50daf8")],
    targets: [
        .target(name: "PyroWaveNative", path: "PyroWaveBench",
                exclude: ["App", "Benchmark.mm", "README.md", "xtool.yml", "vendor/LICENSE", "vendor/UPSTREAM.md"],
                sources: ["Streaming.mm", "vendor/pyrowave_common.mm", "vendor/pyrowave_decoder.mm", "vendor/pyrowave_bitstream.cpp"],
                publicHeadersPath: "include", cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("Metal"), .linkedFramework("CoreVideo"), .linkedFramework("IOSurface")]),
        .target(name: "EternalMonitor", dependencies: ["PyroWaveNative", .product(name: "Copus", package: "swift-opus")],
                path: "EternalMonitor",
                exclude: ["Resources", "Info.plist", "PrivacyInfo.xcprivacy", "PyroWaveBridge.h", "Render/Shaders.metal"],
                swiftSettings: [.swiftLanguageMode(.v5)])
    ],
    cxxLanguageStandard: .cxx14
)
