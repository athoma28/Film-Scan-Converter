import Foundation

public enum FileDropPolicy {
  public static let rawExtensions: Set<String> = [
    "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "ori", "erf", "gpr",
    "raw", "crw", "rw2",
  ]
  public static let supportedExtensions = rawExtensions.union(
    StandardImageDecoder.supportedExtensions)

  public static func supportedFiles(from urls: [URL]) -> [URL] {
    ImportLog.importStarted(fileCount: urls.count)

    var seenPaths = Set<String>()
    var rejected = 0
    var duplicates = 0

    let result = urls.filter { url in
      guard url.isFileURL,
        supportedExtensions.contains(url.pathExtension.lowercased())
      else {
        rejected += 1
        return false
      }
      let inserted = seenPaths.insert(url.standardizedFileURL.path).inserted
      if !inserted {
        duplicates += 1
      } else {
        ImportLog.importAdded(path: url.lastPathComponent)
      }
      return inserted
    }

    ImportLog.importFiltered(
      accepted: result.count,
      rejected: rejected,
      duplicates: duplicates
    )

    return result
  }
}
