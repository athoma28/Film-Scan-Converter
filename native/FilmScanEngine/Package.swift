// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "FilmScanEngine",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "FilmScanEngine", targets: ["FilmScanEngine"]),
    .library(name: "FilmScanPreviewRenderer", targets: ["FilmScanPreviewRenderer"]),
    .executable(name: "FilmScanConverterMac", targets: ["FilmScanConverterMac"]),
    .executable(name: "FilmScanRawBenchmark", targets: ["FilmScanRawBenchmark"]),
    .executable(name: "FilmScanAdjustmentBenchmark", targets: ["FilmScanAdjustmentBenchmark"]),
    .executable(name: "FilmScanPreviewComparator", targets: ["FilmScanPreviewComparator"]),
  ],
  targets: [
    .systemLibrary(
      name: "CLibRaw",
      pkgConfig: "libraw_r",
      providers: [.brew(["libraw"])]
    ),
    .target(
      name: "CLibRawShim",
      dependencies: ["CLibRaw"],
      publicHeadersPath: "include"
    ),
    .target(
      name: "FilmScanEngine",
      dependencies: ["CLibRawShim"]
    ),
    .target(
      name: "FilmScanPreviewRenderer",
      dependencies: ["FilmScanEngine"],
      swiftSettings: [
        .unsafeFlags(["-Xcc", "-DCI_SILENCE_GL_DEPRECATION"])
      ]
    ),
    .executableTarget(
      name: "FilmScanRawBenchmark",
      dependencies: ["FilmScanEngine"]
    ),
    .executableTarget(
      name: "FilmScanAdjustmentBenchmark",
      dependencies: ["FilmScanEngine", "FilmScanPreviewRenderer"]
    ),
    .executableTarget(
      name: "FilmScanPreviewComparator",
      dependencies: ["FilmScanEngine", "FilmScanPreviewRenderer"]
    ),
    .executableTarget(
      name: "FilmScanConverterMac",
      dependencies: ["FilmScanEngine", "FilmScanPreviewRenderer"],
      exclude: ["Info.plist"],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "Sources/FilmScanConverterMac/Info.plist",
        ])
      ]
    ),
    .testTarget(
      name: "FilmScanEngineTests",
      dependencies: ["FilmScanEngine", "FilmScanPreviewRenderer", "FilmScanConverterMac"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
