import FilmScanEngine
import Foundation

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: FilmScanReleaseValidator <app-bundle>\n".utf8))
  exit(64)
}

let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let issues = AppBundleValidator.validate(bundleAt: bundleURL)
guard issues.isEmpty else {
  for issue in issues {
    FileHandle.standardError.write(Data("error: \(issue)\n".utf8))
  }
  exit(1)
}

print("Validated release bundle: \(bundleURL.path)")
