// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

var products: [Product] = [.library(name: "NeutrinoCore", targets: ["NeutrinoCore"]),
    .executable(name: "NeutrinoReaderWorker", targets: ["NeutrinoReaderWorker"])]
var targets: [Target] = [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
    .target(name: "NeutrinoCore", dependencies: ["CSQLite"]),
    .testTarget(name: "NeutrinoCoreTests", dependencies: ["NeutrinoCore"]),
    .target(name: "NeutrinoReaderLogic", dependencies: ["NeutrinoCore"]),
    .executableTarget(name: "NeutrinoReaderWorker", dependencies: ["NeutrinoCore", "NeutrinoReaderLogic"]),
    .testTarget(name: "NeutrinoReaderTests", dependencies: ["NeutrinoCore", "NeutrinoReaderLogic"])
]
#if os(macOS)
products.append(.executable(name: "Neutrino", targets: ["NeutrinoApp"]))
products.append(.executable(name: "NeutrinoResourceMonitor", targets: ["NeutrinoResourceMonitor"]))
products.append(.executable(name: "NeutrinoMemoryMonitor", targets: ["NeutrinoMemoryMonitor"]))
products.append(.executable(name: "NeutrinoUpdater", targets: ["NeutrinoUpdater"]))
targets.append(.target(name: "NeutrinoDistribution", dependencies: ["NeutrinoCore"]))
targets.append(.executableTarget(name: "NeutrinoUpdater", dependencies: ["NeutrinoCore", "NeutrinoDistribution"]))
targets.append(.target(name: "NeutrinoResourcePlatform", dependencies: ["NeutrinoCore"]))
targets.append(.executableTarget(name: "NeutrinoResourceMonitor", dependencies: ["NeutrinoCore", "NeutrinoResourcePlatform"]))
targets.append(.executableTarget(name: "NeutrinoMemoryMonitor", dependencies: ["NeutrinoCore", "NeutrinoResourcePlatform"]))
targets.append(.target(name: "NeutrinoEngineABI", publicHeadersPath: "include",
    linkerSettings: [.linkedFramework("AppKit")]))
targets.append(.executableTarget(name: "NeutrinoApp", dependencies: ["NeutrinoCore", "NeutrinoEngineABI", "NeutrinoDistribution"],
    resources: [.copy("Resources")]))
targets.append(.testTarget(name: "NeutrinoAppTests", dependencies: ["NeutrinoApp"]))
#endif

let package = Package(name: "Neutrino", platforms: [.macOS(.v14)],
    products: products, targets: targets, swiftLanguageModes: [.v6])
