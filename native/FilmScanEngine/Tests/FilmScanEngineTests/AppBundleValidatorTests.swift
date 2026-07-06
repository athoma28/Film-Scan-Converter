import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Release app bundle validation")
struct AppBundleValidatorTests {
  @Test("Accepts a complete executable app bundle")
  func acceptsCompleteBundle() throws {
    let bundle = try makeBundle(
      info: validInfo,
      executableData: Data("binary".utf8)
    )

    #expect(AppBundleValidator.validate(bundleAt: bundle).isEmpty)
  }

  @Test("Reports missing release metadata and executable")
  func reportsIncompleteBundle() throws {
    let bundle = try makeBundle(
      info: [
        "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "MissingExecutable",
      ],
      executableData: nil
    )

    let issues = AppBundleValidator.validate(bundleAt: bundle)

    #expect(issues.contains("CFBundleIdentifier is missing"))
    #expect(issues.contains("CFBundleShortVersionString is missing"))
    #expect(issues.contains("CFBundleVersion is missing"))
    #expect(issues.contains("LSMinimumSystemVersion must be 14.0"))
    #expect(issues.contains("NSCameraUsageDescription is missing"))
    #expect(issues.contains("Contents/MacOS/MissingExecutable is missing"))
  }

  @Test("Rejects malformed property lists")
  func rejectsMalformedPropertyList() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("Film Scan Converter.app")
    let contents = root.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try Data("not a plist".utf8).write(to: contents.appendingPathComponent("Info.plist"))

    #expect(AppBundleValidator.validate(bundleAt: root) == ["Contents/Info.plist is not a readable property list"])
  }

  @Test("Requires the declared application icon resource")
  func requiresIconResource() throws {
    let bundle = try makeBundle(
      info: validInfo,
      executableData: Data("binary".utf8),
      includeIcon: false
    )

    #expect(AppBundleValidator.validate(bundleAt: bundle).contains("Contents/Resources/AppIcon.icns is missing"))
  }

  @Test("Requires standard image and camera RAW document registration")
  func requiresDocumentRegistration() throws {
    var info = validInfo
    info["CFBundleDocumentTypes"] = [
      ["LSItemContentTypes": ["public.image"]],
    ]
    let bundle = try makeBundle(
      info: info,
      executableData: Data("binary".utf8)
    )

    #expect(AppBundleValidator.validate(bundleAt: bundle).contains(
      "CFBundleDocumentTypes must register public.camera-raw-image"
    ))
  }

  private var validInfo: [String: Any] {
    [
      "CFBundleDisplayName": "Film Scan Converter",
      "CFBundleExecutable": "FilmScanConverterMac",
      "CFBundleIconFile": "AppIcon",
      "CFBundleIdentifier": "com.alexthomas.filmscanconverter",
      "CFBundlePackageType": "APPL",
      "CFBundleShortVersionString": "0.1.0",
      "CFBundleVersion": "1",
      "CFBundleDocumentTypes": [
        ["LSItemContentTypes": ["public.image", "public.camera-raw-image"]],
      ],
      "LSMinimumSystemVersion": "14.0",
      "NSCameraUsageDescription": "Camera access is used for live preview.",
    ]
  }

  private func makeBundle(
    info: [String: Any],
    executableData: Data?,
    includeIcon: Bool = true
  ) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("Film Scan Converter.app")
    let contents = root.appendingPathComponent("Contents")
    let macOS = contents.appendingPathComponent("MacOS")
    let resources = contents.appendingPathComponent("Resources")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .xml,
      options: 0
    )
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
    if includeIcon, let icon = info["CFBundleIconFile"] as? String {
      let iconFilename = icon.hasSuffix(".icns") ? icon : "\(icon).icns"
      try Data("icon".utf8).write(to: resources.appendingPathComponent(iconFilename))
    }
    if let executableData, let name = info["CFBundleExecutable"] as? String {
      let executable = macOS.appendingPathComponent(name)
      try executableData.write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executable.path
      )
    }
    return root
  }
}
