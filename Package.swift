// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0
import PackageDescription
import Foundation

let rustLibraryPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build/rust").path

var products: [Product] = [.library(name: "NeutrinoCore", targets: ["NeutrinoCore"]),
    .executable(name: "NeutrinoReaderWorker", targets: ["NeutrinoReaderWorker"])]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
    .systemLibrary(name: "NeutrinoRust"),
    .target(name: "NeutrinoCore", dependencies: ["NeutrinoRust"],
        linkerSettings: [.unsafeFlags(["-L", rustLibraryPath])]),
    .testTarget(name: "NeutrinoCoreTests", dependencies: ["NeutrinoCore", "CSQLite"]),
    .target(name: "NeutrinoReaderLogic", dependencies: ["NeutrinoCore"]),
    .executableTarget(name: "NeutrinoReaderWorker", dependencies: ["NeutrinoCore", "NeutrinoReaderLogic"]),
    .testTarget(name: "NeutrinoReaderTests", dependencies: ["NeutrinoCore", "NeutrinoReaderLogic"])
]
#if os(macOS)
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"))
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
targets.append(.executableTarget(name: "NeutrinoApp", dependencies: ["NeutrinoCore", "NeutrinoEngineABI", "NeutrinoDistribution", "NeutrinoRust", .product(name:"Sparkle",package:"Sparkle")],
    resources: [.copy("Resources")],linkerSettings:[.unsafeFlags(["-Xlinker","-rpath","-Xlinker","@executable_path/../Frameworks"])]))
targets.append(.testTarget(name: "NeutrinoAppTests", dependencies: ["NeutrinoApp", "CSQLite"]))
#endif

let package = Package(name: "Neutrino", platforms: [.macOS(.v14)],
    products: products, dependencies: dependencies, targets: targets, swiftLanguageModes: [.v6])
