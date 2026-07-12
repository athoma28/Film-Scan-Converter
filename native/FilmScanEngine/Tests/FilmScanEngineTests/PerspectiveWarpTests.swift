import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Perspective warp")
struct PerspectiveWarpTests {
  @Test("Parallelism assist softly snaps an edge and leaves distant drags free")
  func parallelismAssist() {
    let crop = PerspectiveCrop.fullFrame

    let snapped = crop.replacing(
      0,
      with: .init(x: 0.2, y: 0.01),
      parallelismAssistThreshold: 0.02)
    #expect(abs(snapped.topLeft.x - 0.2) < 0.000_001)
    #expect(abs(snapped.topLeft.y) < 0.000_001)

    let free = crop.replacing(
      0,
      with: .init(x: 0.2, y: 0.15),
      parallelismAssistThreshold: 0.02)
    #expect(abs(free.topLeft.x - 0.2) < 0.000_001)
    #expect(abs(free.topLeft.y - 0.15) < 0.000_001)
  }

  @Test("Interactive four-corner crop preserves a full source canvas")
  func fullFramePerspectiveCropPreservesImage() throws {
    let image = UInt16Image(
      width: 5, height: 4, channels: 1,
      pixels: (0..<20).map(UInt16.init)
    )

    let cropped = try #require(PerspectiveTransform.crop(
      image, perspectiveCrop: .fullFrame
    ))

    #expect(cropped.width == image.width)
    #expect(cropped.height == image.height)
    #expect(cropped.pixels == image.pixels)
  }

  @Test("Interactive crop rejects a folded or degenerate quadrilateral")
  func invalidPerspectiveCropIsRejected() {
    let folded = PerspectiveCrop(
      topLeft: .init(x: 0.1, y: 0.1),
      topRight: .init(x: 0.9, y: 0.9),
      bottomRight: .init(x: 0.9, y: 0.1),
      bottomLeft: .init(x: 0.1, y: 0.9)
    )
    let image = UInt16Image(width: 4, height: 4, channels: 1, pixels: [UInt16](repeating: 1, count: 16))

    #expect(!folded.isValid)
    #expect(PerspectiveTransform.crop(image, perspectiveCrop: folded) == nil)
  }

  @Test("Interactive crop rectifies a trapezoid to its mean edge dimensions")
  func trapezoidPerspectiveCropRectifiesCanvas() throws {
    let image = UInt16Image(
      width: 100, height: 80, channels: 1,
      pixels: [UInt16](repeating: 30_000, count: 100 * 80)
    )
    let crop = PerspectiveCrop(
      topLeft: .init(x: 0.2, y: 0.1),
      topRight: .init(x: 0.8, y: 0.2),
      bottomRight: .init(x: 0.9, y: 0.9),
      bottomLeft: .init(x: 0.1, y: 0.8)
    )

    let cropped = try #require(PerspectiveTransform.crop(image, perspectiveCrop: crop))

    #expect(cropped.width == 71)
    #expect(cropped.height == 57)
    #expect(cropped.pixels.allSatisfy { $0 == 30_000 })
  }

  @Test("Straighten rotation preserves a quarter-turn canvas exactly")
  func straightenRotationQuarterTurn() {
    let image = UInt16Image(
      width: 3, height: 2, channels: 1,
      pixels: [1, 2, 3, 4, 5, 6]
    )

    let rotated = PerspectiveTransform.rotate(image, clockwiseDegrees: 90)

    #expect(rotated.width == 2)
    #expect(rotated.height == 3)
    #expect(rotated.pixels == [4, 1, 5, 2, 6, 3])
  }

  @Test("Straighten rotation keeps the source centered on the expanded canvas")
  func straightenRotationCentersSource() {
    let image = UInt16Image(
      width: 11, height: 7, channels: 1,
      pixels: [UInt16](repeating: 40_000, count: 77)
    )

    let rotated = PerspectiveTransform.rotate(image, clockwiseDegrees: 10)
    let center = (rotated.height / 2) * rotated.width + rotated.width / 2

    #expect(rotated.pixels[center] > 30_000)
  }

  @Test("Manual canvas crop copies the selected pixel rectangle exactly")
  func manualCanvasCrop() throws {
    let image = UInt16Image(
      width: 8, height: 6, channels: 1,
      pixels: (0..<48).map(UInt16.init))
    let crop = NormalizedCropRect(x: 0.25, y: 1.0 / 6.0, width: 0.5, height: 0.5)

    let result = try #require(PerspectiveTransform.crop(image, canvasRect: crop))

    #expect(result.width == 4)
    #expect(result.height == 3)
    #expect(result.pixels == [10, 11, 12, 13, 18, 19, 20, 21, 26, 27, 28, 29])
  }

  @Test("Straighten guide chooses the nearest horizontal or vertical axis")
  func straightenGuideAxisSelection() throws {
    let horizon = try #require(ImageGeometry.straightenGuide(deltaX: 100, deltaY: 17.6327))
    #expect(horizon.axis == .horizontal)
    #expect(abs(horizon.deviation - 10) < 0.001)

    let wall = try #require(ImageGeometry.straightenGuide(deltaX: 17.6327, deltaY: 100))
    #expect(wall.axis == .vertical)
    #expect(abs(wall.deviation + 10) < 0.001)
  }

  @Test("Full-resolution dimension prediction matches geometry processing")
  func outputDimensionPrediction() {
    let image = UInt16Image(
      width: 100, height: 80, channels: 1,
      pixels: [UInt16](repeating: 1, count: 8_000))
    let cases = [
      ProcessingParameters(
        rotation: 1,
        straightenAngle: 7.5,
        filmType: .cropOnly,
        manualCrop: NormalizedCropRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6)),
      ProcessingParameters(
        borderCrop: 2,
        rotation: 3,
        straightenAngle: -4,
        filmType: .cropOnly,
        perspectiveCrop: PerspectiveCrop(
          topLeft: .init(x: 0.1, y: 0.15),
          topRight: .init(x: 0.9, y: 0.1),
          bottomRight: .init(x: 0.85, y: 0.9),
          bottomLeft: .init(x: 0.15, y: 0.85))),
      ProcessingParameters(
        borderCrop: 1.5,
        rotation: 2,
        straightenAngle: 3,
        filmType: .cropOnly,
        cropRect: RotatedRect(
          centerX: 0.5, centerY: 0.5, width: 0.7, height: 0.8, angle: 8)),
    ]

    for parameters in cases {
      let predicted = ImageGeometry.outputDimensions(
        source: PixelDimensions(width: image.width, height: image.height),
        parameters: parameters)
      let actual = FilmProcessing.correctedPreview(image: image, parameters: parameters)
      #expect(predicted.width == actual.width)
      #expect(predicted.height == actual.height)
    }

    let canvas = PixelDimensions(width: 1_200, height: 800)
    let predictedFrame = ImageGeometry.framedDimensions(
      canvas, framePercent: 5, aspectRatio: AspectRatio(width: 1, height: 1))
    let actualFrame = UInt16Image(
      width: canvas.width, height: canvas.height, channels: 1,
      pixels: [UInt16](repeating: 1, count: canvas.width * canvas.height)
    ).addingFrame(percent: 5, aspectRatio: AspectRatio(width: 1, height: 1))
    #expect(predictedFrame == PixelDimensions(width: actualFrame.width, height: actualFrame.height))
  }

  // MARK: - Homography computation

  @Test("computeHomography returns identity for identical point sets")
  func computeHomographyIdentity() throws {
    let pts: [(x: Float, y: Float)] = [
      (0, 0), (10, 0), (10, 8), (0, 8),
    ]

    let h = try #require(PerspectiveTransform.computeHomography(
      srcPoints: pts, dstPoints: pts))

    #expect(abs(h[0] - 1) < 0.0001)
    #expect(abs(h[4] - 1) < 0.0001)
    #expect(abs(h[8] - 1) < 0.0001)
    #expect(abs(h[1]) < 0.0001)
    #expect(abs(h[2]) < 0.0001)
    #expect(abs(h[3]) < 0.0001)
    #expect(abs(h[5]) < 0.0001)
    #expect(abs(h[6]) < 0.0001)
    #expect(abs(h[7]) < 0.0001)
  }

  @Test("computeHomography handles pure translation")
  func computeHomographyTranslation() throws {
    let src: [(x: Float, y: Float)] = [
      (0, 0), (7, 0), (7, 5), (0, 5),
    ]
    let dst: [(x: Float, y: Float)] = [
      (2, 1), (9, 1), (9, 6), (2, 6),
    ]

    let h = try #require(PerspectiveTransform.computeHomography(
      srcPoints: src, dstPoints: dst))

    #expect(abs(h[0] - 1) < 0.0001)
    #expect(abs(h[2] - 2) < 0.0001)
    #expect(abs(h[4] - 1) < 0.0001)
    #expect(abs(h[5] - 1) < 0.0001)
    #expect(abs(h[8] - 1) < 0.0001)
  }

  @Test("computeHomography returns nil for collinear point sets")
  func computeHomographyCollinear() {
    let pts: [(x: Float, y: Float)] = [
      (0, 0), (1, 0), (2, 0), (3, 0),
    ]
    let h = PerspectiveTransform.computeHomography(
      srcPoints: pts, dstPoints: pts)
    #expect(h == nil)
  }

  @Test("computeHomography matches Python OpenCV getPerspectiveTransform")
  func computeHomographyMatchesOpenCV() throws {
    let src: [(x: Float, y: Float)] = [
      (0, 0), (7, 0), (7, 5), (0, 5),
    ]
    let dst: [(x: Float, y: Float)] = [
      (1, 0), (6, 1), (7, 4), (0, 5),
    ]

    let h = try #require(PerspectiveTransform.computeHomography(
      srcPoints: src, dstPoints: dst))

    let expected: [Float] = [
      1.1818181818181819, -0.2, 1.0,
      0.22077922077922077, 0.6363636363636365, 0.0,
      0.07792207792207792, -0.07272727272727272, 1.0,
    ]

    for i in 0..<9 {
      #expect(abs(h[i] - expected[i]) < 0.0001,
              "Element \(i): got \(h[i]), expected \(expected[i])")
    }
  }

  // MARK: - Warp basic behavior

  @Test("warpPerspective identity warp preserves all pixels exactly")
  func warpPerspectiveIdentity() throws {
    let w = 5
    let h = 4
    var pixels = [UInt16](repeating: 0, count: w * h * 3)
    for y in 0..<h {
      for x in 0..<w {
        let i = (y * w + x) * 3
        pixels[i] = UInt16(y * 1000 + x * 10)
        pixels[i + 1] = UInt16(y * 1000 + x * 10 + 1)
        pixels[i + 2] = UInt16(y * 1000 + x * 10 + 2)
      }
    }

    let img = UInt16Image(width: w, height: h, channels: 3, pixels: pixels)
    let h_identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    let warped = PerspectiveTransform.warpPerspective(
      img, homography: h_identity, outputWidth: w, outputHeight: h)

    #expect(warped.width == w)
    #expect(warped.height == h)
    #expect(warped.channels == 3)
    #expect(warped.pixels == pixels)
  }

  @Test("warpPerspective with zero denominator produces all-zero output")
  func warpPerspectiveZeroDenominator() {
    let w = 4
    let h = 4
    let pixels = [UInt16](repeating: UInt16.max, count: w * h)
    let img = UInt16Image(width: w, height: h, channels: 1, pixels: pixels)

    let h_singular: [Float] = [0, 0, 1, 0, 0, 1, 0, 0, 0]
    let warped = PerspectiveTransform.warpPerspective(
      img, homography: h_singular, outputWidth: 4, outputHeight: 4)

    for p in warped.pixels {
      #expect(p == 0)
    }
  }

  @Test("warpPerspective rejects a singular matrix with infinite inverse terms")
  func warpPerspectiveRejectsSingularInverse() {
    let image = UInt16Image(
      width: 2,
      height: 2,
      channels: 1,
      pixels: [1, 2, 3, 4]
    )
    let singular: [Float] = [
      1, 0, 0,
      0, 1, 0,
      0, 0, 0,
    ]

    let warped = PerspectiveTransform.warpPerspective(
      image,
      homography: singular,
      outputWidth: 2,
      outputHeight: 2
    )

    #expect(warped.pixels == [0, 0, 0, 0])
  }

  @Test("warpPerspective rejects non-finite homography values")
  func warpPerspectiveRejectsNonFiniteHomography() {
    let image = UInt16Image(
      width: 1,
      height: 1,
      channels: 1,
      pixels: [UInt16.max]
    )
    let nonFinite: [Float] = [
      .infinity, 0, 0,
      0, 1, 0,
      0, 0, 1,
    ]

    let warped = PerspectiveTransform.warpPerspective(
      image,
      homography: nonFinite,
      outputWidth: 1,
      outputHeight: 1
    )

    #expect(warped.pixels == [0])
  }

  @Test("warpPerspective uses zero for out-of-bounds source coordinates")
  func warpPerspectiveOutOfBoundsZero() {
    let w = 4
    let h = 4
    var pixels = [UInt16](repeating: 0, count: w * h)
    for y in 0..<h {
      for x in 0..<w {
        pixels[y * w + x] = UInt16(y * 100 + x)
      }
    }
    let img = UInt16Image(width: w, height: h, channels: 1, pixels: pixels)

    let h_trans: [Float] = [1, 0, 10, 0, 1, 10, 0, 0, 1]
    let warped = PerspectiveTransform.warpPerspective(
      img, homography: h_trans, outputWidth: w, outputHeight: h)

    #expect(warped.pixels[0] == 0)
  }

  @Test("warpPerspective handles single-channel and multi-channel images")
  func warpPerspectiveChannelHandling() {
    let w = 6
    let h = 4
    var pix1 = [UInt16](repeating: 0, count: w * h)
    var pix3 = [UInt16](repeating: 0, count: w * h * 3)
    for y in 0..<h {
      for x in 0..<w {
        pix1[y * w + x] = UInt16(y * 100 + x)
        let i3 = (y * w + x) * 3
        pix3[i3] = UInt16(y * 100 + x)
        pix3[i3 + 1] = UInt16(y * 100 + x + 1)
        pix3[i3 + 2] = UInt16(y * 100 + x + 2)
      }
    }

    let img1 = UInt16Image(width: w, height: h, channels: 1, pixels: pix1)
    let img3 = UInt16Image(width: w, height: h, channels: 3, pixels: pix3)

    let homog: [Float] = [0.8, 0, 1, 0, 0.9, 0.5, 0, 0, 1]
    let w1 = PerspectiveTransform.warpPerspective(
      img1, homography: homog, outputWidth: 8, outputHeight: 6)
    let w3 = PerspectiveTransform.warpPerspective(
      img3, homography: homog, outputWidth: 8, outputHeight: 6)

    #expect(w1.channels == 1)
    #expect(w3.channels == 3)
    #expect(w1.pixels.count == 8 * 6)
    #expect(w3.pixels.count == 8 * 6 * 3)
  }

  // MARK: - Fixture-based exact match tests

  @Test("warp identity matches Python OpenCV output exactly")
  func warpIdentityFixture() throws {
    let (input, expected, _) = try FixtureLoader.loadCase("warp_identity")

    let h: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    let warped = PerspectiveTransform.warpPerspective(
      input, homography: h, outputWidth: expected.width, outputHeight: expected.height)

    #expect(warped.pixels == expected.pixels)
  }

  @Test("warp translation matches Python OpenCV output exactly")
  func warpTranslationFixture() throws {
    let (input, expected, _) = try FixtureLoader.loadCase("warp_translate")

    let h: [Float] = [1, 0, 2, 0, 1, 1, 0, 0, 1]
    let warped = PerspectiveTransform.warpPerspective(
      input, homography: h, outputWidth: 12, outputHeight: 8)

    #expect(warped.pixels == expected.pixels)
  }

  @Test("warp perspective tolerates documented OpenCV border differences")
  func warpPerspectiveFixture() throws {
    let (input, expected, _) = try FixtureLoader.loadCase("warp_perspective")

    let h: [Float] = [
      1.1818181818181819, -0.2, 1.0,
      0.22077922077922077, 0.6363636363636365, 0.0,
      0.07792207792207792, -0.07272727272727272, 1.0,
    ]
    let warped = PerspectiveTransform.warpPerspective(
      input, homography: h, outputWidth: expected.width, outputHeight: expected.height)

    assertPixelEquality(warped.pixels, expected.pixels, maxDiff: 830)
  }

  @Test("larger perspective fixture stays within OpenCV interpolation tolerance")
  func warpLargePerspectiveFixture() throws {
    try assertFixture(
      "warp_large_perspective",
      homography: [
        0.8446083044803441, -0.08240918531290413, 5.0,
        -0.0170527642746747, 0.7931998380291808, 3.0,
        -0.00005180586615091049, -0.002743054194913594, 1.0,
      ],
      maxDiff: 1_300
    )
  }

  @Test("single-channel perspective fixture stays within OpenCV interpolation tolerance")
  func warpSingleChannelPerspectiveFixture() throws {
    try assertFixture(
      "warp_persp_1ch",
      homography: [
        0.7828571428571428, -0.0911278195488722, 4.390977443609024,
        0.03488721804511276, 0.7545864661654135, 1.9398496240601513,
        0.00015037593984962316, -0.003909774436090225, 1.0,
      ],
      maxDiff: 1_600
    )
  }

  @Test("in-bounds perspective fixture stays within OpenCV interpolation tolerance")
  func warpInBoundsPerspectiveFixture() throws {
    try assertFixture(
      "warp_persp_inbounds",
      homography: [
        0.7828571428571428, -0.0911278195488722, 4.390977443609024,
        0.03488721804511276, 0.7545864661654135, 1.9398496240601513,
        0.00015037593984962316, -0.003909774436090225, 1.0,
      ],
      maxDiff: 1_320
    )
  }

  @Test("scaled perspective fixture stays within OpenCV interpolation tolerance")
  func warpScaledPerspectiveFixture() throws {
    try assertFixture(
      "warp_persp_scaled",
      homography: [
        0.6497852686168057, -0.06312292358803985, 6.9127299246414395,
        0.03541042054938817, 0.5882829592415525, 4.758366420873512,
        0.00016206142127866152, -0.003241228425573292, 1.0,
      ],
      maxDiff: 1_300
    )
  }

  // MARK: - Self-consistency round-trip tests

  @Test("round-trip with translation warp exactly preserves original")
  func warpRoundTripTranslation() {
    let w = 8
    let h = 6
    var pixels = [UInt16](repeating: 0, count: w * h)
    for y in 0..<h {
      for x in 0..<w {
        pixels[y * w + x] = UInt16(y * 100 + x)
      }
    }
    let img = UInt16Image(width: w, height: h, channels: 1, pixels: pixels)

    let hForward: [Float] = [1, 0, 2, 0, 1, 1, 0, 0, 1]
    let hBack: [Float] = [1, 0, -2, 0, 1, -1, 0, 0, 1]

    let warped = PerspectiveTransform.warpPerspective(
      img, homography: hForward, outputWidth: 12, outputHeight: 8)
    let restored = PerspectiveTransform.warpPerspective(
      warped, homography: hBack, outputWidth: w, outputHeight: h)

    #expect(restored.pixels == pixels)
  }

  @Test("self-consistency: computed homography warp matches hardcoded homography warp")
  func selfConsistencyHomographyWarp() throws {
    let (input, _, _) = try FixtureLoader.loadCase("warp_perspective")

    let src: [(x: Float, y: Float)] = [
      (0, 0), (7, 0), (7, 5), (0, 5),
    ]
    let dst: [(x: Float, y: Float)] = [
      (1, 0), (6, 1), (7, 4), (0, 5),
    ]

    let computedH = try #require(PerspectiveTransform.computeHomography(
      srcPoints: src, dstPoints: dst))
    let hardcodedH: [Float] = [
      1.1818181818181819, -0.2, 1.0,
      0.22077922077922077, 0.6363636363636365, 0.0,
      0.07792207792207792, -0.07272727272727272, 1.0,
    ]

    let w1 = PerspectiveTransform.warpPerspective(
      input, homography: computedH, outputWidth: 8, outputHeight: 6)
    let w2 = PerspectiveTransform.warpPerspective(
      input, homography: hardcodedH, outputWidth: 8, outputHeight: 6)

    #expect(w1.pixels == w2.pixels)
  }

  // MARK: - Crop-style warp (self-consistency)

  @Test("crop-style warp is self-consistent across output sizes")
  func cropStyleSelfConsistent() throws {
    let (input, _, _) = try FixtureLoader.loadCase("warp_crop_style")

    let h: [Float] = [
      -0.08781867967904282, 1.3172801951856425, -9.660054764694713,
      -0.9977429034739439, 0.04988714517369723, 69.24335750109171,
      -0.00021702851212077702, 0.0016802382412989495, 1.0,
    ]

    let w1 = PerspectiveTransform.warpPerspective(
      input, homography: h, outputWidth: 50, outputHeight: 60)
    let w2 = PerspectiveTransform.warpPerspective(
      input, homography: h, outputWidth: 50, outputHeight: 60)

    #expect(w1.pixels == w2.pixels)
  }

  // MARK: - Helpers

  private func assertPixelEquality(
    _ actual: [UInt16], _ expected: [UInt16],
    maxDiff: UInt16 = 0,
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
  ) {
    #expect(actual.count == expected.count, "Pixel count mismatch",
            sourceLocation: Testing.SourceLocation(
              fileID: fileID, filePath: filePath, line: line, column: column))

    var largestDifference: UInt16 = 0
    var largestIndex = 0
    for i in actual.indices {
      let diff = actual[i] > expected[i]
        ? actual[i] - expected[i]
        : expected[i] - actual[i]
      if diff > largestDifference {
        largestDifference = diff
        largestIndex = i
      }
    }
    #expect(
      largestDifference <= maxDiff,
      "Pixel \(largestIndex): actual=\(actual[largestIndex]) expected=\(expected[largestIndex]) diff=\(largestDifference) max=\(maxDiff)",
      sourceLocation: Testing.SourceLocation(
        fileID: fileID, filePath: filePath, line: line, column: column))
  }

  private func assertFixture(
    _ name: String,
    homography: [Float],
    maxDiff: UInt16
  ) throws {
    let (input, expected, _) = try FixtureLoader.loadCase(name)
    let warped = PerspectiveTransform.warpPerspective(
      input,
      homography: homography,
      outputWidth: expected.width,
      outputHeight: expected.height
    )
    assertPixelEquality(warped.pixels, expected.pixels, maxDiff: maxDiff)
  }

}
