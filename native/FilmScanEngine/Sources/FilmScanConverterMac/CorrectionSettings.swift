import AppKit
import FilmScanEngine
import Foundation

/// A slider/curve/wheel snapshot that can move between scans without changing
/// film base, invert IDs, or geometry.
struct CorrectionSettings: Codable, Equatable {
  enum SettingsError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
  }

  private static let currentSchemaVersion = 2

  let schemaVersion: Int
  let recipe: LookRecipe

  init(capturing parameters: ProcessingParameters) {
    schemaVersion = Self.currentSchemaVersion
    recipe = LookRecipe.capturing(
      parameters,
      id: "snapshot",
      title: "Snapshot",
      recommendedFilmBases: FilmBase.allCases
    )
  }

  init(recipe: LookRecipe) {
    schemaVersion = Self.currentSchemaVersion
    self.recipe = recipe
  }

  func applying(to destination: ProcessingParameters) -> ProcessingParameters {
    recipe.applying(to: destination)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case recipe
    case parameters
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .schemaVersion)
    switch version {
    case 1:
      // Keep the public adjustments from older presets, while leaving the
      // destination's film base and frame-specific calibration in place.
      let parameters = try container.decode(ProcessingParameters.self, forKey: .parameters)
      self.init(capturing: parameters)
    case Self.currentSchemaVersion:
      self.init(recipe: try container.decode(LookRecipe.self, forKey: .recipe))
    default:
      throw SettingsError.unsupportedSchemaVersion(version)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(recipe, forKey: .recipe)
  }
}

struct NamedCorrectionPreset: Codable, Equatable, Identifiable {
  let id: UUID
  var name: String
  var settings: CorrectionSettings

  init(id: UUID = UUID(), name: String, settings: CorrectionSettings) {
    self.id = id
    self.name = name
    self.settings = settings
  }
}

/// Atomic, versioned persistence for user-named correction presets.
final class NamedCorrectionPresetStore {
  struct Document: Codable, Equatable {
    var schemaVersion: Int = 2
    var presets: [NamedCorrectionPreset]
  }

  enum StoreError: Error, Equatable {
    case emptyName
    case unsupportedSchemaVersion(Int)
  }

  let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder = JSONDecoder()

  init(baseDirectory: URL) {
    fileURL = baseDirectory.appendingPathComponent("CorrectionPresets.json")
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  }

  convenience init(applicationName: String) {
    let root =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    self.init(baseDirectory: root.appendingPathComponent(applicationName, isDirectory: true))
  }

  func load() throws -> [NamedCorrectionPreset] {
    sorted(try readDocument()?.document.presets ?? [])
  }

  private func readDocument() throws -> (document: Document, data: Data)? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let data = try Data(contentsOf: fileURL)
    let document = try decoder.decode(Document.self, from: data)
    guard document.schemaVersion == 1 || document.schemaVersion == 2 else {
      // Treat an unknown format as an error so save/delete cannot overwrite it.
      throw StoreError.unsupportedSchemaVersion(document.schemaVersion)
    }
    return (document, data)
  }

  @discardableResult
  func savePreset(named rawName: String, settings: CorrectionSettings) throws
    -> [NamedCorrectionPreset]
  {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw StoreError.emptyName }
    let stored = try readDocument()
    var presets = stored?.document.presets ?? []
    if let index = presets.firstIndex(where: {
      Self.namesMatch($0.name, name)
    }) {
      presets[index].name = name
      presets[index].settings = settings
    } else {
      presets.append(NamedCorrectionPreset(name: name, settings: settings))
    }
    return try save(
      presets, legacyData: stored?.document.schemaVersion == 1 ? stored?.data : nil)
  }

  @discardableResult
  func deletePreset(id: UUID) throws -> [NamedCorrectionPreset] {
    let stored = try readDocument()
    var presets = stored?.document.presets ?? []
    guard presets.contains(where: { $0.id == id }) else { return sorted(presets) }
    presets.removeAll { $0.id == id }
    return try save(
      presets, legacyData: stored?.document.schemaVersion == 1 ? stored?.data : nil)
  }

  private func save(_ presets: [NamedCorrectionPreset], legacyData: Data?) throws
    -> [NamedCorrectionPreset]
  {
    let sortedPresets = sorted(presets)
    let data = try encoder.encode(Document(presets: sortedPresets))
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if let legacyData {
      // The new recipe format deliberately omits legacy inversion/calibration
      // fields. Preserve the exact old document before the first v2 mutation.
      let backup = fileURL.deletingLastPathComponent()
        .appendingPathComponent("CorrectionPresets-v1-\(UUID().uuidString).json")
      try legacyData.write(to: backup, options: .atomic)
    }
    try data.write(to: fileURL, options: .atomic)
    return sortedPresets
  }

  private func sorted(_ presets: [NamedCorrectionPreset]) -> [NamedCorrectionPreset] {
    presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
    lhs.compare(
      rhs.trimmingCharacters(in: .whitespacesAndNewlines),
      options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
  }
}

protocol CorrectionSettingsPasteboard: AnyObject {
  /// Nil opts out of caching for providers without a revision counter.
  var correctionSettingsChangeCount: Int? { get }
  @discardableResult func clearContents() -> Int
  @discardableResult func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType)
    -> Bool
  @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType)
    -> Bool
  func data(forType dataType: NSPasteboard.PasteboardType) -> Data?
  func string(forType dataType: NSPasteboard.PasteboardType) -> String?
}

extension CorrectionSettingsPasteboard {
  var correctionSettingsChangeCount: Int? { nil }
}

extension NSPasteboard: CorrectionSettingsPasteboard {
  var correctionSettingsChangeCount: Int? { changeCount }
}

final class CorrectionSettingsClipboard {
  enum ClipboardError: Error, Equatable {
    case writeFailed
  }

  private static let pasteboardType = NSPasteboard.PasteboardType(
    "com.filmscanconverter.correction-settings"
  )

  private let pasteboard: any CorrectionSettingsPasteboard
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private var cachedRead: (revision: Int, result: Result<CorrectionSettings?, Error>)?

  init(pasteboard: any CorrectionSettingsPasteboard = NSPasteboard.general) {
    self.pasteboard = pasteboard
  }

  func write(_ settings: CorrectionSettings) throws {
    let data = try encoder.encode(settings)
    cachedRead = nil
    pasteboard.clearContents()
    let storedData = pasteboard.setData(data, forType: Self.pasteboardType)
    let storedText = pasteboard.setString(String(decoding: data, as: UTF8.self), forType: .string)
    guard storedData || storedText else { throw ClipboardError.writeFailed }
  }

  func read() throws -> CorrectionSettings? {
    let revision = pasteboard.correctionSettingsChangeCount
    if let revision, let cachedRead, cachedRead.revision == revision {
      return try cachedRead.result.get()
    }
    let result = Result { try readUncached() }
    // A clipboard owner may change while data is being fetched. Only memoize
    // a result belonging to the same revision observed before the read.
    if let revision, pasteboard.correctionSettingsChangeCount == revision {
      cachedRead = (revision, result)
    }
    return try result.get()
  }

  private func readUncached() throws -> CorrectionSettings? {
    if let data = pasteboard.data(forType: Self.pasteboardType) {
      return try decoder.decode(CorrectionSettings.self, from: data)
    }
    guard let string = pasteboard.string(forType: .string),
      let data = string.data(using: .utf8)
    else {
      return nil
    }
    return try? decoder.decode(CorrectionSettings.self, from: data)
  }
}
