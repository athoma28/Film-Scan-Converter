import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Grading point controls", .serialized)
@MainActor
struct GradingPointControlTests {
  @Test("Each grading point independently marks tone intent without color intent")
  func pointControlsAreToneIntent() {
    let controls: [WritableKeyPath<PhotoAdjustmentParameters, Double>] = [
      \.shadowFloor, \.midtoneLevel, \.highlightCeiling,
    ]
    for control in controls {
      var points = PhotoAdjustmentParameters()
      points[keyPath: control] = 0.3
      #expect(points.hasToneAdjustment)
      #expect(!points.hasColorAdjustment)
      #expect(!points.isNeutral)
    }
  }

  @Test("Correction parser preserves the three controls through copy and apply")
  func correctionParserRoundTrip() throws {
    var source = ProcessingParameters(photoAdjustments: .init())
    source.photoAdjustments.shadowFloor = 0.2
    source.photoAdjustments.midtoneLevel = -0.15
    source.photoAdjustments.highlightCeiling = -0.25
    let saved = CorrectionSettings(capturing: source)
    let parsed = try JSONDecoder().decode(
      CorrectionSettings.self, from: JSONEncoder().encode(saved))
    let applied = parsed.applying(to: ProcessingParameters(filmType: .slide))
    #expect(applied.photoAdjustments.shadowFloor == 0.2)
    #expect(applied.photoAdjustments.midtoneLevel == -0.15)
    #expect(applied.photoAdjustments.highlightCeiling == -0.25)
  }

  @Test("A point edit promotes an older photographic edit and clamps the result")
  func settersPromoteAndClamp() {
    let model = AppModel()
    model.applyLookRecipe(.cleanInvert)
    #expect(model.parameters.photoAdjustments.schemaVersion == 2)
    model.setExposureEV(0.4)
    #expect(model.parameters.photoAdjustments.schemaVersion == 2)

    model.setShadowFloor(2)
    #expect(model.parameters.photoAdjustments.schemaVersion == 4)
    #expect(model.parameters.photoAdjustments.shadowFloor == 1)
    model.setMidtoneLevel(-2)
    model.setHighlightCeiling(-0.35)
    #expect(model.parameters.photoAdjustments.midtoneLevel == -1)
    #expect(model.parameters.photoAdjustments.highlightCeiling == -0.35)
  }

  @Test("Focused light controls promote version 3; version 1 point controls wait for upgrade")
  func focusedPromotionAndLegacyProtection() {
    let model = AppModel()
    var recipe = LookRecipe.cleanInvert
    recipe.photoAdjustments.schemaVersion = 3
    model.applyLookRecipe(recipe)
    model.setWhites(0.2)
    #expect(model.parameters.photoAdjustments.schemaVersion == 4)
    model.applyLookRecipe(recipe)
    model.setBlacks(-0.2)
    #expect(model.parameters.photoAdjustments.schemaVersion == 4)
    model.applyLookRecipe(recipe)
    model.setSemanticHighlights(-0.2)
    #expect(model.parameters.photoAdjustments.schemaVersion == 4)
    model.applyLookRecipe(recipe)
    model.setSemanticShadows(0.2)
    #expect(model.parameters.photoAdjustments.schemaVersion == 4)

    recipe.photoAdjustments.schemaVersion = 1
    model.applyLookRecipe(recipe)
    model.setShadowFloor(0.3)
    #expect(model.parameters.photoAdjustments.schemaVersion == 1)
    #expect(model.parameters.photoAdjustments.shadowFloor == 0)
    model.upgradeToneControls()
    #expect(model.parameters.photoAdjustments.schemaVersion == 4)
    model.setShadowFloor(0.3)
    #expect(model.parameters.photoAdjustments.shadowFloor == 0.3)
  }
}
