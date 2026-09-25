import FilmScanEngine
import Foundation

private let usage = """
  Usage: FilmScanLookbook [OUTPUT_DIRECTORY] [--lucky-study]

  Renders factory LookRecipe snapshots against local sample scans. Invert-only
  is the film-base conversion with no look applied. Lucky C200 frames have no
  paired JPEG/XMP; those rows show inversion and recipe comparisons.
  --lucky-study renders all five Lucky scans with Clean Invert and Foliage.
  --recipes=FILE renders a JSON array of LookRecipe values instead of factory recipes.
  --sources=FILE renders a JSON array of LookbookSource values instead of the default set.
  LookbookSource fields: label, relativePath, optional referenceJPEGRelativePath,
  filmBase, rawDecodeProfile (0 = RawPy-compatible positive photo, 1 = camera scan),
  optional manualCrop in normalized post-rotation coordinates, and optional rotation
  in clockwise quarter-turns.
  --paired-study=MANIFEST runs production renders for the offline paired-reference
  study; see native/diagnostics/paired-reference-study.py for manifest generation.
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

private struct LookbookSource: Codable {
  let label: String
  let relativePath: String
  let referenceJPEGRelativePath: String?
  let filmBase: FilmBase
  let rawDecodeProfile: RawDecodeProfile
  let manualCrop: NormalizedCropRect?
  let rotation: Int?

  init(
    label: String,
    relativePath: String,
    referenceJPEGRelativePath: String? = nil,
    filmBase: FilmBase = .colorC41,
    rawDecodeProfile: RawDecodeProfile = .rawTherapeeCameraScan,
    manualCrop: NormalizedCropRect? = nil,
    rotation: Int? = nil
  ) {
    self.label = label
    self.relativePath = relativePath
    self.referenceJPEGRelativePath = referenceJPEGRelativePath
    self.filmBase = filmBase
    self.rawDecodeProfile = rawDecodeProfile
    self.manualCrop = manualCrop
    self.rotation = rotation
  }

  var url: URL { sampleRawRoot.appending(path: relativePath) }
  var referenceJPEGURL: URL? {
    referenceJPEGRelativePath.map { sampleRawRoot.appending(path: $0) }
  }
}

private struct LookbookColumn {
  let recipe: LookRecipe?

  var slug: String { recipe?.id ?? "base" }
  var title: String { recipe?.title ?? "Base only" }
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

private func decodeSample(_ url: URL, profile: RawDecodeProfile) throws -> UInt16Image {
  let ext = url.pathExtension.lowercased()
  if FileDropPolicy.rawExtensions.contains(ext) {
    return try RawImageDecoder.decode(
      url,
      profile: profile
    ).image.resizedToFit(maxDimension: lookbookMaxDimension)
  }
  return try StandardImageDecoder.decodePreview(url, maxDimension: lookbookMaxDimension)
}

private func invertParameters(for image: UInt16Image, base: FilmBase) -> ProcessingParameters {
  var parameters = base.applyingInvert(to: ProcessingParameters())
  parameters.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(
    image: image,
    borderPercent: 20
  )
  return parameters
}

private func writeHTML(
  to directory: URL,
  rows: [(source: LookbookSource, files: [String: String])],
  columns: [LookbookColumn],
  description: String
) throws {
  let hasReferences = rows.contains { $0.files["camera-raw"] != nil }
  var html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>Color lookbook</title>
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
    <h1>Color lookbook</h1>
    <p class="lede">
      \(description)
    </p>
    <table>
    <thead><tr><th></th>
    """
  for column in columns {
    html += "<th>\(column.title)</th>"
  }
  if hasReferences { html += "<th>Camera Raw JPEG</th>" }
  html += "</tr></thead><tbody>\n"
  for row in rows {
    html += "<tr><td class=\"label\">\(row.source.label)</td>"
    for column in columns {
      if let file = row.files[column.slug] {
        html += "<td><img src=\"\(file)\" alt=\"\(row.source.label) · \(column.title)\"></td>"
      } else {
        html += "<td class=\"missing\">missing</td>"
      }
    }
    if hasReferences {
      if let file = row.files["camera-raw"] {
        html += "<td><img src=\"\(file)\" alt=\"\(row.source.label) · Camera Raw\"></td>"
      } else {
        html += "<td class=\"missing\">no paired JPEG</td>"
      }
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

enum FilmScanLookbook {
  static func main() throws {
    if let option = CommandLine.arguments.first(where: { $0.hasPrefix("--paired-study=") }) {
      try PairedReferenceStudy.run(manifest: String(option.dropFirst("--paired-study=".count)))
      return
    }
    if CommandLine.arguments.contains("--lucky-study") {
      try LuckyReferenceStudy.run(repositoryRoot: repositoryRoot)
      return
    }
    if CommandLine.arguments.contains("-h") || CommandLine.arguments.contains("--help") {
      FileHandle.standardError.write(Data((usage + "\n").utf8))
      return
    }

    let output: URL
    if let argument = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
      output = URL(fileURLWithPath: argument, isDirectory: true)
    } else {
      output = defaultOutput
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    let recipes: [LookRecipe]
    if let option = CommandLine.arguments.first(where: { $0.hasPrefix("--recipes=") }) {
      let path = String(option.dropFirst("--recipes=".count))
      recipes = try JSONDecoder().decode(
        [LookRecipe].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } else {
      recipes = LookRecipe.factory
    }
    let activeSources: [LookbookSource]
    if let option = CommandLine.arguments.first(where: { $0.hasPrefix("--sources=") }) {
      let path = String(option.dropFirst("--sources=".count))
      activeSources = try JSONDecoder().decode(
        [LookbookSource].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } else {
      activeSources = sources
    }
    let columns = [LookbookColumn(recipe: nil)] + recipes.map { LookbookColumn(recipe: $0) }

    var rows: [(source: LookbookSource, files: [String: String])] = []
    for source in activeSources {
      guard FileManager.default.fileExists(atPath: source.url.path) else {
        FileHandle.standardError.write(
          Data(("skip missing \(source.relativePath)\n").utf8)
        )
        continue
      }
      FileHandle.standardError.write(Data(("decode \(source.relativePath)\n").utf8))
      let image = try decodeSample(source.url, profile: source.rawDecodeProfile)
      var files: [String: String] = [:]
      let stem = source.url.deletingPathExtension().lastPathComponent

      for column in columns {
        let invert = invertParameters(for: image, base: source.filmBase)
        var parameters = column.recipe?.applying(to: invert) ?? invert
        parameters.manualCrop = source.manualCrop
        parameters.rotation = source.rotation ?? 0
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

    let description =
      "Base only uses each source's declared film base. Look columns apply public LookRecipe settings through the production Swift renderer. These are creative starting points, not measured stock simulations."
    try writeHTML(to: output, rows: rows, columns: columns, description: description)
    FileHandle.standardError.write(
      Data(("wrote \(rows.count) rows to \(output.path)\n").utf8)
    )
  }
}

try FilmScanLookbook.main()
