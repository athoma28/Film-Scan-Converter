import CoreGraphics
import Foundation
import ImageIO
import Testing

/// Inspects exported files the way a second macOS application would: ImageIO
/// metadata, ColorSync-backed ICC data, and `/usr/bin/sips`.
enum IndependentViewerInspection {
  struct NamedSRGBReport: Equatable, Sendable {
    let width: Int
    let height: Int
    let depth: Int
    let profileName: String
    let orientation: Int
  }

  static func inspectNamedSRGB(
    at url: URL,
    expectedWidth: Int,
    expectedHeight: Int,
    expectedDepth: Int
  ) throws -> NamedSRGBReport {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = try #require(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    let width = try intProperty(properties, kCGImagePropertyPixelWidth)
    let height = try intProperty(properties, kCGImagePropertyPixelHeight)
    let depth = try intProperty(properties, kCGImagePropertyDepth)
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let profileName = try #require(
      properties[kCGImagePropertyProfileName] as? String,
      "Independent ImageIO reader did not report a named color profile for \(url.lastPathComponent)"
    )
    let colorModel = properties[kCGImagePropertyColorModel] as? String
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let icc = image.colorSpace?.copyICCData() as Data?

    #expect(width == expectedWidth, "\(url.lastPathComponent) width")
    #expect(height == expectedHeight, "\(url.lastPathComponent) height")
    #expect(depth == expectedDepth, "\(url.lastPathComponent) bit depth")
    #expect(orientation == 1, "\(url.lastPathComponent) should bake orientation into pixels")
    #expect(profileName.localizedCaseInsensitiveContains("sRGB"))
    #expect(colorModel == String(kCGImagePropertyColorModelRGB))
    #expect(image.colorSpace?.name == CGColorSpace.sRGB)
    #expect(icc != nil && !(icc?.isEmpty ?? true))
    #expect(image.width == expectedWidth)
    #expect(image.height == expectedHeight)

    let sips = try sipsProperties(at: url)
    #expect(sips["pixelWidth"] == String(expectedWidth))
    #expect(sips["pixelHeight"] == String(expectedHeight))
    #expect(sips["space"] == "RGB")
    if let bits = sips["bitsPerSample"] {
      #expect(bits == String(expectedDepth))
    }
    try expectExtractedICCProfile(at: url)

    return NamedSRGBReport(
      width: width,
      height: height,
      depth: depth,
      profileName: profileName,
      orientation: orientation
    )
  }

  static func inspectProcessedDNG(
    at url: URL,
    expectedWidth: Int,
    expectedHeight: Int
  ) throws {
    let data = try Data(contentsOf: url)
    let entries = dngIFDEntries(data)
    #expect(Int(try requireTag(entries, 256).value) == expectedWidth)
    #expect(Int(try requireTag(entries, 257).value) == expectedHeight)
    #expect(try requireTag(entries, 258).count == 3)
    #expect(Int(try requireTag(entries, 274).value) == 1)
    #expect(Int(try requireTag(entries, 262).value) == 34_892)
    #expect(try requireTag(entries, 50706).value == 0x0000_0201)
    #expect(try requireTag(entries, 50721).count == 9)
    #expect(Int(try requireTag(entries, 50879).value) == 1)
    let uniqueCameraModel = asciiTag(data, entries: entries, tag: 50_708)
    #expect(uniqueCameraModel?.contains("Processed RGB") == true)
    let software = asciiTag(data, entries: entries, tag: 305)
    #expect(software?.contains("Film Scan Converter") == true)
  }

  private static func intProperty(_ properties: [CFString: Any], _ key: CFString) throws -> Int {
    try #require((properties[key] as? NSNumber)?.intValue)
  }

  private static func sipsProperties(at url: URL) throws -> [String: String] {
    let result = try runSips(
      arguments: [
        "-g", "pixelWidth",
        "-g", "pixelHeight",
        "-g", "format",
        "-g", "space",
        "-g", "bitsPerSample",
        url.path,
      ])
    var properties: [String: String] = [:]
    for line in result.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let separator = trimmed.firstIndex(of: ":") else { continue }
      let key = String(trimmed[..<separator])
      let value = trimmed[trimmed.index(after: separator)...]
        .trimmingCharacters(in: .whitespaces)
      if ["pixelWidth", "pixelHeight", "format", "space", "bitsPerSample"].contains(key) {
        properties[key] = value
      }
    }
    #expect(!properties.isEmpty, "sips produced no image properties for \(url.lastPathComponent)")
    return properties
  }

  private static func expectExtractedICCProfile(at url: URL) throws {
    let profile = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-icc-\(UUID().uuidString).icc")
    defer { try? FileManager.default.removeItem(at: profile) }
    _ = try runSips(arguments: ["-x", profile.path, url.path])
    let size = try profile.resourceValues(forKeys: [.fileSizeKey]).fileSize
    #expect((size ?? 0) > 0, "sips extracted an empty ICC profile from \(url.lastPathComponent)")
  }

  private static func runSips(arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: stdoutData, encoding: .utf8) ?? ""
    let errors = String(data: stderrData, encoding: .utf8) ?? ""
    try #require(
      process.terminationStatus == 0,
      "sips failed (\(process.terminationStatus)): \(errors)\(output)")
    return output
  }

  private static func dngIFDEntries(_ data: Data) -> [UInt16: (
    type: UInt16, count: UInt32, value: UInt32
  )] {
    let ifdOffset = Int(littleEndianUInt32(data, at: 4))
    let count = Int(littleEndianUInt16(data, at: ifdOffset))
    var result: [UInt16: (type: UInt16, count: UInt32, value: UInt32)] = [:]
    for index in 0..<count {
      let offset = ifdOffset + 2 + index * 12
      result[littleEndianUInt16(data, at: offset)] = (
        littleEndianUInt16(data, at: offset + 2),
        littleEndianUInt32(data, at: offset + 4),
        littleEndianUInt32(data, at: offset + 8)
      )
    }
    return result
  }

  private static func requireTag(
    _ entries: [UInt16: (type: UInt16, count: UInt32, value: UInt32)],
    _ tag: UInt16
  ) throws -> (type: UInt16, count: UInt32, value: UInt32) {
    try #require(entries[tag], "DNG is missing TIFF/DNG tag \(tag)")
  }

  private static func asciiTag(
    _ data: Data,
    entries: [UInt16: (type: UInt16, count: UInt32, value: UInt32)],
    tag: UInt16
  ) -> String? {
    guard let entry = entries[tag], entry.type == 2, entry.count > 0 else { return nil }
    let offset: Int
    if entry.count <= 4 {
      var bytes = Data()
      var value = entry.value
      for _ in 0..<Int(entry.count) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        value >>= 8
      }
      return String(data: bytes, encoding: .ascii)?
        .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
    offset = Int(entry.value)
    let count = Int(entry.count)
    guard offset + count <= data.count else { return nil }
    return String(data: data.subdata(in: offset..<(offset + count)), encoding: .ascii)?
      .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
  }

  private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
  }

  private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
      | UInt32(data[offset + 1]) << 8
      | UInt32(data[offset + 2]) << 16
      | UInt32(data[offset + 3]) << 24
  }
}
