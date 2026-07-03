import Foundation

public enum AppBundleValidator {
  private static let requiredStringKeys = [
    "CFBundleDisplayName",
    "CFBundleIdentifier",
    "CFBundleShortVersionString",
    "CFBundleVersion",
    "NSCameraUsageDescription",
  ]

  public static func validate(
    bundleAt bundleURL: URL,
    fileManager: FileManager = .default
  ) -> [String] {
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    let plistURL = contentsURL.appendingPathComponent("Info.plist")
    guard
      let data = try? Data(contentsOf: plistURL),
      let info = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ) as? [String: Any]
    else {
      return ["Contents/Info.plist is not a readable property list"]
    }

    var issues = requiredStringKeys.compactMap { key -> String? in
      guard let value = info[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "\(key) is missing"
      }
      return nil
    }

    if info["CFBundlePackageType"] as? String != "APPL" {
      issues.append("CFBundlePackageType must be APPL")
    }
    if info["LSMinimumSystemVersion"] as? String != "14.0" {
      issues.append("LSMinimumSystemVersion must be 14.0")
    }

    guard
      let executableName = info["CFBundleExecutable"] as? String,
      !executableName.isEmpty
    else {
      issues.append("CFBundleExecutable is missing")
      return issues
    }

    let executableURL = contentsURL
      .appendingPathComponent("MacOS", isDirectory: true)
      .appendingPathComponent(executableName)
    guard fileManager.fileExists(atPath: executableURL.path) else {
      issues.append("Contents/MacOS/\(executableName) is missing")
      return issues
    }
    if !fileManager.isExecutableFile(atPath: executableURL.path) {
      issues.append("Contents/MacOS/\(executableName) is not executable")
    }
    return issues
  }
}
