import FilmScanEngine
import Foundation

/// Atomic, versioned persistence for correction state keyed by source file path.
final class PerFileSettingsStore: Sendable {
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

  struct State: Equatable, Sendable {
    var settingsByPath: [String: ProcessingParameters]
    var editedPaths: Set<String>
  }

  enum StoreError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
  }

  /// Recovery remains session-local; a successful read is not a request to
  /// synchronize with another running app. Once a read fails, keep merging
  /// recovered history because the writer no longer owns its complete state.
  private final class SessionSaveOperation: @unchecked Sendable {
    private let store: PerFileSettingsStore
    private let lock = NSLock()
    private var requiresRecovery: Bool

    init(store: PerFileSettingsStore, requiresRecovery: Bool) {
      self.store = store
      self.requiresRecovery = requiresRecovery
    }

    func save(_ state: State) throws {
      lock.lock()
      defer { lock.unlock() }
      if requiresRecovery {
        try store.saveMergingWithExisting(state)
      } else {
        do {
          _ = try store.loadState()
        } catch {
          requiresRecovery = true
          throw error
        }
        try store.write(state)
      }
    }
  }

  let fileURL: URL
  init(baseDirectory: URL) {
    fileURL = baseDirectory.appendingPathComponent("PerFileSettings.json")
  }

  convenience init(applicationName: String) {
    let root =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    self.init(baseDirectory: root.appendingPathComponent(applicationName, isDirectory: true))
  }

  func loadState() throws -> State {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return State(settingsByPath: [:], editedPaths: [])
    }
    let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
    guard (1...3).contains(document.schemaVersion) else {
      throw StoreError.unsupportedSchemaVersion(document.schemaVersion)
    }
    return State(
      settingsByPath: document.settingsByPath,
      editedPaths: document.schemaVersion == 1
        ? Set(document.settingsByPath.keys) : document.editedPaths
    )
  }

  /// A session that could not load its history must not replace unreadable bytes.
  /// Retry loading before each save, and preserve recovered files that this
  /// session never loaded. Keep merging for the entire session: its persistence
  /// writer does not own entries introduced while the document was unreadable.
  func saveMergingWithExisting(_ state: State) throws {
    var recovered = try loadState()
    recovered.settingsByPath.merge(state.settingsByPath) { _, current in current }
    recovered.editedPaths.subtract(state.settingsByPath.keys)
    recovered.editedPaths.formUnion(state.editedPaths)
    try write(recovered)
  }

  func save(_ state: State) throws {
    // Startup success does not authorize replacing bytes that became unreadable
    // or unsupported later. Removal or repair allows the pending save to retry.
    _ = try loadState()
    try write(state)
  }

  func makeSessionSaveOperation(
    requiresRecovery: Bool
  ) -> @Sendable (State) throws -> Void {
    let operation = SessionSaveOperation(store: self, requiresRecovery: requiresRecovery)
    return { try operation.save($0) }
  }

  private func write(_ state: State) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(
      Document(
        // Older apps ignore unknown parameter fields. A repair-bearing document
        // must fail their store gate so they cannot silently erase saved strokes.
        schemaVersion: state.settingsByPath.values.contains { !$0.dustRepairs.isEmpty } ? 3 : 2,
        settingsByPath: state.settingsByPath,
        editedPaths: state.editedPaths
      ))
    try data.write(to: fileURL, options: .atomic)
  }
}
