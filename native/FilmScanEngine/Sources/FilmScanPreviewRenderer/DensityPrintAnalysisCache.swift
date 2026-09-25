import FilmScanEngine
import Foundation

/// One renderer owns one immutable analysis source, so its cache only needs
/// the resolved profile and paper values. A source upgrade creates a new cache.
/// Keep only the latest analysis, including when profiles are edited in place.
final class DensityPrintAnalysisCache: @unchecked Sendable {
  private struct Entry {
    let profile: NegativeDensityProfile
    let paper: DensityPaperProfile
    let analysis: DensityPrintAnalysis
    let version: Int
  }

  private let lock = NSLock()
  private var entry: Entry?

  func analysis(
    profile: NegativeDensityProfile,
    paper: DensityPaperProfile,
    version: Int = 1,
    compute: () -> DensityPrintAnalysis
  ) -> DensityPrintAnalysis {
    lock.lock()
    defer { lock.unlock() }
    if let entry, entry.profile == profile, entry.paper == paper, entry.version == version {
      return entry.analysis
    }
    // Compute under the lock so concurrent requests for this source do not
    // repeat the same expensive analysis or publish out-of-order entries.
    let analysis = compute()
    entry = Entry(profile: profile, paper: paper, analysis: analysis, version: version)
    return analysis
  }
}
