import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Look recipes apply as slider snapshots")
@MainActor
struct LookRecipeAppTests {
  @Test("Legacy tone upgrade is undoable and endpoint controls survive the app clipboard parser")
  func toneUpgradeAndClipboard() async throws {
    let model = AppModel()
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    model.importFiles([input])
    try await waitUntil { model.previewImage != nil && !model.isRendering }
    var legacy = LookRecipe.cleanInvert
    legacy.photoAdjustments = .init(schemaVersion: 1, brightness: -0.2, highlights: 0.4)
    model.applyLookRecipe(legacy)
    let before = model.parameters
    model.upgradeToneControls()
    #expect(model.parameters.photoAdjustments.schemaVersion == 4)
    #expect(model.parameters.photoAdjustments.highlights == -0.4)
    model.undo()
    #expect(model.parameters == before)
    model.upgradeToneControls()
    model.setWhites(0.25)
    model.setBlacks(-0.2)
    let settings = CorrectionSettings(capturing: model.parameters)
    let decoded = try JSONDecoder().decode(
      CorrectionSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.recipe.photoAdjustments == model.parameters.photoAdjustments)
  }

  @Test("Apply writes snapshot values without a decoded image or invert swap")
  func applyDoesNotNeedADecodedImage() {
    let model = AppModel()
    #expect(model.decodedImage == nil)
    model.setFilmBase(.colorC41)
    let invert = model.parameters.filmNegativeParams
    model.applyLookRecipe(.foliage)
    #expect(model.decodedImage == nil)
    #expect(FilmBase.resolved(from: model.parameters) == .colorC41)
    #expect(model.parameters.filmNegativeParams.rendering == invert.rendering)
    #expect(model.parameters.filmNegativeParams.densityProfileID == invert.densityProfileID)
    #expect(LookRecipe.foliage.matches(model.parameters))
    #expect(model.parameters.photoAdjustments.warmHueRecovery == 0.55)
    #expect(model.appliedPresetName == "Foliage")
  }

  @Test("Switching looks keeps film base; switching film base does not apply a look")
  func switchingLooksKeepsFilmBase() {
    let model = AppModel()
    model.setFilmBase(.colorC41)
    model.applyLookRecipe(.warm)
    #expect(FilmBase.resolved(from: model.parameters) == .colorC41)
    model.applyLookRecipe(.nightLift)
    #expect(FilmBase.resolved(from: model.parameters) == .colorC41)
    #expect(LookRecipe.nightLift.matches(model.parameters))

    let adjustments = model.parameters.photoAdjustments
    model.setFilmBase(.colorCyanMask)
    #expect(FilmBase.resolved(from: model.parameters) == .colorCyanMask)
    #expect(model.parameters.photoAdjustments == adjustments)
    #expect(model.parameters.filmBaseChosenByUser)
    #expect(!LookRecipe.cleanInvert.matches(model.parameters))
  }

  @Test("Undo after apply restores the previous slider state")
  func undoAfterApplyRestoresSliders() async throws {
    let model = AppModel()
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    model.importFiles([input])
    try await waitUntil { model.previewImage != nil && !model.isRendering }
    model.setFilmBase(.colorC41)
    model.setExposureEV(-0.5)
    model.setVibrance(0.2)
    let before = model.parameters
    model.applyLookRecipe(.punchyPrint)
    #expect(LookRecipe.punchyPrint.matches(model.parameters))
    #expect(model.appliedPresetName == "Punchy Print")
    model.undo()
    #expect(model.parameters.photoAdjustments == before.photoAdjustments)
    #expect(model.parameters.curveEnabled == before.curveEnabled)
    #expect(!LookRecipe.punchyPrint.matches(model.parameters))
  }

  @Test("User save and load stores a slider snapshot without changing film base")
  func userSaveLoadSliderSnapshot() throws {
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-look-recipes-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let store = NamedCorrectionPresetStore(baseDirectory: workDir)
    let model = AppModel(presetStore: store)
    model.setFilmBase(.slide)
    model.applyLookRecipe(.softPeople)
    model.setExposureEV(0.37)
    model.saveCorrectionPreset(named: "Evening")
    let preset = try #require(model.namedCorrectionPresets.first)
    #expect(preset.name == "Evening")
    #expect(preset.settings.recipe.photoAdjustments.exposureEV == 0.37)

    let other = AppModel(presetStore: store)
    other.setFilmBase(.colorC41)
    other.applyCorrectionPreset(preset)
    #expect(FilmBase.resolved(from: other.parameters) == .colorC41)
    #expect(other.parameters.photoAdjustments.exposureEV == 0.37)
    #expect(
      other.parameters.photoAdjustments.contrast == LookRecipe.softPeople.photoAdjustments.contrast)
    #expect(other.appliedPresetName == "Evening")
  }

  @Test("Setting a factory look's controls keeps values while promoting the tone response")
  func publicControlsMatchApply() {
    let applied = AppModel()
    applied.setFilmBase(.colorC41)
    applied.applyLookRecipe(.punchyPrint)

    let reconstructed = AppModel()
    reconstructed.setFilmBase(.colorC41)
    let recipe = LookRecipe.punchyPrint
    reconstructed.setExposureEV(recipe.photoAdjustments.exposureEV)
    reconstructed.setBrightness(recipe.photoAdjustments.brightness)
    reconstructed.setContrast(recipe.photoAdjustments.contrast)
    reconstructed.setSemanticHighlights(recipe.photoAdjustments.highlights)
    reconstructed.setSemanticShadows(recipe.photoAdjustments.shadows)
    reconstructed.setSemanticTemperature(recipe.photoAdjustments.temperatureShiftMired)
    reconstructed.setSemanticTint(recipe.photoAdjustments.tint)
    reconstructed.setSemanticSaturation(recipe.photoAdjustments.saturation)
    reconstructed.setVibrance(recipe.photoAdjustments.vibrance)
    reconstructed.setWarmHueRecovery(recipe.photoAdjustments.warmHueRecovery ?? 0)
    reconstructed.setCurveEnabled(recipe.curveEnabled)
    reconstructed.setCurveControlPoints(recipe.curveControlPoints)
    reconstructed.setHighlightWheel(
      hue: recipe.highlightWheel.hue, strength: recipe.highlightWheel.strength)
    reconstructed.setMidtoneWheel(
      hue: recipe.midtoneWheel.hue, strength: recipe.midtoneWheel.strength)
    reconstructed.setShadowWheel(
      hue: recipe.shadowWheel.hue, strength: recipe.shadowWheel.strength)
    reconstructed.setDensityCastRemovalStrength(recipe.castCleanup)
    reconstructed.setDensityUnmixStrength(recipe.colorSeparation)

    #expect(applied.parameters.photoAdjustments.schemaVersion == 2)
    #expect(reconstructed.parameters.photoAdjustments.schemaVersion == 4)
    var promoted = recipe
    promoted.photoAdjustments.schemaVersion = 4
    #expect(promoted.matches(reconstructed.parameters))
    #expect(applied.parameters.curveControlPoints == reconstructed.parameters.curveControlPoints)
    #expect(FilmBase.resolved(from: reconstructed.parameters) == .colorC41)
  }

  private func waitUntil(
    timeout: Duration = .seconds(10),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else {
        Issue.record("Timed out waiting for look-recipe app state")
        throw WaitError.timedOut
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private enum WaitError: Error {
  case timedOut
}
