import FilmScanEngine
import Foundation

/// A high-confidence, session-local proposal that adjacent imports depict the
/// same physical negative. The first member owns edits and the export name.
struct DetectedScanStack: Identifiable, Equatable, Sendable {
  let id: String
  let members: [URL]
  let confidence: Double
  let exposureSpreadEV: Double
  let recommendedMode: ScanStackMode

  init(
    members: [URL],
    confidence: Double,
    exposureSpreadEV: Double,
    recommendedMode: ScanStackMode
  ) {
    precondition(members.count >= 2, "A detected stack needs at least two captures")
    self.members = members
    self.confidence = min(max(confidence, 0), 1)
    self.exposureSpreadEV = max(0, exposureSpreadEV)
    self.recommendedMode = recommendedMode
    id = members.map { $0.standardizedFileURL.path }.joined(separator: "\u{1F}")
  }

  var anchor: URL { members[0] }

  func contains(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    return members.contains { $0.standardizedFileURL.path == path }
  }
}
