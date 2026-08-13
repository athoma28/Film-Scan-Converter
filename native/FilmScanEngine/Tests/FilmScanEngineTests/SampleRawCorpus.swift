import Foundation
import FilmScanEngine

struct SampleRawTriplet: Sendable {
  let stockID: String
  let stem: String
  let rawURL: URL
  let targetURL: URL
  let xmpURL: URL
  let isMonochrome: Bool
}

struct SampleRawAlignedReference {
  let triplet: SampleRawTriplet
  let raw: UInt16Image
  let target: UInt16Image
  let targetOriginX: Int
  let targetOriginY: Int
}

enum SampleRawCorpus {
  static let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  static let root = repositoryRoot.appending(path: "sample-raw", directoryHint: .isDirectory)

  static func url(relativePath: String) -> URL {
    root.appending(path: relativePath)
  }

  /// Resolves historical manifests that stored only a basename. A duplicate
  /// basename is deliberately treated as ambiguous so a newly added stock can
  /// never make a regression test select the wrong frame silently.
  static func uniqueURL(named filename: String) -> URL? {
    if filename.contains("/") {
      let candidate = root.appending(path: filename)
      return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
    let matches = allFiles().filter {
      $0.lastPathComponent.caseInsensitiveCompare(filename) == .orderedSame
    }
    return matches.count == 1 ? matches[0] : nil
  }

  static func rawURLs() -> [URL] {
    allFiles()
      .filter { $0.pathExtension.caseInsensitiveCompare("raf") == .orderedSame }
      .sorted { $0.path < $1.path }
  }

  static func triplets() -> [SampleRawTriplet] {
    let files = allFiles()
    let grouped = Dictionary(grouping: files) { $0.deletingLastPathComponent() }
    var result: [SampleRawTriplet] = []

    for (directory, directoryFiles) in grouped {
      let raws = directoryFiles.filter {
        $0.pathExtension.caseInsensitiveCompare("raf") == .orderedSame
      }
      for rawURL in raws {
        let stem = rawURL.deletingPathExtension().lastPathComponent
        guard
          let xmpURL = directoryFiles.first(where: {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(stem)
              == .orderedSame
              && $0.pathExtension.caseInsensitiveCompare("xmp") == .orderedSame
          }),
          let targetURL = preferredTarget(
            for: stem,
            among: directoryFiles
          )
        else { continue }

        let xmp = (try? String(contentsOf: xmpURL, encoding: .utf8)) ?? ""
        let stockID = directory == root
          ? root.lastPathComponent
          : directory.path.replacingOccurrences(of: root.path + "/", with: "")
        result.append(
          SampleRawTriplet(
            stockID: stockID,
            stem: stem,
            rawURL: rawURL,
            targetURL: targetURL,
            xmpURL: xmpURL,
            isMonochrome: xmp.contains("ConvertToGrayscale=\"True\"")
          )
        )
      }
    }

    return result.sorted {
      ($0.stockID, $0.stem) < ($1.stockID, $1.stem)
    }
  }

  static func loadAlignedReference(
    _ triplet: SampleRawTriplet
  ) throws -> SampleRawAlignedReference {
    let raw = try RawImageDecoder.decode(
      triplet.rawURL,
      profile: .rawTherapeeCameraScan
    ).image
    let fullRaw = try RawImageDecoder.fullResolutionDimensions(triplet.rawURL)
    let xmp = try String(contentsOf: triplet.xmpURL, encoding: .utf8)
    func attribute(_ qualifiedName: String) -> String? {
      let marker = "\(qualifiedName)=\""
      guard let start = xmp.range(of: marker)?.upperBound,
        let end = xmp[start...].firstIndex(of: "\"")
      else { return nil }
      return String(xmp[start..<end])
    }
    let targetAlignmentQuarterTurns: Int
    switch Int(attribute("tiff:Orientation") ?? "1") ?? 1 {
    case 1: targetAlignmentQuarterTurns = 0
    case 3: targetAlignmentQuarterTurns = 2
    case 6: targetAlignmentQuarterTurns = -1
    case 8: targetAlignmentQuarterTurns = 1
    default: throw CocoaError(.coderInvalidValue)
    }
    let fullTarget = try StandardImageDecoder.fullResolutionDimensions(triplet.targetURL)
    let scaleX = Double(raw.width) / Double(fullRaw.width)
    let scaleY = Double(raw.height) / Double(fullRaw.height)
    let decodedTarget = try StandardImageDecoder.decodePreview(
      triplet.targetURL,
      maxDimension: max(
        1,
        Int(
          round(
            max(
              Double(fullTarget.width) * scaleX,
              Double(fullTarget.height) * scaleY
            )
          )
        )
      )
    )
    let target = decodedTarget.rotated(quarterTurns: targetAlignmentQuarterTurns)
    let alignedFullTargetWidth = targetAlignmentQuarterTurns.isMultiple(of: 2)
      ? fullTarget.width : fullTarget.height
    let alignedFullTargetHeight = targetAlignmentQuarterTurns.isMultiple(of: 2)
      ? fullTarget.height : fullTarget.width

    func value(_ name: String, fallback: Double) -> Double {
      Double(attribute("crs:\(name)") ?? "") ?? fallback
    }
    let cropTop = value("CropTop", fallback: 0)
    let cropLeft = value("CropLeft", fallback: 0)
    let cropBottom = value("CropBottom", fallback: 1)
    let cropRight = value("CropRight", fallback: 1)
    let activeWidth = Double(alignedFullTargetWidth) / max(cropRight - cropLeft, 1e-6)
    let activeHeight = Double(alignedFullTargetHeight) / max(cropBottom - cropTop, 1e-6)
    let originX = Int(
      round(
        ((Double(fullRaw.width) - activeWidth) / 2 + cropLeft * activeWidth)
          * scaleX
      )
    )
    let originY = Int(
      round(
        ((Double(fullRaw.height) - activeHeight) / 2 + cropTop * activeHeight)
          * scaleY
      )
    )
    guard originX >= 0, originY >= 0,
      originX + target.width <= raw.width,
      originY + target.height <= raw.height
    else {
      throw CocoaError(.coderInvalidValue)
    }
    return SampleRawAlignedReference(
      triplet: triplet,
      raw: raw,
      target: target,
      targetOriginX: originX,
      targetOriginY: originY
    )
  }

  private static func allFiles() -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }

    return enumerator.compactMap { item in
      guard let url = item as? URL else { return nil }
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
      return values?.isRegularFile == true ? url : nil
    }
  }

  private static func preferredTarget(for stem: String, among files: [URL]) -> URL? {
    let candidates = files.filter {
      let name = $0.deletingPathExtension().lastPathComponent.lowercased()
      let lowerStem = stem.lowercased()
      return ["jpg", "jpeg"].contains($0.pathExtension.lowercased())
        && (name == lowerStem || name.hasPrefix(lowerStem + "-")
          || name.hasPrefix(lowerStem + "_"))
        && !$0.lastPathComponent.lowercased().contains("cnegprofile")
    }
    func rank(_ url: URL) -> Int {
      let name = url.deletingPathExtension().lastPathComponent.lowercased()
      let lowerStem = stem.lowercased()
      if name == lowerStem { return 0 }
      if name == lowerStem + "-adobe" { return 1 }
      return 2
    }
    return candidates.sorted {
      let left = rank($0)
      let right = rank($1)
      return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
    }.first
  }
}
