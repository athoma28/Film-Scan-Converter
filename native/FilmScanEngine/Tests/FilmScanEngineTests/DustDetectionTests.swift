import Testing

@testable import FilmScanEngine

@Suite("Dust detection")
struct DustDetectionTests {
  @Test("Default dust mask matches the frozen Python OpenCV reference")
  func defaultMaskParity() throws {
    let fixture = try FixtureLoader.loadCase("dust_mask_default")

    let actual = DustDetection.findMask(
      in: fixture.input,
      parameters: DustDetectionParameters()
    )

    #expect(fixture.metadata.stage == "find_dust")
    #expect(actual == fixture.expected)
    #expect(actual.channels == 1)
  }

  @Test("Border exclusion and tuned settings match the Python reference")
  func ignoredBorderParity() throws {
    let fixture = try FixtureLoader.loadCase("dust_mask_border_ignored")

    let actual = DustDetection.findMask(
      in: fixture.input,
      parameters: DustDetectionParameters(
        thresholdPercent: 18,
        maximumParticleArea: 28,
        closingIterations: 2,
        ignoredBorderPercent: SIMD2(12, 8)
      )
    )

    #expect(actual == fixture.expected)
  }

  @Test("Particle filtering uses OpenCV contour area rather than pixel count")
  func contourAreaGateParity() throws {
    let fixture = try FixtureLoader.loadCase("dust_mask_contour_area_gate")

    let actual = DustDetection.findMask(
      in: fixture.input,
      parameters: DustDetectionParameters(
        thresholdPercent: 18,
        maximumParticleArea: 20,
        closingIterations: 2,
        ignoredBorderPercent: SIMD2(12, 8)
      )
    )

    #expect(actual == fixture.expected)
  }

  @Test("Dust detection is deterministic and does not modify its input")
  func deterministicAndNonMutating() {
    let image = UInt16Image(
      width: 5,
      height: 4,
      channels: 3,
      pixels: (0..<(5 * 4 * 3)).map { UInt16($0 * 997) }
    )
    let original = image

    let first = DustDetection.findMask(in: image)
    let second = DustDetection.findMask(in: image)

    #expect(first == second)
    #expect(image == original)
    #expect(first.width == image.width)
    #expect(first.height == image.height)
  }
}
