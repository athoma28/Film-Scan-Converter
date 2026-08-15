import Foundation

/// Deterministic recursive discovery for development corpora and batch tools.
/// Sorting by root-relative path keeps results stable as film-stock folders are
/// added and avoids basename collisions between different stocks.
public enum RecursiveFileDiscovery {
  public static func files(
    under root: URL,
    extensions: Set<String>
  ) throws -> [URL] {
    let normalizedExtensions = Set(extensions.map { $0.lowercased() })
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      throw CocoaError(.fileReadUnknown)
    }

    var matches: [URL] = []
    for case let url as URL in enumerator {
      guard normalizedExtensions.contains(url.pathExtension.lowercased()) else { continue }
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      if values.isRegularFile == true {
        matches.append(url)
      }
    }
    return matches.sorted {
      $0.path.replacingOccurrences(of: root.path, with: "")
        < $1.path.replacingOccurrences(of: root.path, with: "")
    }
  }
}
