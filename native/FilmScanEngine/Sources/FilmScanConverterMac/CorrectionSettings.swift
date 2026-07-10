import AppKit
import FilmScanEngine
import Foundation

/// Correction intent that can move between scans without carrying frame-specific geometry.
struct CorrectionSettings: Codable, Equatable {
  enum SettingsError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
  }

  private static let currentSchemaVersion = 1

  let schemaVersion: Int
  let parameters: ProcessingParameters

  init(capturing parameters: ProcessingParameters) {
    schemaVersion = Self.currentSchemaVersion
    self.parameters = parameters
  }

  func applying(to destination: ProcessingParameters) -> ProcessingParameters {
    var result = parameters
    result.borderCrop = destination.borderCrop
    result.rotation = destination.rotation
    result.flip = destination.flip
    result.straightenAngle = destination.straightenAngle
    result.cropRect = destination.cropRect
    result.perspectiveCrop = destination.perspectiveCrop
    result.manualCrop = destination.manualCrop
    result.densityPipelineEnabled = destination.densityPipelineEnabled
    result.densityBaseDensity = destination.densityBaseDensity
    return result
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case parameters
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .schemaVersion)
    guard version == Self.currentSchemaVersion else {
      throw SettingsError.unsupportedSchemaVersion(version)
    }
    schemaVersion = version
    parameters = try container.decode(ProcessingParameters.self, forKey: .parameters)
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
    var schemaVersion: Int = 1
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
    let root = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    self.init(baseDirectory: root.appendingPathComponent(applicationName, isDirectory: true))
  }

  func load() throws -> [NamedCorrectionPreset] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let document = try decoder.decode(Document.self, from: Data(contentsOf: fileURL))
    guard document.schemaVersion == 1 else {
      throw StoreError.unsupportedSchemaVersion(document.schemaVersion)
    }
    return sorted(document.presets)
  }

  @discardableResult
  func savePreset(named rawName: String, settings: CorrectionSettings) throws
    -> [NamedCorrectionPreset]
  {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw StoreError.emptyName }
    var presets = try load()
    if let index = presets.firstIndex(where: {
      $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }) {
      presets[index].name = name
      presets[index].settings = settings
    } else {
      presets.append(NamedCorrectionPreset(name: name, settings: settings))
    }
    try save(presets)
    return sorted(presets)
  }

  @discardableResult
  func deletePreset(id: UUID) throws -> [NamedCorrectionPreset] {
    var presets = try load()
    presets.removeAll { $0.id == id }
    try save(presets)
    return sorted(presets)
  }

  private func save(_ presets: [NamedCorrectionPreset]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try encoder.encode(Document(presets: sorted(presets))).write(to: fileURL, options: .atomic)
  }

  private func sorted(_ presets: [NamedCorrectionPreset]) -> [NamedCorrectionPreset] {
    presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
}

final class CorrectionSettingsClipboard {
  private static let pasteboardType = NSPasteboard.PasteboardType(
    "com.filmscanconverter.correction-settings"
  )

  private let pasteboard: NSPasteboard
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  func write(_ settings: CorrectionSettings) throws {
    let data = try encoder.encode(settings)
    pasteboard.clearContents()
    pasteboard.setData(data, forType: Self.pasteboardType)
    pasteboard.setString(String(decoding: data, as: UTF8.self), forType: .string)
  }

  func read() throws -> CorrectionSettings? {
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
