import CoreGraphics
import CoreImage
import FilmScanEngine
import Foundation
import Metal
import Testing

@testable import FilmScanConverterMac
@testable import FilmScanPreviewRenderer

@Suite(
  "Shared Metal preview output",
  .enabled(
    if: MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true,
    "Shared preview output requires a unified-memory Metal device"))
struct SharedPreviewBitmapTests {
  @Test("Shared output preserves row order, offset extents, crops and quarter turns")
  func geometryAndPackingMatchCoreImage() throws {
    let source = try numericImage(width: 73, height: 47)
    let context = CIContext(options: [
      .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf,
    ])
    let images = [
      source,
      source.transformed(by: CGAffineTransform(translationX: -13, y: 19)),
      source.cropped(to: CGRect(x: 7, y: 5, width: 37, height: 23)),
      source.oriented(.right),
      source.oriented(.leftMirrored),
    ]
    for image in images {
      let shared = try #require(StillPreviewRenderer.sharedBitmap(image))
      let expected = try #require(
        context.createCGImage(
          image, from: image.extent, format: .RGBA8,
          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false))
      #expect(shared.width == expected.width && shared.height == expected.height)
      #expect(shared.bitsPerPixel == 32 && shared.bitsPerComponent == 8)
      #expect(shared.bytesPerRow >= shared.width * 4)
      #expect(try pixels(shared) == pixels(expected))
    }
  }

  @Test("Retained bitmap pixels survive source release and subsequent GPU writes")
  func providerOwnsImmutableStorage() throws {
    let retained = try autoreleasepool {
      try #require(StillPreviewRenderer.sharedBitmap(numericImage(width: 79, height: 53)))
    }
    let before = try pixels(retained)
    for value in [0.0, 0.25, 0.75, 1.0] {
      try autoreleasepool {
        let other = CIImage(color: CIColor(red: value, green: 1 - value, blue: value))
          .cropped(to: CGRect(x: 0, y: 0, width: 79, height: 53))
        let output = try #require(StillPreviewRenderer.sharedBitmap(other))
        #expect(try pixels(output) != before)
      }
    }
    #expect(try pixels(retained) == before)
    #expect(StillPreviewRenderer.statistics(for: retained)?.sampleCount == 79 * 53)
  }

  @Test("Large production previews publish complete pixels with padded row accounting")
  @MainActor
  func completeProductionRaster() throws {
    let width = 2053
    let height = 2048
    let values = (0..<(width * height * 3)).map { UInt16(($0 * 37) % 256) * 257 }
    let image = UInt16Image(width: width, height: height, channels: 3, pixels: values)
    let renderer = try #require(StillPreviewRenderer(image: image))
    let first = try #require(
      renderer.render(parameters: .init(filmType: .cropOnly), showOriginal: true))
    #expect(first.width == width && first.height == height)
    #expect(first.bytesPerRow >= width * 4)
    let before = try pixels(first)
    // An independently packed CPU source guards channel order and every row.
    let expected = try #require(image.makePreviewCGImage())
    let reference = try pixels(expected)
    #expect(
      stride(from: 0, to: before.count, by: 4).allSatisfy { index in
        before[index..<index + 3] == reference[index..<index + 3]
      })
    let parameters = ProcessingParameters(
      filmType: .slide, curveEnabled: true,
      curveControlPoints: [
        .init(input: 0, output: 0.02), .init(input: 0.4, output: 0.3),
        .init(input: 1, output: 0.98),
      ],
      photoAdjustments: .init(exposureEV: 1, temperatureShiftMired: 12, saturation: 0.15))
    let edited = try #require(renderer.render(parameters: parameters, showOriginal: false))
    #expect(edited.width == width && edited.height == height)
    #expect(try pixels(edited) != before)
    // A complete normalized region uses the original createCGImage writer.
    // Compare both materializers with active curves/color at the same resolution.
    let originalWriter = try #require(
      renderer.render(
        parameters: parameters, showOriginal: false,
        normalizedRegion: CGRect(x: 0, y: 0, width: 1, height: 1)))
    #expect(try pixels(edited) == pixels(originalWriter))
    #expect(try pixels(first) == before)
    let nativeImage = PreviewBitmap.nsImage(from: first)
    #expect(try pixels(#require(PreviewBitmap.cgImage(from: nativeImage))) == before)
    let bounded = try #require(
      renderer.render(parameters: parameters, showOriginal: false, maximumDimension: 1000))
    #expect(max(bounded.width, bounded.height) <= 1000)
  }

  @Test("Unsupported destination bounds stay on the existing renderer path")
  func unsupportedBounds() {
    let solid = CIImage(color: .white)
    #expect(StillPreviewRenderer.sharedBitmap(solid) == nil)
    #expect(
      StillPreviewRenderer.sharedBitmap(
        solid.cropped(to: CGRect(x: 0, y: 0, width: 16_385, height: 1))) == nil)
  }

  private func numericImage(width: Int, height: Int) throws -> CIImage {
    let image = UInt16Image(
      width: width, height: height, channels: 3,
      pixels: (0..<(width * height * 3)).map { UInt16(($0 * 3571) % 65_536) })
    return CIImage(
      bitmapData: try #require(image.rgba16Data()), bytesPerRow: width * 8,
      size: CGSize(width: width, height: height), format: .RGBA16, colorSpace: nil)
  }

  private func pixels(_ image: CGImage) throws -> [UInt8] {
    let data = try #require(image.dataProvider?.data)
    let pointer = try #require(CFDataGetBytePtr(data))
    return (0..<image.height).flatMap { y in
      Array(UnsafeBufferPointer(start: pointer + y * image.bytesPerRow, count: image.width * 4))
    }
  }
}
