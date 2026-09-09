import CoreGraphics
import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Crop aspect ratios")
struct CropAspectRatioTests {
  @Test("Ratio fitting preserves the center and stays inside landscape and portrait canvases")
  func centeredFit() throws {
    for canvas in [
      PixelDimensions(width: 6_001, height: 4_003), .init(width: 4_003, height: 6_001),
    ] {
      for preset in CropAspectRatio.allCases where preset != .free {
        let ratio = try #require(preset.normalizedRatio(in: canvas))
        for original in [
          NormalizedCropRect.fullFrame, .init(x: 0.2, y: 0.1, width: 0.6, height: 0.7),
        ] {
          let crop = original.fitted(toAspectRatio: ratio)
          #expect(crop.isValid)
          #expect(abs(crop.width / crop.height - ratio) < 1e-12)
          #expect(abs(crop.x + crop.width / 2 - original.x - original.width / 2) < 1e-12)
          #expect(abs(crop.y + crop.height / 2 - original.y - original.height / 2) < 1e-12)
          #expect(crop.width <= original.width && crop.height <= original.height)
          #expect(crop.fitted(toAspectRatio: ratio) == crop)
        }
      }
    }
    #expect(CropAspectRatio.free.normalizedRatio(in: .init(width: 600, height: 400)) == nil)
  }

  @Test("Every constrained handle keeps its opposite anchor at bounds and across the anchor")
  func handleAnchors() {
    for ratio in [0.25, 2.0 / 3, 1, 1.5, 4] {
      let origin = NormalizedCropRect(x: 0.1, y: 0.15, width: 0.8, height: 0.7)
        .fitted(toAspectRatio: ratio)
      for handle in NormalizedCropRect.Handle.allCases {
        let opposite = NormalizedCropRect.Handle(rawValue: (handle.rawValue + 4) % 8)!
        let anchor = origin.handlePosition(opposite)
        for x in [-1.0, 0, 0.35, 0.5, 0.9, 1, 2] {
          for y in [-1.0, 0, 0.35, 0.5, 0.9, 1, 2] {
            let crop = origin.movingHandle(
              handle, to: (x, y), minWidth: 0.01, minHeight: 0.02, aspectRatio: ratio)
            let nextAnchor = crop.handlePosition(opposite)
            #expect(crop.isValid)
            #expect(abs(crop.width / crop.height - ratio) < 1e-12)
            #expect(abs(nextAnchor.x - anchor.x) < 1e-12)
            #expect(abs(nextAnchor.y - anchor.y) < 1e-12)
            #expect(crop.width >= 0.01 - 1e-12 && crop.height >= 0.02 - 1e-12)
          }
        }
      }
    }
  }

  @Test("A constrained crop at an image edge stays valid even below the screen minimum")
  func edgeMinimum() {
    let crop = NormalizedCropRect(x: 0, y: 0, width: 0.001, height: 0.001)
    let result = crop.movingHandle(
      .topLeft, to: (-1, -1), minWidth: 0.1, minHeight: 0.1, aspectRatio: 2)
    #expect(result.isValid)
    #expect(abs(result.width / result.height - 2) < 1e-12)
    #expect(abs(result.maxX - crop.maxX) < 1e-12)
    #expect(abs(result.maxY - crop.maxY) < 1e-12)
  }

  @Test("Corner handles shrink when dragged inward along either axis")
  func inwardCornerDrag() {
    let origin = NormalizedCropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.4)
    for handle in [NormalizedCropRect.Handle.topLeft, .topRight, .bottomLeft, .bottomRight] {
      let start = origin.handlePosition(handle)
      let opposite = NormalizedCropRect.Handle(rawValue: (handle.rawValue + 4) % 8)!
      let anchor = origin.handlePosition(opposite)
      for target in [
        (x: (start.x + anchor.x) / 2, y: start.y),
        (x: start.x, y: (start.y + anchor.y) / 2),
      ] {
        let crop = origin.movingHandle(
          handle, to: target, minWidth: 0.01, minHeight: 0.01, aspectRatio: 1.5)
        #expect(crop.isValid)
        #expect(abs(crop.width - 0.3) < 1e-12)
        #expect(abs(crop.height - 0.2) < 1e-12)
      }
    }
  }

  @Test("Drawing ratios are independent of zoom, drag direction, and image offsets")
  func drawnCrop() {
    let imageRect = CGRect(x: 20, y: 40, width: 1_200, height: 800)
    let start = CGPoint(x: 620, y: 440)
    for ratio in [0.5, 1, 2] {
      for end in [
        CGPoint(x: 100, y: 90), CGPoint(x: 900, y: 90),
        CGPoint(x: 100, y: 790), CGPoint(x: 900, y: 790),
        CGPoint(x: -100, y: -100), CGPoint(x: 2_000, y: 2_000),
      ] {
        for zoom in [0.12, 1, 2] {
          let documentStart = PreviewOverlayGeometry.documentGesturePoint(
            CGPoint(x: start.x * zoom, y: start.y * zoom), magnification: zoom)
          let documentEnd = PreviewOverlayGeometry.documentGesturePoint(
            CGPoint(x: end.x * zoom, y: end.y * zoom), magnification: zoom)
          let rect = PreviewOverlayGeometry.drawnCropRect(
            from: documentStart, to: documentEnd, in: imageRect, aspectRatio: ratio)
          let crop = PreviewOverlayGeometry.normalizedCrop(for: rect, in: imageRect)
          #expect(crop.isValid)
          #expect(abs(crop.width / crop.height - ratio) < 1e-12)
          #expect(abs((end.x < start.x ? rect.maxX : rect.minX) - start.x) < 1e-9)
          #expect(abs((end.y < start.y ? rect.maxY : rect.minY) - start.y) < 1e-9)
        }
      }
    }
    #expect(
      PreviewOverlayGeometry.drawnCropRect(
        from: start, to: CGPoint(x: 100, y: 200), in: imageRect, aspectRatio: nil)
        == CGRect(x: 100, y: 200, width: 520, height: 240))
  }

  @Test("Old settings remain freeform and look transfer preserves the destination ratio")
  func settingsCompatibility() throws {
    let legacy = try JSONDecoder().decode(ProcessingParameters.self, from: Data("{}".utf8))
    #expect(legacy.manualCropAspectRatio == .free)
    var source = ProcessingParameters()
    source.manualCropAspectRatio = .landscape3x2
    source.photoAdjustments.exposureEV = 1
    var destination = ProcessingParameters()
    destination.manualCropAspectRatio = .portrait4x5
    destination.manualCrop = .init(x: 0.1, y: 0.2, width: 0.4, height: 0.6)
    let applied = CorrectionSettings(capturing: source).applying(to: destination)
    #expect(applied.manualCropAspectRatio == .portrait4x5)
    #expect(applied.manualCrop == destination.manualCrop)
    #expect(applied.photoAdjustments.exposureEV == 1)
    #expect(
      try JSONDecoder().decode(ProcessingParameters.self, from: JSONEncoder().encode(applied))
        == applied)
  }
}
