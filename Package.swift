// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NegiPlayer",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.executable(name: "NegiPlayer", targets: ["NegiPlayer"]), .executable(name:"LANConformanceHost", targets:["LANConformanceHost"]), .executable(name:"SensMePCMStream", targets:["SensMePCMStream"]), .library(name: "LANCore", targets: ["LANCore"]), .library(name: "SensMeCore", targets: ["CSensMeCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "LibraryDomain"),
        .target(name: "LyricCore"),
        .target(name: "LANCore"),
        .target(name: "LANHost", dependencies: ["LANCore", "MediaIO", "LibraryDomain", "LyricCore"]),
        .target(name: "CDoPTransport", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "AudioCore", dependencies: ["LibraryDomain", "MediaIO", "CDoPTransport"]),
        .target(name: "LibraryStore", dependencies: ["CSQLite", "LibraryDomain", "LyricCore"]),
        .target(name: "MediaIO", dependencies: ["LibraryDomain", "LyricCore"]),
        .target(name: "FileOperations", dependencies: ["LibraryDomain"]),
        .target(name: "CSensMeCore", cSettings: [.define("NEGI_SENSME_SCALAR", .when(configuration: .release))]),
        .target(name: "MusicEnrichment", dependencies: ["LibraryDomain", "MediaIO", "CSensMeCore"]),
        .executableTarget(name: "NegiPlayer", dependencies: ["LibraryDomain", "LibraryStore", "MediaIO", "AudioCore", "LyricCore", "LANHost", "LANCore", "FileOperations", "MusicEnrichment"]),
        .executableTarget(name:"LANConformanceHost", dependencies:["LANCore","LANHost","MediaIO","LibraryDomain"]),
        .executableTarget(name:"SensMePCMStream", dependencies:["MusicEnrichment"]),
        .testTarget(name: "CoreTests", dependencies: ["LyricCore", "LibraryDomain", "LibraryStore", "MediaIO", "AudioCore", "CDoPTransport", "FileOperations", "LANCore", "LANHost", "MusicEnrichment", "CSensMeCore"], resources: [.copy("Fixtures/SensMeTonal.json"), .copy("Fixtures/SensMeBeatGrid.json"), .copy("Fixtures/SensMeSectionKey.json"), .copy("Fixtures/SensMeSimilarity.json"), .copy("Fixtures/SensMeCoarseSections.json"), .copy("Fixtures/SensMeChorus.json"),
                .copy("Fixtures/SensMeTempoSpectrum.json"),
                .copy("Fixtures/SensMeResultFeatures.json"), .copy("Fixtures/SensMeClassifiers.json"), .copy("Fixtures/SensMeEncoding.json"), .copy("Fixtures/SensMeAnalyzer.json"), .copy("Fixtures/SensMeChorusLikelihood.json"), .copy("Fixtures/SensMeDefaultBank.json")])
    ],
    swiftLanguageModes: [.v5]
)
