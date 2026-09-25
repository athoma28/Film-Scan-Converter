import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Public photo adjustment editing")
@MainActor
struct PhotoAdjustmentEditingTests {
  @Test("Tone promotion and a slider drag undo together", arguments: [2, 3])
  func promotionPreservesGestureHistory(version: Int) async throws {
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png", subdirectory: "Fixtures/decode_png8"))
    let model = AppModel()
    defer {
      model.selection = nil
      model.loadSelection()
    }
    model.importFiles([input])
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while model.previewImage == nil || model.isLoading || model.isRendering {
      try #require(ContinuousClock.now < deadline, "Initial preview did not settle")
      try await Task.sleep(for: .milliseconds(5))
    }
    var recipe = LookRecipe.cleanInvert
    recipe.photoAdjustments.schemaVersion = version
    model.applyLookRecipe(recipe)
    let before = model.parameters
    model.beginEditingGesture(named: "Highlights")
    model.setSemanticHighlights(0.2)
    model.setSemanticHighlights(0.4)
    model.endEditingGesture()
    let edited = model.parameters
    #expect(edited.photoAdjustments.schemaVersion == 4)
    #expect(edited.photoAdjustments.highlights == 0.4)
    #expect(model.undoActionName == "Highlights")
    model.undo()
    #expect(model.parameters == before)
    model.redo()
    #expect(model.parameters == edited)
  }

  @Test("Invalid numeric edits preserve parameters, tone version, and Original comparison")
  func invalidEditsDoNotMutateState() throws {
    let model = AppModel()
    model.setFilmBase(.colorC41)
    model.applyLookRecipe(.cleanInvert)
    model.showOriginal = true
    let before = model.parameters
    let setters: [(Double) -> Void] = [
      model.setExposureEV, model.setBrightness, model.setContrast,
      model.setSemanticHighlights, model.setSemanticShadows, model.setWhites, model.setBlacks,
      model.setShadowFloor, model.setMidtoneLevel, model.setHighlightCeiling,
      model.setSemanticTemperature, model.setSemanticTint, model.setSemanticSaturation,
      model.setVibrance, model.setWarmHueRecovery,
      model.setDensityCastRemovalStrength, model.setDensityUnmixStrength,
    ]
    for (index, set) in setters.enumerated() {
      for value in [Double.nan, .infinity, -.infinity] {
        set(value)
        #expect(model.parameters == before, "Setter \(index) accepted \(value)")
        #expect(model.showOriginal)
      }
    }
    _ = try JSONEncoder().encode(CorrectionSettings(capturing: model.parameters))
  }

  @Test("Public tone and color sliders clamp at their advertised endpoints")
  func sliderEndpoints() {
    let model = AppModel()
    let controls: [(WritableKeyPath<PhotoAdjustmentParameters, Double>, Double, (Double) -> Void)] =
      [
        (\.exposureEV, 4, model.setExposureEV),
        (\.brightness, 1, model.setBrightness),
        (\.contrast, 1, model.setContrast),
        (\.highlights, 1, model.setSemanticHighlights),
        (\.shadows, 1, model.setSemanticShadows),
        (\.whites, 1, model.setWhites),
        (\.blacks, 1, model.setBlacks),
        (\.shadowFloor, 1, model.setShadowFloor),
        (\.midtoneLevel, 1, model.setMidtoneLevel),
        (\.highlightCeiling, 1, model.setHighlightCeiling),
        (\.temperatureShiftMired, 100, model.setSemanticTemperature),
        (\.tint, 1, model.setSemanticTint),
        (\.saturation, 1, model.setSemanticSaturation),
        (\.vibrance, 1, model.setVibrance),
      ]
    for (keyPath, limit, set) in controls {
      for sign in [-1.0, 1.0] {
        set(sign * limit * 2)
        #expect(model.parameters.photoAdjustments[keyPath: keyPath] == sign * limit)
        set(sign * limit / 2)
        #expect(model.parameters.photoAdjustments[keyPath: keyPath] == sign * limit / 2)
      }
    }
    #expect(model.parameters.temperature == 50)
    #expect(model.parameters.tint == 50)
    #expect(model.parameters.saturation == 150)
  }
}
