// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PyroWaveBench",
    platforms: [.iOS(.v17)],
    products: [.library(name: "PyroWaveBench", targets: ["PyroWaveBench"])],
    targets: [
        .target(name: "PyroWaveNative", path: ".",
                exclude: ["App", "README.md", "xtool.yml", "vendor/LICENSE", "vendor/UPSTREAM.md"],
                sources: ["Benchmark.mm", "Streaming.mm", "vendor/pyrowave_common.mm", "vendor/pyrowave_encoder.mm",
                          "vendor/pyrowave_decoder.mm", "vendor/pyrowave_bitstream.cpp"],
                publicHeadersPath: "include",
                cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("Metal"), .linkedFramework("Foundation"),
                                 .linkedFramework("IOSurface"), .linkedFramework("CoreVideo")]),
        .target(name: "PyroWaveBench", dependencies: ["PyroWaveNative"], path: "App",
                swiftSettings: [.swiftLanguageMode(.v5)])
    ],
    cxxLanguageStandard: .cxx14
)
