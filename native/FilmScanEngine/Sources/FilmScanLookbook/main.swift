import FilmScanEngine
import Foundation

private let usage = """
  Usage: FilmScanLookbook [OUTPUT_DIRECTORY]

  Renders a small lookbook of Natural, Kodachrome-like Auto, and the prototype
  display looks against local sample scans. Lucky C200 frames have no paired
  JPEG/XMP; those rows show inversion-only comparisons.
  """

private let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

private let sampleRawRoot = repositoryRoot.appending(
  path: "sample-raw", directoryHint: .isDirectory)
private let defaultOutput =
  repositoryRoot
  .appending(path: "photo-inspo/lookbook", directoryHint: .isDirectory)

private let lookbookMaxDimension = 900
private let exportParameters = ExportParameters(format: .jpeg, jpegQuality: 0.88)

private struct LookbookSource {
  let label: String
  let relativePath: String
  let referenceJPEGRelativePath: String?

  var url: URL { sampleRawRoot.appending(path: relativePath) }
  var referenceJPEGURL: URL? {
    referenceJPEGRelativePath.map { sampleRawRoot.appending(path: $0) }
  }
}

private struct LookbookColumn {
  let slug: String
  let title: String
  let look: AdaptiveDisplayLook?
}

private let sources: [LookbookSource] = [
  LookbookSource(
    label: "Lucky C200 · DSCF3790",
    relativePath: "luckyc200/DSCF3790.RAF",
    referenceJPEGRelativePath: nil
  ),
  LookbookSource(
    label: "Lucky C200 · DSCF3799",
    relativePath: "luckyc200/DSCF3799.RAF",
    referenceJPEGRelativePath: nil
  ),
  LookbookSource(
    label: "Lucky C200 · DSCF3811",
    relativePath: "luckyc200/DSCF3811.RAF",
    referenceJPEGRelativePath: nil
  ),
  LookbookSource(
    label: "Misc · DSCF2879",
    relativePath: "misc/DSCF2879.JPG",
    referenceJPEGRelativePath: nil
  ),
  LookbookSource(
    label: "Misc · DSCF2819",
    relativePath: "misc/DSCF2819.RAF",
    referenceJPEGRelativePath: nil
  ),
  LookbookSource(
    label: "Fuji 400 · DSCF2555",
    relativePath: "fuji400-fresh/DSCF2555.RAF",
    referenceJPEGRelativePath: "fuji400-fresh/DSCF2555.jpg"
  ),
]

private let columns: [LookbookColumn] = [
  LookbookColumn(slug: "natural", title: "Natural", look: nil),
  LookbookColumn(slug: "kodachrome", title: "Kodachrome-like Auto", look: .kodachromeLike),
  LookbookColumn(slug: "night-cinema", title: "Night Cinema", look: .nightCinema),
  LookbookColumn(slug: "golden-cream", title: "Golden Cream", look: .goldenCream),
  LookbookColumn(slug: "daylight-print", title: "Daylight Print", look: .daylightPrint),
  LookbookColumn(slug: "blue-hour", title: "Blue Hour", look: .blueHour),
]

private func decodeSample(_ url: URL) throws -> UInt16Image {
  let ext = url.pathExtension.lowercased()
  if FileDropPolicy.rawExtensions.contains(ext) {
    return try RawImageDecoder.decode(
      url,
      profile: .rawTherapeeCameraScan
    ).image.resizedToFit(maxDimension: lookbookMaxDimension)
  }
  return try StandardImageDecoder.decodePreview(url, maxDimension: lookbookMaxDimension)
}

private func naturalParameters(for image: UInt16Image) -> ProcessingParameters {
  var parameters = ProcessingParameters()
  parameters.filmType = .colourNegative
  parameters.filmNegativeParams = .colourNegative
  parameters.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(
    image: image,
    borderPercent: 20
  )
  return parameters
}

private func writeHTML(to directory: URL, rows: [(source: LookbookSource, files: [String: String])])
  throws
{
  var html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>Prototype lookbook</title>
    <style>
      :root { color-scheme: dark; }
      body { margin: 0; padding: 28px; font: 14px/1.45 ui-sans-serif, system-ui, sans-serif;
             background: #111; color: #ece8e1; }
      h1 { font-size: 22px; font-weight: 600; margin: 0 0 8px; }
      p.lede { max-width: 72ch; color: #b9b3aa; margin: 0 0 28px; }
      table { border-collapse: collapse; width: max-content; }
      th, td { padding: 8px 10px; vertical-align: top; text-align: left; }
      th { font-size: 12px; font-weight: 600; letter-spacing: 0.02em; color: #d8d2c8;
           position: sticky; top: 0; background: #111; }
      td.label { font-size: 12px; color: #b9b3aa; white-space: nowrap; padding-top: 18px; }
      img { width: 280px; height: auto; display: block; background: #1a1a1a; }
      .missing { width: 280px; height: 80px; color: #7d776f; font-size: 12px; }
    </style>
    </head>
    <body>
    <h1>Prototype lookbook</h1>
    <p class="lede">
      Natural is the generic calibrated color-negative inversion with no display grade.
      The other columns keep that inversion, then apply a per-frame tone curve and a light
      split-tone. Recipes were sampled from finished JPEGs in photo-inspo, not from paired
      RAW/XMP emulsion fits. Lucky C200 frames have no Camera Raw references.
    </p>
    <table>
    <thead><tr><th></th>
    """
  for column in columns {
    html += "<th>\(column.title)</th>"
  }
  html += "<th>Camera Raw JPEG</th></tr></thead><tbody>\n"
  for row in rows {
    html += "<tr><td class=\"label\">\(row.source.label)</td>"
    for column in columns {
      if let file = row.files[column.slug] {
        html += "<td><img src=\"\(file)\" alt=\"\(row.source.label) · \(column.title)\"></td>"
      } else {
        html += "<td class=\"missing\">missing</td>"
      }
    }
    if let file = row.files["camera-raw"] {
      html += "<td><img src=\"\(file)\" alt=\"\(row.source.label) · Camera Raw\"></td>"
    } else {
      html += "<td class=\"missing\">no paired JPEG</td>"
    }
    html += "</tr>\n"
  }
  html += """
    </tbody></table>
    </body></html>
    """
  try html.write(
    to: directory.appending(path: "index.html"),
    atomically: true,
    encoding: .utf8
  )
}

@main
enum FilmScanLookbook {
  static func main() throws {
    if CommandLine.arguments.contains("-h") || CommandLine.arguments.contains("--help") {
      FileHandle.standardError.write(Data((usage + "\n").utf8))
      return
    }

    let output: URL
    if let argument = CommandLine.arguments.dropFirst().first {
      output = URL(fileURLWithPath: argument, isDirectory: true)
    } else {
      output = defaultOutput
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    var rows: [(source: LookbookSource, files: [String: String])] = []
    for source in sources {
      guard FileManager.default.fileExists(atPath: source.url.path) else {
        FileHandle.standardError.write(
          Data(("skip missing \(source.relativePath)\n").utf8)
        )
        continue
      }
      FileHandle.standardError.write(Data(("decode \(source.relativePath)\n").utf8))
      let image = try decodeSample(source.url)
      var files: [String: String] = [:]
      let stem = source.url.deletingPathExtension().lastPathComponent

      for column in columns {
        let parameters: ProcessingParameters
        if let look = column.look {
          parameters = look.parameters(for: image, preserving: ProcessingParameters())
        } else {
          parameters = naturalParameters(for: image)
        }
        let rendered = FilmProcessing.correctedPreview(image: image, parameters: parameters)
        let filename = "\(stem)-\(column.slug).jpg"
        try rendered.write(
          to: output.appending(path: filename),
          format: .jpeg,
          parameters: exportParameters
        )
        files[column.slug] = filename
      }

      if let reference = source.referenceJPEGURL,
        FileManager.default.fileExists(atPath: reference.path)
      {
        let jpeg = try StandardImageDecoder.decodePreview(
          reference,
          maxDimension: lookbookMaxDimension
        )
        let filename = "\(stem)-camera-raw.jpg"
        try jpeg.write(
          to: output.appending(path: filename),
          format: .jpeg,
          parameters: exportParameters
        )
        files["camera-raw"] = filename
      }

      rows.append((source, files))
    }

    try writeHTML(to: output, rows: rows)
    FileHandle.standardError.write(
      Data(("wrote \(rows.count) rows to \(output.path)\n").utf8)
    )
  }
}
