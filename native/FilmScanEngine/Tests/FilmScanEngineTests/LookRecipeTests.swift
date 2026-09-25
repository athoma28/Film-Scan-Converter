import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Look recipes are public slider snapshots")
struct LookRecipeTests {
  @Test("Assigning a recipe's public controls without apply reproduces that recipe")
  func publicControlsRecreateApply() {
    for recipe in LookRecipe.factory {
      let base = recipe.recommendedFilmBases.first ?? .colorC41
      var parameters = base.applyingInvert(to: ProcessingParameters())
      parameters.photoAdjustments.exposureEV = -0.4
      parameters.rotation = 1
      parameters.filmNegativeParams.measuredMedians = BGRChannelValues(
        blue: 0.2, green: 0.3, red: 0.4)

      let applied = recipe.applying(to: parameters)
      var reconstructed = parameters
      reconstructed.photoAdjustments = recipe.photoAdjustments
      reconstructed.curveEnabled = recipe.curveEnabled
      reconstructed.curveControlPoints = recipe.curveControlPoints
      reconstructed.redCurveEnabled = recipe.redCurveEnabled
      reconstructed.redCurveControlPoints = recipe.redCurveControlPoints
      reconstructed.greenCurveEnabled = recipe.greenCurveEnabled
      reconstructed.greenCurveControlPoints = recipe.greenCurveControlPoints
      reconstructed.blueCurveEnabled = recipe.blueCurveEnabled
      reconstructed.blueCurveControlPoints = recipe.blueCurveControlPoints
      reconstructed.highlightWheel = recipe.highlightWheel
      reconstructed.midtoneWheel = recipe.midtoneWheel
      reconstructed.shadowWheel = recipe.shadowWheel
      reconstructed.gamma = 0
      reconstructed.shadows = 0
      reconstructed.highlights = 0
      if base.usesDensityPrint {
        reconstructed.filmNegativeParams.densityCastRemovalStrength = recipe.castCleanup
        reconstructed.filmNegativeParams.densityUnmixStrength = recipe.colorSeparation
        reconstructed.filmNegativeParams.densityNeutralProtection = true
      }
      reconstructed.syncLegacyColorFieldsFromPhotoAdjustments()

      #expect(applied == reconstructed)
      #expect(recipe.matches(applied))
      #expect(recipe.matches(reconstructed))
      #expect(applied.rotation == 1)
      #expect(
        applied.filmNegativeParams.measuredMedians == parameters.filmNegativeParams.measuredMedians)
      #expect(FilmBase.resolved(from: applied) == base)
    }
  }

  @Test("Applying a look does not change film-base invert IDs")
  func applyKeepsInvertIDs() {
    for base in FilmBase.allCases {
      let before = base.applyingInvert(to: ProcessingParameters())
      for recipe in LookRecipe.factory {
        let after = recipe.applying(to: before)
        #expect(after.filmType == before.filmType)
        #expect(after.filmNegativeParams.enabled == before.filmNegativeParams.enabled)
        #expect(after.filmNegativeParams.rendering == before.filmNegativeParams.rendering)
        #expect(
          after.filmNegativeParams.densityProfileID == before.filmNegativeParams.densityProfileID)
        #expect(
          after.filmNegativeParams.calibratedColorProfile
            == before.filmNegativeParams.calibratedColorProfile)
        #expect(
          after.filmNegativeParams.calibratedMonochromeProfile
            == before.filmNegativeParams.calibratedMonochromeProfile)
        #expect(FilmBase.resolved(from: after) == base)
      }
    }
  }

  @Test("Foliage recovery is a public slider on every color-negative look")
  func foliageRecoveryIsAPublicSlider() {
    let base = FilmBase.colorC41.applyingInvert(to: ProcessingParameters())
    for recipe in LookRecipe.recommended(for: .colorC41) {
      var parameters = recipe.applying(to: base)
      parameters.photoAdjustments.warmHueRecovery = 0.4
      #expect(parameters.photoAdjustments.warmHueRecovery == 0.4)
      #expect(!recipe.matches(parameters) || recipe.photoAdjustments.warmHueRecovery == 0.4)
    }
    let foliage = LookRecipe.foliage.applying(to: base)
    #expect(foliage.photoAdjustments.warmHueRecovery == 0.55)
    #expect(LookRecipe.foliage.matches(foliage))
  }

  @Test("Switching looks keeps film base; switching film base does not apply a look")
  func filmBaseAndLooksStayIndependent() {
    var parameters = FilmBase.colorC41.applyingInvert(to: ProcessingParameters())
    parameters = LookRecipe.warm.applying(to: parameters)
    let invertID = parameters.filmNegativeParams.densityProfileID
    parameters = LookRecipe.cool.applying(to: parameters)
    #expect(FilmBase.resolved(from: parameters) == .colorC41)
    #expect(parameters.filmNegativeParams.densityProfileID == invertID)
    #expect(LookRecipe.cool.matches(parameters))
    #expect(!LookRecipe.warm.matches(parameters))

    let warmth = parameters.photoAdjustments
    parameters = FilmBase.colorCyanMask.applyingInvert(to: parameters)
    #expect(FilmBase.resolved(from: parameters) == .colorCyanMask)
    #expect(parameters.photoAdjustments == warmth)
    #expect(!LookRecipe.cleanInvert.matches(parameters))
  }

  @Test("Density-print invert always uses the identity paper response")
  func densityPrintUsesNeutralPaper() {
    for params in [
      FilmNegativeParams.densityPrintGenericC41,
      FilmNegativeParams.densityPrintHarmanPhoenixII,
      FilmNegativeParams.densityPrintFuji400,
    ] {
      #expect(
        DensityPrintProcessing.resolvedPaper(from: params) == DensityPaperProfileCatalog.neutral)
    }
  }
}
