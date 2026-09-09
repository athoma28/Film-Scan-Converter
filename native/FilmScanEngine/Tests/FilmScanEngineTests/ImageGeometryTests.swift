import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Image geometry")
struct ImageGeometryTests {
  @Test("Straighten guide is unchanged when the same segment is drawn backwards")
  func straightenGuideDirectionInvariance() throws {
    let forward = try #require(ImageGeometry.straightenGuide(deltaX: 100, deltaY: 17.6327))
    let backward = try #require(ImageGeometry.straightenGuide(deltaX: -100, deltaY: -17.6327))
    #expect(forward.axis == backward.axis)
    #expect(abs(forward.deviation - backward.deviation) < 0.001)
  }

  @Test("Straighten guide ignores empty or non-finite input")
  func straightenGuideRejectsEmptyInput() {
    #expect(ImageGeometry.straightenGuide(deltaX: 0, deltaY: 0) == nil)
    #expect(ImageGeometry.straightenGuide(deltaX: .nan, deltaY: 1) == nil)
    #expect(ImageGeometry.straightenGuide(deltaX: 1, deltaY: .infinity) == nil)
  }

  @Test("Positive straighten deviation rotates the image counterclockwise")
  func straightenSignConvention() {
    var pixels = [UInt16](repeating: 0, count: 31 * 21)
    for y in 0..<21 {
      for x in 0..<31 {
        pixels[y * 31 + x] = UInt16(x * 1_000 + y)
      }
    }
    let image = UInt16Image(width: 31, height: 21, channels: 1, pixels: pixels)
    let clockwise = PerspectiveTransform.rotate(image, clockwiseDegrees: 8)
    let fromPositiveGuide = PerspectiveTransform.rotate(
      image, clockwiseDegrees: -8)
    #expect(clockwise.pixels != fromPositiveGuide.pixels)
  }

  @Test("Pixel bounds keep a one-pixel minimum and stay on the canvas")
  func pixelBoundsClamping() throws {
    let full = try #require(
      ImageGeometry.pixelBounds(
        for: NormalizedCropRect(x: 0, y: 0, width: 1, height: 1),
        imageWidth: 10, imageHeight: 8))
    #expect(full == (0, 0, 10, 8))

    let sliver = try #require(
      ImageGeometry.pixelBounds(
        for: NormalizedCropRect(x: 0, y: 0, width: 0.0001, height: 0.0001),
        imageWidth: 10, imageHeight: 8))
    #expect(sliver.width == 1)
    #expect(sliver.height == 1)

    #expect(
      ImageGeometry.pixelBounds(
        for: NormalizedCropRect(x: 0.5, y: 0.5, width: 0.6, height: 0.6),
        imageWidth: 10, imageHeight: 8) == nil)
  }

  @Test("Quarter-turn and zero straighten canvases keep source dimensions")
  func rotatedCanvasDimensionsSpecialCases() {
    let source = PixelDimensions(width: 12, height: 7)
    #expect(ImageGeometry.rotatedCanvasDimensions(source, clockwiseDegrees: 0) == source)
    #expect(
      ImageGeometry.rotatedCanvasDimensions(source, clockwiseDegrees: 90)
        == PixelDimensions(width: 7, height: 12))
    #expect(ImageGeometry.rotatedCanvasDimensions(source, clockwiseDegrees: 180) == source)
    let tilted = ImageGeometry.rotatedCanvasDimensions(source, clockwiseDegrees: 12)
    #expect(tilted.width > source.width)
    #expect(tilted.height > source.height)
  }

  @Test("Crop handles swap when dragged past the opposite edge")
  func cropHandleCrossingSwapsEdges() {
    let crop = NormalizedCropRect(x: 0.2, y: 0.25, width: 0.4, height: 0.3)
    let moved = crop.movingHandle(.left, to: (0.9, 0.4), minSize: 0.05)
    #expect(abs(moved.minX - 0.6) < 1e-9)
    #expect(abs(moved.maxX - 0.9) < 1e-9)
    #expect(abs(moved.minY - 0.25) < 1e-9)
    #expect(abs(moved.maxY - 0.55) < 1e-9)
  }

  @Test("Crop translation stays inside the canvas")
  func cropTranslationClampsToCanvas() {
    let crop = NormalizedCropRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
    let moved = crop.translated(dx: -1, dy: 1)
    #expect(moved.x == 0)
    #expect(abs(moved.y - 0.7) < 1e-9)
    #expect(moved.width == 0.3)
    #expect(moved.height == 0.3)
  }

  @Test("Crop handles keep a minimum size")
  func cropHandleEnforcesMinSize() {
    let crop = NormalizedCropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
    let squeezed = crop.movingHandle(.right, to: (0.21, 0.4), minSize: 0.1)
    #expect(squeezed.width + 1e-9 >= 0.1)
    #expect(squeezed.height + 1e-9 >= 0.1)
  }

  @Test("Crop handles keep independent minimum width and height")
  func cropHandleEnforcesIndependentMinSize() {
    let crop = NormalizedCropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
    let squeezed = crop.movingHandle(
      .right, to: (0.21, 0.4), minWidth: 0.15, minHeight: 0.05)
    #expect(squeezed.width + 1e-9 >= 0.15)
    #expect(abs(squeezed.height - 0.4) < 1e-9)
  }

  @Test("A collapsed perspective border does not change predicted output size")
  func collapsedPerspectiveInsetKeepsSourceSize() {
    let source = PixelDimensions(width: 40, height: 30)
    let parameters = ProcessingParameters(
      borderCrop: 100,
      filmType: .cropOnly,
      perspectiveCrop: .fullFrame)
    #expect(ImageGeometry.outputDimensions(source: source, parameters: parameters) == source)
  }
}
