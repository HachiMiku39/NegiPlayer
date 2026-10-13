// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NegiPlayer",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.executable(name: "NegiPlayer", targets: ["NegiPlayer"]), .executable(name:"LANConformanceHost", targets:["LANConformanceHost"]), .library(name: "LANCore", targets: ["LANCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "LibraryDomain"),
        .target(name: "LyricCore"),
        .target(name: "LANCore"),
        .target(name: "LANHost", dependencies: ["LANCore", "MediaIO", "LibraryDomain", "LyricCore"]),
        .target(name: "AudioCore", dependencies: ["LibraryDomain"]),
        .target(name: "LibraryStore", dependencies: ["CSQLite", "LibraryDomain", "LyricCore"]),
        .target(name: "MediaIO", dependencies: ["LibraryDomain", "LyricCore"]),
        .target(name: "FileOperations", dependencies: ["LibraryDomain"]),
        .executableTarget(name: "NegiPlayer", dependencies: ["LibraryDomain", "LibraryStore", "MediaIO", "AudioCore", "LyricCore", "LANHost", "LANCore"]),
        .executableTarget(name:"LANConformanceHost", dependencies:["LANCore","LANHost","MediaIO","LibraryDomain"]),
        .testTarget(name: "CoreTests", dependencies: ["LyricCore", "LibraryDomain", "LibraryStore", "MediaIO", "AudioCore", "FileOperations", "LANCore", "LANHost"])
    ],
    swiftLanguageModes: [.v5]
)
