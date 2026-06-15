import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Python pixel-equivalence fixtures")
struct UInt16ImageTests {
  @Test("Rotation and horizontal flip match Python")
  func rotateAndFlip() throws {
    let fixture = try FixtureLoader.loadCase("rotate_flip")

    let actual = fixture.input.rotated(quarterTurns: 1, flipHorizontally: true)

    #expect(fixture.metadata.stage == "rotate")
    #expect(actual == fixture.expected)
    #expect([actual.height, actual.width, actual.channels] == fixture.metadata.outputShape)
  }

  @Test("Frame and aspect-ratio padding match Python")
  func frameAndAspectRatio() throws {
    let fixture = try FixtureLoader.loadCase("frame_aspect")

    let actual = fixture.input.addingFrame(
      percent: 10,
      aspectRatio: AspectRatio(width: 3, height: 2)
    )

    #expect(fixture.metadata.stage == "add_frame")
    #expect(actual == fixture.expected)
    #expect([actual.height, actual.width, actual.channels] == fixture.metadata.outputShape)
  }

  @Test("Processing parameters round trip through JSON")
  func processingParametersCodable() throws {
    let parameters = ProcessingParameters(
      borderCrop: 2.5,
      flip: true,
      rotation: 3,
      filmType: .colourNegative,
      gamma: 25,
      temperature: -10,
      saturation: 120,
      removeDust: true
    )

    let encoded = try JSONEncoder().encode(parameters)
    let decoded = try JSONDecoder().decode(ProcessingParameters.self, from: encoded)

    #expect(decoded == parameters)
  }

  @Test("Film modes expose only corrections that processing applies")
  func filmModeCorrectionCapabilities() {
    #expect(FilmType.cropOnly.supportsToneCorrections == false)
    #expect(FilmType.cropOnly.supportsColorCorrections == false)
    #expect(FilmType.blackAndWhiteNegative.supportsToneCorrections == true)
    #expect(FilmType.blackAndWhiteNegative.supportsColorCorrections == false)
    #expect(FilmType.colourNegative.supportsToneCorrections == true)
    #expect(FilmType.colourNegative.supportsColorCorrections == true)
    #expect(FilmType.slide.supportsToneCorrections == true)
    #expect(FilmType.slide.supportsColorCorrections == true)
  }

  @Test("Preview proxy fits within the requested dimension")
  func previewProxyResize() {
    let image = UInt16Image(
      width: 4,
      height: 2,
      channels: 1,
      pixels: [0, 1, 2, 3, 4, 5, 6, 7]
    )

    let resized = image.resizedToFit(maxDimension: 2)

    #expect(resized.width == 2)
    #expect(resized.height == 1)
    #expect(resized.pixels == [0, 2])
  }

  @Test("16-bit preview image preserves dimensions and component depth")
  func previewImage16() {
    let image = UInt16Image(width: 1, height: 1, channels: 3, pixels: [1, 2, 3])

    let preview = image.makePreviewCGImage16()

    #expect(preview?.width == 1)
    #expect(preview?.height == 1)
    #expect(preview?.bitsPerComponent == 16)
    #expect(preview?.bitsPerPixel == 64)
    let data = preview?.dataProvider?.data as Data?
    let components = data?.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    #expect(components == [3, 2, 1, .max])
  }
}
