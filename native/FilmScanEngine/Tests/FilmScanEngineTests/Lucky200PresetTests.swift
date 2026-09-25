import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Lucky 200 reference-guided color")
struct Lucky200PresetTests {
  @Test("Recovery excludes blue water, neutral granite, and redder skin")
  func excludedColors() {
    for rgb in [[0.2, 0.4, 0.6], [0.55, 0.55, 0.55], [0.5, 0.25, 0.16]] {
      let linear = working(rgb)
      let result = WarmHueRecovery.apply(
        blue: linear.blue, green: linear.green, red: linear.red, amount: 1)
      #expect(result.blue == linear.blue)
      #expect(result.green == linear.green)
      #expect(result.red == linear.red)
    }
  }

  @Test("Copper foliage moves toward olive while conserving luminance")
  func foliageAndLuminance() {
    let copper = working([0.50, 0.34, 0.16])
    let result = WarmHueRecovery.apply(
      blue: copper.blue, green: copper.green, red: copper.red, amount: 0.85)
    #expect(result.green > result.red)
    let before = 0.2626983 * copper.red + 0.6780 * copper.green + 0.0593017 * copper.blue
    let after = 0.2626983 * result.red + 0.6780 * result.green + 0.0593017 * result.blue
    #expect(abs(before - after) < 1e-10)
    #expect(min(result.red, result.green, result.blue) >= 0)
  }

  @Test("Older adjustment and stock JSON leave recovery and neutral priors disabled")
  func migration() throws {
    let encoder = JSONEncoder()
    let defaults = PhotoAdjustmentParameters()
    let data = try encoder.encode(defaults)
    #expect(!String(decoding: data, as: UTF8.self).contains("warmHueRecovery"))
    #expect(try JSONDecoder().decode(PhotoAdjustmentParameters.self, from: data) == defaults)
    let profile = NegativeDensityProfileCatalog.genericC41
    let restored = try JSONDecoder().decode(
      NegativeDensityProfile.self, from: encoder.encode(profile))
    #expect(restored.logNeutralBalance == nil)
    #expect(restored == profile)
  }

  @Test("Roll neutral prior follows green exposure without changing legacy profiles")
  func neutralResponse() {
    let prior = NegativeLogNeutralBalance(
      referenceRGB: [-1.22, -1.30, -1.05], scaleRGB: [1.1, 1, 1], strengthRGB: [1, 0, 0])
    let bounds = (
      floors: BGRChannelValues(blue: -2, green: -2, red: -2),
      ceils: BGRChannelValues(blue: -0.5, green: -0.5, red: -0.5)
    )
    let result = prior.applying(to: bounds)
    let greenPosition = (-1.30 - result.floors.green) / (result.ceils.green - result.floors.green)
    let redPosition = (-1.22 - result.floors.red) / (result.ceils.red - result.floors.red)
    #expect(abs(greenPosition - redPosition) < 1e-12)
    #expect(result.floors.blue == bounds.floors.blue)
    #expect(result.ceils.blue == bounds.ceils.blue)
    let invalid = NegativeLogNeutralBalance(referenceRGB: [], scaleRGB: [], strengthRGB: [])
    #expect(invalid.applying(to: bounds).floors == bounds.floors)
  }

  private func working(_ rgb: [Double]) -> (red: Double, green: Double, blue: Double) {
    FilmNegativeProcessing.linearSRGBToRec2020(
      red: FilmNegativeProcessing.sRGBToLinear(rgb[0]),
      green: FilmNegativeProcessing.sRGBToLinear(rgb[1]),
      blue: FilmNegativeProcessing.sRGBToLinear(rgb[2]))
  }
}
