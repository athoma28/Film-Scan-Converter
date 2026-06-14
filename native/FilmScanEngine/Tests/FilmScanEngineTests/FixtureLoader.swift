import CryptoKit
import Foundation
import Testing

@testable import FilmScanEngine

struct FixtureMetadata: Decodable {
  let stage: String
  let inputShape: [Int]
  let outputShape: [Int]
  let inputSHA256: String
  let outputSHA256: String
}

enum FixtureLoader {
  static func fixtureDirectory(_ name: String) -> URL {
    Bundle.module.resourceURL!
      .appending(path: "Fixtures")
      .appending(path: name)
  }

  static func fixtureURL(_ name: String, file: String) -> URL {
    fixtureDirectory(name)
      .appending(path: file)
  }

  static func loadExpected(_ name: String) throws -> UInt16Image {
    try loadNPY(fixtureURL(name, file: "expected.npy"))
  }

  static func loadCase(_ name: String) throws -> (
    input: UInt16Image,
    expected: UInt16Image,
    metadata: FixtureMetadata
  ) {
    let directory = fixtureDirectory(name)
    let input = try loadNPY(directory.appending(path: "input.npy"))
    let expected = try loadNPY(directory.appending(path: "expected.npy"))
    let metadata = try JSONDecoder().decode(
      FixtureMetadata.self,
      from: Data(contentsOf: directory.appending(path: "metadata.json"))
    )

    #expect(metadata.inputSHA256 == sha256(input.pixels))
    #expect(metadata.outputSHA256 == sha256(expected.pixels))
    return (input, expected, metadata)
  }

  static func loadFloat64Case(_ name: String) throws -> (
    input: [Double],
    expected: [Double],
    shape: [Int],
    metadata: FixtureMetadata
  ) {
    let directory = fixtureDirectory(name)
    let (input, inputShape) = try loadNPYFloat64(directory.appending(path: "input.npy"))
    let (expected, _) = try loadNPYFloat64(directory.appending(path: "expected.npy"))
    let metadata = try JSONDecoder().decode(
      FixtureMetadata.self,
      from: Data(contentsOf: directory.appending(path: "metadata.json"))
    )

    #expect(metadata.inputSHA256 == sha256Float64(input))
    #expect(metadata.outputSHA256 == sha256Float64(expected))
    return (input, expected, inputShape, metadata)
  }

  static func loadNPY(_ url: URL) throws -> UInt16Image {
    let (data, header, headerEnd) = try parseNPYHeader(url)
    guard header.contains("'descr': '<u2'") else {
      throw FixtureError.unsupportedNPYFormat
    }

    let shape = try parseShape(header)
    let height = shape[0]
    let width = shape[1]
    let channels = shape.count == 3 ? shape[2] : 1
    let expectedByteCount = height * width * channels * MemoryLayout<UInt16>.size
    guard data.count - headerEnd == expectedByteCount else {
      throw FixtureError.invalidPixelCount
    }

    var pixels = [UInt16](repeating: 0, count: height * width * channels)
    for index in pixels.indices {
      let byteIndex = headerEnd + index * 2
      pixels[index] = UInt16(data[byteIndex]) | (UInt16(data[byteIndex + 1]) << 8)
    }
    return UInt16Image(width: width, height: height, channels: channels, pixels: pixels)
  }

  private static func loadNPYFloat64(_ url: URL) throws -> ([Double], [Int]) {
    let (data, header, headerEnd) = try parseNPYHeader(url)
    guard header.contains("'descr': '<f8'") else {
      throw FixtureError.unsupportedNPYFormat
    }

    let shape = try parseShape(header)
    let elementCount = shape.reduce(1, *)
    let expectedByteCount = elementCount * MemoryLayout<Double>.size
    guard data.count - headerEnd == expectedByteCount else {
      throw FixtureError.invalidPixelCount
    }

    var values = [Double](repeating: 0, count: elementCount)
    _ = values.withUnsafeMutableBytes { bytes in
      data.copyBytes(to: bytes, from: headerEnd..<data.count)
    }
    return (values, shape)
  }

  private static func parseNPYHeader(_ url: URL) throws -> (Data, String, Int) {
    let data = try Data(contentsOf: url)
    guard data.count > 10, data.prefix(6) == Data([0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59]) else {
      throw FixtureError.invalidNPY
    }
    guard data[6] == 1 else {
      throw FixtureError.unsupportedNPYVersion
    }

    let headerLength = Int(data[8]) | (Int(data[9]) << 8)
    let headerEnd = 10 + headerLength
    guard headerEnd <= data.count,
      let header = String(data: data[10..<headerEnd], encoding: .ascii),
      header.contains("'fortran_order': False")
    else {
      throw FixtureError.unsupportedNPYFormat
    }
    return (data, header, headerEnd)
  }

  private static func parseShape(_ header: String) throws -> [Int] {
    let regex = try NSRegularExpression(pattern: #"'shape': \(([^)]*)\)"#)
    let range = NSRange(header.startIndex..<header.endIndex, in: header)
    guard let match = regex.firstMatch(in: header, range: range),
      let valuesRange = Range(match.range(at: 1), in: header)
    else {
      throw FixtureError.invalidShape
    }
    let shape = header[valuesRange]
      .split(separator: ",")
      .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard shape.count == 2 || shape.count == 3 else {
      throw FixtureError.invalidShape
    }
    return shape
  }

  private static func sha256(_ pixels: [UInt16]) -> String {
    var bytes = [UInt8]()
    bytes.reserveCapacity(pixels.count * 2)
    for pixel in pixels {
      bytes.append(UInt8(truncatingIfNeeded: pixel))
      bytes.append(UInt8(truncatingIfNeeded: pixel >> 8))
    }
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func sha256Float64(_ values: [Double]) -> String {
    values.withUnsafeBytes {
      SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
    }
  }
}

enum FixtureError: Error {
  case invalidNPY
  case unsupportedNPYVersion
  case unsupportedNPYFormat
  case invalidShape
  case invalidPixelCount
}
