import CryptoKit
import Foundation
import Testing

@testable import FilmScanConverterMac
@testable import FilmScanEngine

@Suite("Preview analysis equivalence")
struct PreviewAnalysisTests {
  @Test("CPU preview statistics match full-frame normalization", arguments: [1, 3])
  func statisticsMatchFullFrameNormalization(channels: Int) throws {
    for pixelCount in [1, 17, 65_535, 65_536, 65_537, 131_077] {
      let image = analysisBenchmarkImage(width: pixelCount, height: 1, channels: channels)
      let normalized = image.pixels.flatMap { value -> [Double] in
        Array(repeating: Double(value) / 65_535, count: channels == 1 ? 3 : 1)
      }
      let linear = RenderReadyLinearImage(width: pixelCount, height: 1, pixels: normalized)
      for limit in [1, 11, 65_536, Int.max] {
        #expect(
          image.previewStatistics(maximumSampleCount: limit)
            == linear.statistics(maximumSampleCount: limit))
      }
      let actual = try #require(AppModel.previewStatistics(for: image))
      #expect(actual == linear.statistics())
      #expect(actual.totalPixelCount == pixelCount)
      #expect(actual.sampleCount == min(pixelCount, 65_536))
    }
  }

  @Test("CPU preview statistics reject unsupported channel layouts", arguments: [2, 4])
  func unsupportedChannels(channels: Int) {
    let image = analysisBenchmarkImage(width: 1, height: 1, channels: channels)
    #expect(AppModel.previewStatistics(for: image) == nil)
  }

  @Test("Darkroom analysis and output retain the pre-optimization bytes")
  func densityPrintReference() {
    // Captured before the optimization, from 42c1943 on Apple Silicon with
    // Swift 6.1.2. Hash the complete analysis followed by UInt16 output, both
    // in little-endian order. Inputs cover ties, quantization, and texture.
    let expected = [
      [
        "3b353f896900c625227ff280d3538b0508ac9913888048c6fcbfd1a497073d52",
        "03fc7aa2f957cc2d13d318876c81221246c076a529e4e19aa0c2ace17a9bac85",
        "0111697a8f4c32a2fe107c636db6cd8f080988f0237e3f1566abb7967f9e41df",
      ],
      [
        "83ee7b005b79c2074c80d3e4500b3eced71add8eb167955354ce36caeba60c52",
        "c8f9ffe781e78ecf76cb52eef8d6ac0bfa2eadd3dd0e029797b1bdfa2f1114d4",
        "59ea657e6da18d41f1edc57974ef44bfb8ac42f33c21f282225dd33e86e26faa",
      ],
      [
        "d8c46cdd8088c13a6431e368d0ee073efba26ef0bf25b560f2c198c09bc92312",
        "1abfd6ddf0dc508179f2a9437f07ec974e98b4eddb0c35f45380e3e24818197d",
        "507441def5d3d893d113b18a791aa19bf707964545e1e46f5a628d30aae60eee",
      ],
    ]
    for kind in 0..<3 {
      let original = analysisBenchmarkImage(width: 256, height: 192, flat: kind == 0)
      let image = UInt16Image(
        width: original.width, height: original.height, channels: 3,
        pixels: kind == 1 ? original.pixels.map { ($0 / 8192) * 8192 } : original.pixels)
      for (paperIndex, paper) in [
        DensityPaperProfileCatalog.neutral,
        DensityPaperProfileCatalog.fujiCrystalArchive,
        DensityPaperProfileCatalog.kodakEnduraPremier,
      ].enumerated() {
        let analysis = DensityPrintProcessing.analyze(
          image: image, profile: NegativeDensityProfileCatalog.harmanPhoenixII, paper: paper)
        let rendered = DensityPrintProcessing.apply(image: image, analysis: analysis)
        let channels = [
          analysis.unmixBlue, analysis.unmixGreen, analysis.unmixRed,
          analysis.floors, analysis.ceils, analysis.slopes, analysis.pivots,
          analysis.curvatures, analysis.paperDMin,
          analysis.dyeMixBlue, analysis.dyeMixGreen, analysis.dyeMixRed,
        ]
        let scalars =
          channels.flatMap { [$0.blue, $0.green, $0.red] } + [
            analysis.paperDMax, analysis.paperMidtoneGamma, analysis.paperGammaWidth,
            analysis.toeSharpnessBase, analysis.shoulderSharpnessBase,
            analysis.toeHeight, analysis.shoulderHeight, analysis.referenceLinear,
          ]
        var data = scalars.map { $0.bitPattern.littleEndian }.withUnsafeBytes { Data($0) }
        rendered.pixels.map(\.littleEndian).withUnsafeBytes { data.append(contentsOf: $0) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == expected[kind][paperIndex], "\(kind) / \(paper.id.rawValue)")
      }
    }
  }
}
