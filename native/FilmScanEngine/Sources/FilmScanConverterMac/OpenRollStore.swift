import FilmScanEngine
import Foundation

/// Saves browsing state separately from image corrections and transient history.
final class OpenRollStore: Sendable {
  struct State: Codable, Equatable, Sendable {
    var paths: [String]
    var selection: String?
    var selectedPaths: Set<String>

    init(paths: [String], selection: String? = nil, selectedPaths: Set<String> = []) {
      var seen = Set<String>()
      self.paths = paths.compactMap { path in
        guard let normalized = Self.normalizedPath(path), seen.insert(normalized).inserted else {
          return nil
        }
        return normalized
      }
      self.selection = selection.flatMap(Self.normalizedPath).flatMap {
        seen.contains($0) ? $0 : nil
      }
      self.selectedPaths = Set(selectedPaths.compactMap(Self.normalizedPath)).intersection(seen)
      if let selection = self.selection { self.selectedPaths.insert(selection) }
    }

    private enum CodingKeys: String, CodingKey {
      case paths, selection, selectedPaths
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        paths: try container.decode([String].self, forKey: .paths),
        selection: try container.decodeIfPresent(String.self, forKey: .selection),
        selectedPaths: try container.decodeIfPresent(Set<String>.self, forKey: .selectedPaths) ?? []
      )
    }

    private static func normalizedPath(_ path: String) -> String? {
      guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
      let url = URL(fileURLWithPath: path).standardizedFileURL
      guard FileDropPolicy.supportedExtensions.contains(url.pathExtension.lowercased()) else {
        return nil
      }
      return url.path
    }
  }

  private struct Header: Decodable {
    let schemaVersion: Int
  }

  private struct Document: Codable {
    var schemaVersion = 1
    let state: State
  }

  enum StoreError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
  }

  let fileURL: URL

  init(baseDirectory: URL) {
    fileURL = baseDirectory.appendingPathComponent("OpenRoll.json")
  }

  convenience init(applicationName: String) {
    let root =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    self.init(baseDirectory: root.appendingPathComponent(applicationName, isDirectory: true))
  }

  func load() throws -> State? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    // Inspect the envelope first so a future version's different payload does
    // not masquerade as corruption or become overwritten by this version.
    let header = try decoder.decode(Header.self, from: data)
    guard header.schemaVersion == 1 else {
      throw StoreError.unsupportedSchemaVersion(header.schemaVersion)
    }
    return try decoder.decode(Document.self, from: data).state
  }

  func save(_ state: State) throws {
    // Recheck on every save: a document can become unreadable after startup.
    // Removing or repairing it permits the pending latest snapshot to retry.
    _ = try load()
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let normalized = State(
      paths: state.paths, selection: state.selection, selectedPaths: state.selectedPaths)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(Document(state: normalized)).write(to: fileURL, options: .atomic)
  }
}
