import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Native input and live preview contracts")
struct InputAndLivePreviewTests {
  @Test("Drop admission accepts supported images and RAW files case-insensitively")
  func supportedDropFiles() {
    let urls = [
      URL(fileURLWithPath: "/tmp/scan.RAF"),
      URL(fileURLWithPath: "/tmp/scan.dng"),
      URL(fileURLWithPath: "/tmp/preview.TIFF"),
      URL(fileURLWithPath: "/tmp/notes.txt"),
    ]

    #expect(FileDropPolicy.supportedFiles(from: urls) == Array(urls.prefix(3)))
  }

  @Test("Drop admission removes duplicates while preserving order")
  func deduplicatedDropFiles() {
    let first = URL(fileURLWithPath: "/tmp/a.raf")
    let second = URL(fileURLWithPath: "/tmp/b.jpg")

    #expect(FileDropPolicy.supportedFiles(from: [first, second, first]) == [first, second])
  }

  @Test("Drop admission and standard decoder share standard image extensions")
  func sharedStandardImageExtensions() {
    #expect(
      StandardImageDecoder.supportedExtensions.isSubset(of: FileDropPolicy.supportedExtensions))
    #expect(StandardImageDecoder.supportedExtensions.isDisjoint(with: FileDropPolicy.rawExtensions))
  }

  @Test("Live preview throttles frames to its target rate")
  func throttlesFrames() {
    var throttle = LivePreviewThrottle(maximumFramesPerSecond: 20)

    let first = throttle.shouldProcess(timestamp: 0)
    let tooSoon = throttle.shouldProcess(timestamp: 0.02)
    let boundary = throttle.shouldProcess(timestamp: 0.05)
    let later = throttle.shouldProcess(timestamp: 0.20)

    #expect(first)
    #expect(!tooSoon)
    #expect(boundary)
    #expect(later)
  }

  @Test("Live preview accepts timestamps after capture clock resets")
  func acceptsClockReset() {
    var throttle = LivePreviewThrottle(maximumFramesPerSecond: 30)

    let first = throttle.shouldProcess(timestamp: 5)
    let reset = throttle.shouldProcess(timestamp: 0)

    #expect(first)
    #expect(reset)
  }
}
