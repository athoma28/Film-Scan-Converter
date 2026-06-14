import Foundation

public enum FileDropPolicy {
  public static let rawExtensions: Set<String> = [
    "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "ori", "erf", "gpr",
    "raw", "crw", "rw2",
  ]
  public static let supportedExtensions = rawExtensions.union(
    StandardImageDecoder.supportedExtensions)

  public static func supportedFiles(from urls: [URL]) -> [URL] {
    var seenPaths = Set<String>()
    return urls.filter { url in
      guard url.isFileURL,
        supportedExtensions.contains(url.pathExtension.lowercased())
      else {
        return false
      }
      return seenPaths.insert(url.standardizedFileURL.path).inserted
    }
  }
}
