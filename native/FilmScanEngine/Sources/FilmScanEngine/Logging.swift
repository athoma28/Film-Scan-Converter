import CLibRawShim
import Foundation
import os

private enum LogFile {
  private static let queue = DispatchQueue(label: "film.scan.converter.logfile")
  nonisolated(unsafe) private static var handle: FileHandle?
  nonisolated(unsafe) private static var dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
  }()

  static func configure(directory: URL) {
    queue.sync {
      let fm = FileManager.default
      try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
      let logURL = directory.appendingPathComponent("fsc.log")
      if !fm.fileExists(atPath: logURL.path) {
        fm.createFile(atPath: logURL.path, contents: nil)
      }
      handle?.closeFile()
      handle = try? FileHandle(forUpdating: logURL)
      handle?.seekToEndOfFile()

      let cPath = logURL.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } }
      if let cPath {
        fsc_set_log_path(cPath)
      }
    }
  }

  static func write(_ message: String) {
    queue.async {
      let ts = dateFormatter.string(from: Date())
      let line = "\(ts)  \(message)\n"
      if let data = line.data(using: .utf8) {
        handle?.write(data)
      }
    }
  }
}

public enum FilmScanLog {
  private static func findProjectRoot() -> URL? {
    var searchURL = Bundle.main.bundleURL
    for _ in 0..<10 {
      let packageURL = searchURL.appendingPathComponent("native/FilmScanEngine/Package.swift")
      if FileManager.default.fileExists(atPath: packageURL.path) {
        return searchURL
      }
      if searchURL.path == "/" { break }
      searchURL = searchURL.deletingLastPathComponent()
    }
    return nil
  }

  public static func configureLogDirectory() {
    let dir: URL
    if let projectRoot = findProjectRoot() {
      dir = projectRoot.appendingPathComponent("logs")
    } else {
      dir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/FilmScanConverter")
    }
    LogFile.configure(directory: dir)
  }

  public static func configureLogDirectory(at url: URL) {
    LogFile.configure(directory: url)
  }
}

public enum ImportLog {
  private static let logger = Logger(
    subsystem: "film.scan.converter",
    category: "Import"
  )

  public static func importStarted(fileCount: Int) {
    let msg = "Import started — \(fileCount) file(s) presented for import"
    logger.info("\(msg, privacy: .public)")
    LogFile.write("[Import] \(msg)")
  }

  public static func importFiltered(
    accepted: Int,
    rejected: Int,
    duplicates: Int
  ) {
    let msg = "Import filtered — accepted=\(accepted) rejected=\(rejected) duplicates=\(duplicates)"
    logger.info("\(msg, privacy: .public)")
    LogFile.write("[Import] \(msg)")
  }

  public static func importAdded(path: String) {
    let msg = "Import added: \(path)"
    logger.debug("\(msg, privacy: .public)")
    LogFile.write("[Import] \(msg)")
  }

  public static func loadSelectionStarted(path: String) {
    let msg = "loadSelection started: \(path)"
    logger.info("\(msg, privacy: .public)")
    LogFile.write("[Import] \(msg)")
  }

  public static func loadSelectionCacheHit(path: String) {
    let msg = "loadSelection cache hit: \(path)"
    logger.debug("\(msg, privacy: .public)")
    LogFile.write("[Import] \(msg)")
  }

  public static func loadSelectionDecodeStarted(path: String) {
    let msg = "Decoding started: \(path)"
    logger.info("\(msg, privacy: .public)")
    LogFile.write("[Import] \(msg)")
  }

  public static func loadSelectionDecodeComplete(
    path: String,
    width: Int,
    height: Int,
    channels: Int
  ) {
    let msg = "Decode complete: \(path) \(width)×\(height) \(channels)ch"
    logger.info("\(msg, privacy: .public)")
    LogFile.write("[Import] \(msg)")
  }

  public static func loadSelectionDecodeFailed(path: String, error: String) {
    let msg = "Decode failed: \(path) — \(error)"
    logger.error("\(msg, privacy: .public)")
    LogFile.write("[Import] \(msg)")
  }

  public static func loadSelectionCancelled(path: String) {
    let msg = "loadSelection cancelled: \(path)"
    logger.debug("\(msg, privacy: .public)")
    LogFile.write("[Import] \(msg)")
  }

  public static func error(_ message: String) {
    logger.error("\(message, privacy: .public)")
    LogFile.write("[Import] ERROR: \(message)")
  }
}

public enum DecodeLog {
  private static let logger = Logger(
    subsystem: "film.scan.converter",
    category: "Decode"
  )

  public static func standardImageStarted(
    path: String,
    ext: String,
    width: Int,
    height: Int,
    colorModel: String,
    bitsPerComponent: Int
  ) {
    let msg = "Standard decode: \(path) .\(ext) \(width)×\(height) model=\(colorModel) bpc=\(bitsPerComponent)"
    logger.info("\(msg, privacy: .public)")
    LogFile.write("[Decode] \(msg)")
  }

  public static func standardImageSkippedAlpha(path: String) {
    let msg = "Standard decode rejected (alpha): \(path)"
    logger.error("\(msg, privacy: .public)")
    LogFile.write("[Decode] \(msg)")
  }

  public static func standardImageFailed(
    path: String,
    error: String
  ) {
    let msg = "Standard decode failed: \(path) — \(error)"
    logger.error("\(msg, privacy: .public)")
    LogFile.write("[Decode] \(msg)")
  }

  public static func rawDecodeStarted(path: String, fullResolution: Bool) {
    let msg = "RAW decode started: \(path) fullRes=\(fullResolution)"
    logger.info("\(msg, privacy: .public)")
    LogFile.write("[Decode] \(msg)")
  }

  public static func rawDecodeComplete(
    path: String,
    width: Int,
    height: Int,
    colorDescription: String,
    version: String
  ) {
    let msg = "RAW decode complete: \(path) \(width)×\(height) color=\(colorDescription) libraw=\(version)"
    logger.info("\(msg, privacy: .public)")
    LogFile.write("[Decode] \(msg)")
  }

  public static func rawDecodeFailed(path: String, error: String) {
    let msg = "RAW decode failed: \(path) — \(error)"
    logger.error("\(msg, privacy: .public)")
    LogFile.write("[Decode] \(msg)")
  }
}
