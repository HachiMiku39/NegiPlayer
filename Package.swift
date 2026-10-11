// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NegiPlayer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NegiPlayer", targets: ["NegiPlayer"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "LibraryDomain"),
        .target(name: "LyricCore"),
        .target(name: "AudioCore", dependencies: ["LibraryDomain"]),
        .target(name: "LibraryStore", dependencies: ["CSQLite", "LibraryDomain", "LyricCore"]),
        .target(name: "MediaIO", dependencies: ["LibraryDomain", "LyricCore"]),
        .target(name: "FileOperations", dependencies: ["LibraryDomain"]),
        .executableTarget(name: "NegiPlayer", dependencies: ["LibraryDomain", "LibraryStore", "MediaIO", "AudioCore", "LyricCore"]),
        .testTarget(name: "CoreTests", dependencies: ["LyricCore", "LibraryDomain", "LibraryStore", "MediaIO", "AudioCore", "FileOperations"])
    ],
    swiftLanguageModes: [.v5]
)
