// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "FilmScanEngine",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "FilmScanEngine", targets: ["FilmScanEngine"]),
    .executable(name: "FilmScanConverterMac", targets: ["FilmScanConverterMac"]),
    .executable(name: "FilmScanRawBenchmark", targets: ["FilmScanRawBenchmark"]),
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
    .executableTarget(
      name: "FilmScanRawBenchmark",
      dependencies: ["FilmScanEngine"]
    ),
    .executableTarget(
      name: "FilmScanConverterMac",
      dependencies: ["FilmScanEngine"],
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
      dependencies: ["FilmScanEngine"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
