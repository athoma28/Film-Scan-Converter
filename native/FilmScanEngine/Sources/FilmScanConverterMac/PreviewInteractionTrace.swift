import AppKit
import Foundation
import SwiftUI

/// Opt-in, bounded diagnostics. Native view/draw callbacks are not compositor
/// presentation acknowledgements and must never be reported as displayed FPS.
@MainActor
final class PreviewInteractionTrace {
  enum Stage: String, Codable {
    case gestureBegan, gestureEnded, setterBegan
    case requestSubmitted, renderBegan, workerBegan, workerFinished, renderReturned, modelPublished
    case viewportUpdateBegan, viewportUpdated, viewportUpdateEnded
    case hostingViewWillDraw, hostingDrawBegan, hostingDrawEnded
  }

  struct Event: Codable {
    let stage: Stage
    let milliseconds: Double
    let revision: Int?
    let interactionMilliseconds: Double?
    let exposureEV: Double?
    let contrast: Double?
    let sourceWidth: Int?
    let sourceHeight: Int?
    let rasterWidth: Int?
    let rasterHeight: Int?
    let usesProxy: Bool?
    let usesProxyOverview: Bool?
    let hasDetail: Bool?
    let renderer: String?
  }

  let origin = ContinuousClock.now
  private(set) var events: [Event] = []
  private(set) var discardedEventCount = 0
  private let maximumEvents: Int

  init(maximumEvents: Int = 20_000) {
    self.maximumEvents = max(1, maximumEvents)
    events.reserveCapacity(min(self.maximumEvents, 2_000))
  }

  func milliseconds(at instant: ContinuousClock.Instant = .now) -> Double {
    let duration = origin.duration(to: instant)
    return Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1e15
  }

  func record(
    _ stage: Stage, revision: Int? = nil,
    at instant: ContinuousClock.Instant = .now,
    interactionStart: ContinuousClock.Instant? = nil,
    exposureEV: Double? = nil, contrast: Double? = nil,
    sourceWidth: Int? = nil, sourceHeight: Int? = nil,
    rasterWidth: Int? = nil, rasterHeight: Int? = nil,
    usesProxy: Bool? = nil, usesProxyOverview: Bool? = nil,
    hasDetail: Bool? = nil, renderer: String? = nil
  ) {
    guard events.count < maximumEvents else {
      discardedEventCount += 1
      return
    }
    events.append(
      Event(
        stage: stage, milliseconds: milliseconds(at: instant), revision: revision,
        interactionMilliseconds: interactionStart.map { milliseconds(at: $0) },
        exposureEV: exposureEV, contrast: contrast,
        sourceWidth: sourceWidth, sourceHeight: sourceHeight,
        rasterWidth: rasterWidth, rasterHeight: rasterHeight,
        usesProxy: usesProxy, usesProxyOverview: usesProxyOverview,
        hasDetail: hasDetail, renderer: renderer))
  }
}

/// Used only when an explicit diagnostic recorder is attached to the model.
/// Layer-backed SwiftUI drawing may bypass draw(_:); missing callbacks remain
/// missing data, rather than being synthesized from view updates or timers.
@MainActor
final class DiagnosticPreviewHostingView<Content: View>: NSHostingView<Content> {
  weak var interactionTrace: PreviewInteractionTrace?
  var traceRevision = 0

  override func viewWillDraw() {
    interactionTrace?.record(.hostingViewWillDraw, revision: traceRevision)
    super.viewWillDraw()
  }

  override func draw(_ dirtyRect: NSRect) {
    let revision = traceRevision
    interactionTrace?.record(.hostingDrawBegan, revision: revision)
    super.draw(dirtyRect)
    interactionTrace?.record(.hostingDrawEnded, revision: revision)
  }
}

/// A diagnostic-only marker committed by the same SwiftUI preview update as
/// its raster. ScreenCaptureKit may observe it without retaining image data.
struct PreviewRevisionMarker: View {
  let revision: Int

  var body: some View {
    let value = revision & 0xffff
    let checksum = (value & 255) ^ ((value >> 8) & 255) ^ 0xa5
    let payload = value | (checksum << 16)
    HStack(spacing: 0) {
      Color(red: 1, green: 0, blue: 1)
      Color(red: 0, green: 1, blue: 1)
      Color(red: 1, green: 1, blue: 0)
      ForEach(0..<24) { bit in
        ((payload >> bit) & 1 == 1 ? Color.white : Color.black)
      }
      Color.red
    }
    .frame(width: 168, height: 12)
    .transaction { $0.animation = nil }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
