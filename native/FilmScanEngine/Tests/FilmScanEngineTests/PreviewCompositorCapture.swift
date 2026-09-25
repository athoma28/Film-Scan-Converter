import AppKit
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

/// Test-only observation of the diagnostic window's composited revision marker.
/// Does not record other windows, audio, or image files. Callback latency includes
/// ScreenCaptureKit delivery; it is not physical scan-out or mouse-to-photon time.
@MainActor
final class PreviewCompositorCapture {
  struct Frame: Codable, Sendable {
    let revision: Int?
    let callbackMilliseconds: Double
    let presentationTimeSeconds: Double
  }

  struct Snapshot: Codable, Sendable {
    let frames: [Frame]
    let incompleteFrames: Int
    let discardedFrames: Int
    let width: Int
    let height: Int
    let requestedFramesPerSecond: Int
    let clockNote: String
  }

  enum CaptureError: Error {
    case permissionUnavailable, windowUnavailable, notStarted
  }

  private let sink: PreviewCompositorSink
  private var stream: SCStream?
  private var width = 0
  private var height = 0

  init(origin: ContinuousClock.Instant) {
    sink = PreviewCompositorSink(origin: origin)
  }

  func start(windowNumber: Int) async throws {
    // Never prompt for or request screen recording access from a benchmark.
    guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionUnavailable }
    let content = try await SCShareableContent.excludingDesktopWindows(
      true, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: { $0.windowID == windowNumber }) else {
      throw CaptureError.windowUnavailable
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    // One output pixel per window point is enough to read the binary marker.
    // The app still renders at its normal display scale.
    width = Int(window.frame.width.rounded(.up))
    height = Int(window.frame.height.rounded(.up))
    configuration.width = width
    configuration.height = height
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.queueDepth = 3
    configuration.showsCursor = false
    configuration.capturesAudio = false
    configuration.colorSpaceName = CGColorSpace.sRGB
    configuration.ignoreShadowsSingleWindow = true
    let capture = SCStream(filter: filter, configuration: configuration, delegate: nil)
    try capture.addStreamOutput(
      sink, type: .screen,
      sampleHandlerQueue: DispatchQueue(label: "FSC.preview-compositor-diagnostic"))
    try await capture.startCapture()
    stream = capture
  }

  func stop() async throws -> Snapshot {
    guard let stream else { throw CaptureError.notStarted }
    try await stream.stopCapture()
    self.stream = nil
    let result = sink.snapshot()
    return Snapshot(
      frames: result.frames, incompleteFrames: result.incomplete,
      discardedFrames: result.discarded, width: width, height: height,
      requestedFramesPerSecond: 120,
      clockNote:
        "callbackMilliseconds shares the trace ContinuousClock origin and includes capture delivery. presentationTimeSeconds is the ScreenCaptureKit sample PTS; only differences within that clock are used. A marker observes window composition, not physical screen scan-out."
    )
  }
}

private final class PreviewCompositorSink: NSObject, SCStreamOutput, @unchecked Sendable {
  private let origin: ContinuousClock.Instant
  private let lock = NSLock()
  private var frames: [PreviewCompositorCapture.Frame] = []
  private var incomplete = 0
  private var discarded = 0

  init(origin: ContinuousClock.Instant) {
    self.origin = origin
  }

  func snapshot() -> (frames: [PreviewCompositorCapture.Frame], incomplete: Int, discarded: Int) {
    lock.withLock { (frames, incomplete, discarded) }
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen else { return }
    let duration = origin.duration(to: .now)
    let milliseconds =
      Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1e15
    let attachments =
      CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
    guard let rawStatus = attachments?.first?[.status] as? Int,
      rawStatus == SCFrameStatus.complete.rawValue,
      let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
    else {
      lock.withLock { incomplete += 1 }
      return
    }
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard let address = CVPixelBufferGetBaseAddress(pixels) else { return }
    let width = CVPixelBufferGetWidth(pixels)
    let height = CVPixelBufferGetHeight(pixels)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    let bytes = UnsafeBufferPointer(
      start: address.assumingMemoryBound(to: UInt8.self), count: stride * height)
    let revision = PreviewRevisionMarker.decode(
      bytes, width: width, height: height, bytesPerRow: stride)
    let frame = PreviewCompositorCapture.Frame(
      revision: revision, callbackMilliseconds: milliseconds,
      presentationTimeSeconds: CMTimeGetSeconds(
        CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    lock.withLock {
      guard frames.count < 10_000 else {
        discarded += 1
        return
      }
      frames.append(frame)
    }
  }
}

/// Decode magenta/cyan/yellow anchors, 16 revision bits plus checksum (LSB first),
/// and a red terminator. Binary samples tolerate display color conversion.
enum PreviewRevisionMarker {
  static func decode(
    _ bytes: UnsafeBufferPointer<UInt8>, width: Int, height: Int, bytesPerRow: Int
  ) -> Int? {
    guard width > 28, height > 0, bytesPerRow >= width * 4,
      bytes.count >= bytesPerRow * height
    else { return nil }
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
      let offset = y * bytesPerRow + x * 4
      return (Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset]))
    }
    func matches(_ x: Int, _ y: Int, _ high: (Bool, Bool, Bool)) -> Bool {
      guard x >= 0, x < width else { return false }
      let c = rgb(x, y)
      return (high.0 ? c.0 > 180 : c.0 < 90)
        && (high.1 ? c.1 > 180 : c.1 < 90)
        && (high.2 ? c.2 > 180 : c.2 < 90)
    }
    for y in stride(from: 0, to: height, by: 3) {
      var x = 0
      while x < width - 28 {
        guard matches(x, y, (true, false, true)) else {
          x += 1
          continue
        }
        let runStart = x
        while x < width, matches(x, y, (true, false, true)) { x += 1 }
        let runWidth = x - runStart
        // Fractional placement and Retina downsampling can include or exclude
        // one edge pixel. Validate nearby pitches with all anchors and checksum.
        for cell in [runWidth, runWidth - 1, runWidth + 1] where (3...24).contains(cell) {
          for start in [runStart, runStart - 1, runStart + 1] {
            guard start >= 0, start + 28 * cell <= width,
              matches(start + cell + cell / 2, y, (false, true, true)),
              matches(start + 2 * cell + cell / 2, y, (true, true, false)),
              matches(start + 27 * cell + cell / 2, y, (true, false, false))
            else { continue }
            var packed = 0
            var valid = true
            for bit in 0..<24 {
              let px = start + (3 + bit) * cell + cell / 2
              if matches(px, y, (true, true, true)) {
                packed |= 1 << bit
              } else if !matches(px, y, (false, false, false)) {
                valid = false
                break
              }
            }
            let revision = packed & 0xffff
            let checksum = (revision & 255) ^ (revision >> 8) ^ 0xa5
            if valid, packed >> 16 == checksum { return revision }
          }
        }
      }
    }
    return nil
  }
}
