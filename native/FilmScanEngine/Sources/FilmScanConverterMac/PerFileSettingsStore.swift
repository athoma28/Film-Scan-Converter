import FilmScanEngine
import Foundation

/// Atomic, versioned persistence for correction state keyed by source file path.
final class PerFileSettingsStore {
  struct Document: Codable, Equatable {
    var schemaVersion: Int = 2
    var settingsByPath: [String: ProcessingParameters]
    var editedPaths: Set<String> = []

    private enum CodingKeys: String, CodingKey {
      case schemaVersion, settingsByPath, editedPaths
    }

    init(
      schemaVersion: Int = 2,
      settingsByPath: [String: ProcessingParameters],
      editedPaths: Set<String> = []
    ) {
      self.schemaVersion = schemaVersion
      self.settingsByPath = settingsByPath
      self.editedPaths = editedPaths
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
      settingsByPath = try container.decode(
        [String: ProcessingParameters].self, forKey: .settingsByPath)
      editedPaths = try container.decodeIfPresent(Set<String>.self, forKey: .editedPaths) ?? []
    }
  }

  struct State: Equatable {
    var settingsByPath: [String: ProcessingParameters]
    var editedPaths: Set<String>
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
    try loadState().settingsByPath
  }

  func loadState() throws -> State {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return State(settingsByPath: [:], editedPaths: [])
    }
    let document = try decoder.decode(Document.self, from: Data(contentsOf: fileURL))
    guard document.schemaVersion == 1 || document.schemaVersion == 2 else {
      throw StoreError.unsupportedSchemaVersion(document.schemaVersion)
    }
    return State(
      settingsByPath: document.settingsByPath,
      editedPaths: document.schemaVersion == 1 ? Set(document.settingsByPath.keys) : document.editedPaths
    )
  }

  func save(_ settingsByPath: [String: ProcessingParameters]) throws {
    try save(State(settingsByPath: settingsByPath, editedPaths: Set(settingsByPath.keys)))
  }

  func save(_ state: State) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try encoder.encode(Document(
      settingsByPath: state.settingsByPath,
      editedPaths: state.editedPaths
    ))
    try data.write(to: fileURL, options: .atomic)
  }
}
