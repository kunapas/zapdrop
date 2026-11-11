// swift-tools-version:5.10
//
// Zapdrop — copy photos, videos and files from an Android phone to a Mac over USB (MTP).
// This package is the source of truth for all code. See docs/ARCHITECTURE.md.
//
// Environment switches (read when the package is resolved):
//   ZAPDROP_MOCK_ONLY=1       build without libmtp (UI development against the mock phone only)
//   ZAPDROP_DEPS_PREFIX=/path prefix containing include/libmtp.h and lib/libmtp.dylib
//                           (default on macOS: Vendor/build/prefix, produced by Scripts/build-deps.sh)

import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let env = ProcessInfo.processInfo.environment
let mockOnly = env["ZAPDROP_MOCK_ONLY"] == "1"

#if os(macOS)
let depsPrefix = env["ZAPDROP_DEPS_PREFIX"] ?? "\(packageDir)/Vendor/build/prefix"
let shimCSettings: [CSetting] = [.unsafeFlags(["-I\(depsPrefix)/include"])]
let shimLinker: [LinkerSetting] = [
    .linkedLibrary("mtp"),
    .linkedLibrary("usb-1.0"),
    .unsafeFlags(["-L\(depsPrefix)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(depsPrefix)/lib"]),
]
#else
// Linux (CI and core development): distro packages libmtp-dev and libusb-1.0-0-dev, or a prefix built by
// Scripts/build-deps.sh when ZAPDROP_DEPS_PREFIX is set.
let shimCSettings: [CSetting] = env["ZAPDROP_DEPS_PREFIX"].map { [.unsafeFlags(["-I\($0)/include"])] } ?? []
let shimLinker: [LinkerSetting] = [.linkedLibrary("mtp"), .linkedLibrary("usb-1.0")]
    + (env["ZAPDROP_DEPS_PREFIX"].map { [.unsafeFlags(["-L\($0)/lib", "-Xlinker", "-rpath", "-Xlinker", "\($0)/lib"])] } ?? [])
#endif

let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
]

var products: [Product] = [
    .library(name: "ZapdropCore", targets: ["ZapdropCore"]),
    .library(name: "ZapdropMock", targets: ["ZapdropMock"]),
    .library(name: "ZapdropAppModel", targets: ["ZapdropAppModel"]),
]

var targets: [Target] = [
    .target(name: "ZapdropCore", swiftSettings: strictConcurrency),
    .target(name: "ZapdropMock", dependencies: ["ZapdropCore"], swiftSettings: strictConcurrency),
    .target(name: "ZapdropAppModel", dependencies: ["ZapdropCore"], swiftSettings: strictConcurrency),
    .testTarget(name: "ZapdropCoreTests", dependencies: ["ZapdropCore", "ZapdropMock"], swiftSettings: strictConcurrency),
    .testTarget(name: "ZapdropAppModelTests", dependencies: ["ZapdropAppModel", "ZapdropCore", "ZapdropMock"], swiftSettings: strictConcurrency),
    // Long-running stress and soak tests; skipped unless ZAPDROP_STRESS_TESTS=1 (docs/TESTING.md).
    .testTarget(name: "ZapdropStressTests", dependencies: ["ZapdropAppModel", "ZapdropCore", "ZapdropMock"], swiftSettings: strictConcurrency),
]

if !mockOnly {
    products.append(.library(name: "ZapdropLibMTP", targets: ["ZapdropLibMTP"]))
    targets += [
        .target(name: "CZapdropMTP", cSettings: shimCSettings, linkerSettings: shimLinker),
        .target(name: "ZapdropLibMTP", dependencies: ["ZapdropCore", "CZapdropMTP"], swiftSettings: strictConcurrency),
        .testTarget(name: "ZapdropLibMTPTests", dependencies: ["ZapdropLibMTP", "ZapdropCore"], swiftSettings: strictConcurrency),
    ]
}

#if os(macOS)
// The SwiftUI app. Built with Scripts/build-app.sh (Command Line Tools are enough) or via App/Zapdrop.xcodeproj.
var appDependencies: [Target.Dependency] = ["ZapdropCore", "ZapdropMock", "ZapdropAppModel"]
if !mockOnly { appDependencies.append("ZapdropLibMTP") }
targets.append(
    .executableTarget(
        name: "ZapdropApp",
        dependencies: appDependencies,
        path: "App/Zapdrop",
        exclude: ["AppIcon.icns"], // copied into the bundle by Scripts/build-app.sh (and by Xcode)
        swiftSettings: strictConcurrency,
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    )
)
products.append(.executable(name: "ZapdropApp", targets: ["ZapdropApp"]))
#endif

let package = Package(
    name: "Zapdrop",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
