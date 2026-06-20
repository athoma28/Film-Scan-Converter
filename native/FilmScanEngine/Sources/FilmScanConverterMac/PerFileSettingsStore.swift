import FilmScanEngine
import Foundation

/// Atomic, versioned persistence for correction state keyed by source file path.
final class PerFileSettingsStore {
  struct Document: Codable, Equatable {
    var schemaVersion: Int = 1
    var settingsByPath: [String: ProcessingParameters]
  }

  enum StoreError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
  }

  let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(baseDirectory: URL) {
    fileURL = baseDirectory.appendingPathComponent("PerFileSettings.json")
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    decoder = JSONDecoder()
  }

  convenience init(applicationName: String) {
    let root = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    self.init(baseDirectory: root.appendingPathComponent(applicationName, isDirectory: true))
  }

  func load() throws -> [String: ProcessingParameters] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
    let document = try decoder.decode(Document.self, from: Data(contentsOf: fileURL))
    guard document.schemaVersion == 1 else {
      throw StoreError.unsupportedSchemaVersion(document.schemaVersion)
    }
    return document.settingsByPath
  }

  func save(_ settingsByPath: [String: ProcessingParameters]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try encoder.encode(Document(settingsByPath: settingsByPath))
    try data.write(to: fileURL, options: .atomic)
  }
}
