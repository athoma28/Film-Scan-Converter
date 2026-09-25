import FilmScanEngine
import Foundation

/// Lazy diagnostics owned by one immutable corrected raster. The lock also
/// covers computation so a retained image can never be sampled twice at once.
final class RenderedPreviewStatistics: @unchecked Sendable {
  private let lock = NSLock()
  private var value: RenderReadyImageStatistics?
  private var compute: (@Sendable () -> RenderReadyImageStatistics)?

  init(_ compute: @escaping @Sendable () -> RenderReadyImageStatistics) {
    self.compute = compute
  }

  var resolvedValue: RenderReadyImageStatistics? {
    // Publication runs on the main actor and must never wait for sampling.
    guard lock.try() else { return nil }
    defer { lock.unlock() }
    return value
  }

  func resolve() -> (statistics: RenderReadyImageStatistics, didCompute: Bool) {
    lock.withLock {
      if let value { return (value, false) }
      let result = compute!()
      value = result
      compute = nil
      return (result, true)
    }
  }
}
