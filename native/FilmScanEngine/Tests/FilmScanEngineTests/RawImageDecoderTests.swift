import CryptoKit
import Foundation
import Testing

@testable import FilmScanEngine

private struct RawDecodeReference: Decodable {
  struct Entry: Decodable {
    let file: String
    let shape: [Int]
    let sha256: String
    let colorDescription: String
  }

  let entries: [Entry]
  let fullResolution: Entry
}

@Suite("LibRaw decoding")
struct RawImageDecoderTests {
  @Test("Representative RAF corpus matches RawPy reference pixels")
  func representativeRAFCorpus() throws {
    let reference = try JSONDecoder().decode(
      RawDecodeReference.self,
      from: Data(contentsOf: FixtureLoader.fixtureURL("", file: "raw_decode_reference.json"))
    )
    let rawDirectory = repositoryRoot.appending(path: "sample-raw")
    guard FileManager.default.fileExists(atPath: rawDirectory.path) else {
      return
    }

    for entry in reference.entries {
      let result = try RawImageDecoder.decode(rawDirectory.appending(path: entry.file))

      #expect([result.image.height, result.image.width, result.image.channels] == entry.shape)
      #expect(sha256(result.image.pixels) == entry.sha256)
      #expect(result.colorDescription == entry.colorDescription)
    }
  }

  @Test("Full-resolution RAF decode matches RawPy reference pixels")
  func fullResolutionRAF() throws {
    let reference = try loadReference()
    let rawDirectory = repositoryRoot.appending(path: "sample-raw")
    guard FileManager.default.fileExists(atPath: rawDirectory.path) else {
      return
    }

    let entry = reference.fullResolution
    let result = try RawImageDecoder.decode(
      rawDirectory.appending(path: entry.file),
      fullResolution: true
    )

    #expect([result.image.height, result.image.width, result.image.channels] == entry.shape)
    #expect(sha256(result.image.pixels) == entry.sha256)
    #expect(result.colorDescription == entry.colorDescription)
  }

  @Test("Standard images do not enter the RAW decoder")
  func rejectsStandardImageExtension() {
    #expect(throws: RawImageDecoderError.self) {
      try RawImageDecoder.decode(URL(fileURLWithPath: "/tmp/scan.png"))
    }
  }

  @Test("Missing RAW files report a LibRaw decode failure")
  func missingRAWFile() {
    #expect(throws: RawImageDecoderError.self) {
      try RawImageDecoder.decode(URL(fileURLWithPath: "/tmp/missing-film-scan.raf"))
    }
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func loadReference() throws -> RawDecodeReference {
    try JSONDecoder().decode(
      RawDecodeReference.self,
      from: Data(contentsOf: FixtureLoader.fixtureURL("", file: "raw_decode_reference.json"))
    )
  }

  private func sha256(_ pixels: [UInt16]) -> String {
    pixels.withUnsafeBytes {
      SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
    }
  }
}
