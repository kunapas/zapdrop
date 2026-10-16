// swift-tools-version:5.10
//
// Ferry — copy photos, videos and files from an Android phone to a Mac over USB (MTP).
// This package is the source of truth for all code. See docs/ARCHITECTURE.md.
//
// Environment switches (read when the package is resolved):
//   FERRY_MOCK_ONLY=1       build without libmtp (UI development against the mock phone only)
//   FERRY_DEPS_PREFIX=/path prefix containing include/libmtp.h and lib/libmtp.dylib
//                           (default on macOS: Vendor/build/prefix, produced by Scripts/build-deps.sh)

import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let env = ProcessInfo.processInfo.environment
let mockOnly = env["FERRY_MOCK_ONLY"] == "1"

#if os(macOS)
let depsPrefix = env["FERRY_DEPS_PREFIX"] ?? "\(packageDir)/Vendor/build/prefix"
let shimCSettings: [CSetting] = [.unsafeFlags(["-I\(depsPrefix)/include"])]
let shimLinker: [LinkerSetting] = [
    .linkedLibrary("mtp"),
    .linkedLibrary("usb-1.0"),
    .unsafeFlags(["-L\(depsPrefix)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(depsPrefix)/lib"]),
]
#else
// Linux (CI and core development): distro packages libmtp-dev and libusb-1.0-0-dev, or a prefix built by
// Scripts/build-deps.sh when FERRY_DEPS_PREFIX is set.
let shimCSettings: [CSetting] = env["FERRY_DEPS_PREFIX"].map { [.unsafeFlags(["-I\($0)/include"])] } ?? []
let shimLinker: [LinkerSetting] = [.linkedLibrary("mtp"), .linkedLibrary("usb-1.0")]
    + (env["FERRY_DEPS_PREFIX"].map { [.unsafeFlags(["-L\($0)/lib", "-Xlinker", "-rpath", "-Xlinker", "\($0)/lib"])] } ?? [])
#endif

let strictConcurrency: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

var products: [Product] = [
    .library(name: "FerryCore", targets: ["FerryCore"]),
    .library(name: "FerryMock", targets: ["FerryMock"]),
    .library(name: "FerryAppModel", targets: ["FerryAppModel"]),
]

var targets: [Target] = [
    .target(name: "FerryCore", swiftSettings: strictConcurrency),
    .target(name: "FerryMock", dependencies: ["FerryCore"], swiftSettings: strictConcurrency),
    .target(name: "FerryAppModel", dependencies: ["FerryCore"], swiftSettings: strictConcurrency),
    .testTarget(name: "FerryCoreTests", dependencies: ["FerryCore", "FerryMock"], swiftSettings: strictConcurrency),
    .testTarget(name: "FerryAppModelTests", dependencies: ["FerryAppModel", "FerryCore", "FerryMock"], swiftSettings: strictConcurrency),
]

if !mockOnly {
    products.append(.library(name: "FerryLibMTP", targets: ["FerryLibMTP"]))
    targets += [
        .target(name: "CFerryMTP", cSettings: shimCSettings, linkerSettings: shimLinker),
        .target(name: "FerryLibMTP", dependencies: ["FerryCore", "CFerryMTP"], swiftSettings: strictConcurrency),
        .testTarget(name: "FerryLibMTPTests", dependencies: ["FerryLibMTP", "FerryCore"], swiftSettings: strictConcurrency),
    ]
}

#if os(macOS)
// The SwiftUI app. Built with Scripts/build-app.sh (Command Line Tools are enough) or via App/Ferry.xcodeproj.
var appDependencies: [Target.Dependency] = ["FerryCore", "FerryMock", "FerryAppModel"]
if !mockOnly { appDependencies.append("FerryLibMTP") }
targets.append(
    .executableTarget(
        name: "FerryApp",
        dependencies: appDependencies,
        path: "App/Ferry",
        swiftSettings: strictConcurrency,
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    )
)
products.append(.executable(name: "FerryApp", targets: ["FerryApp"]))
#endif

let package = Package(
    name: "Ferry",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
