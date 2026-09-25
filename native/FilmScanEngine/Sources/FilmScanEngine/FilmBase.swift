import Foundation

/// What the scan is. Invert defaults come from this choice; looks never change it.
public enum FilmBase: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
  case colorC41
  case colorCyanMask
  case blackAndWhite
  case slide
  case original

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .colorC41: "Color C-41"
    case .colorCyanMask: "Color cyan-mask"
    case .blackAndWhite: "B&W negative"
    case .slide: "Slide"
    case .original: "Original"
    }
  }

  public var summary: String {
    switch self {
    case .colorC41:
      "Orange-mask color negative. Density-print invert with a generic C-41 unmix."
    case .colorCyanMask:
      "Cyan or purple-mask color negative. Density-print invert with the cyan-mask unmix."
    case .blackAndWhite:
      "Monochrome negative invert."
    case .slide:
      "Positive transparency. No invert."
    case .original:
      "Already-positive image. Framing and export only."
    }
  }

  public var filmType: FilmType {
    switch self {
    case .colorC41, .colorCyanMask: .colourNegative
    case .blackAndWhite: .blackAndWhiteNegative
    case .slide: .slide
    case .original: .cropOnly
    }
  }

  public var invertParameters: FilmNegativeParams {
    switch self {
    case .colorC41:
      .densityPrintGenericC41
    case .colorCyanMask:
      .densityPrintHarmanPhoenixII
    case .blackAndWhite:
      .blackAndWhite
    case .slide, .original:
      FilmNegativeParams(enabled: false)
    }
  }

  public var usesDensityPrint: Bool {
    switch self {
    case .colorC41, .colorCyanMask: true
    case .blackAndWhite, .slide, .original: false
    }
  }

  public var supportsLooks: Bool {
    self != .original
  }

  public static func resolved(from parameters: ProcessingParameters) -> FilmBase {
    switch parameters.filmType {
    case .cropOnly:
      .original
    case .slide:
      .slide
    case .blackAndWhiteNegative:
      .blackAndWhite
    case .colourNegative:
      parameters.filmNegativeParams.densityProfileID
        == NegativeDensityProfileCatalog.harmanPhoenixII.id.rawValue
        ? .colorCyanMask : .colorC41
    }
  }

  public func applyingInvert(to parameters: ProcessingParameters) -> ProcessingParameters {
    var result = parameters
    let medians = parameters.filmNegativeParams.measuredMedians
    result.filmType = filmType
    result.filmNegativeParams = invertParameters
    result.filmNegativeParams.measuredMedians = medians
    return result
  }

  /// Shared by first import, deferred look transfer, and diagnostic Automatic.
  /// A queued look is applied after classification so all of its public controls
  /// survive, including density controls on a previously unknown film base.
  public static func automaticallyClassifiedParameters(
    base: ProcessingParameters,
    image: UInt16Image,
    weakPrior: FilmType? = nil
  ) -> ProcessingParameters {
    let classification = FilmNegativeProcessing.classifyFilmScan(image: image, weakPrior: weakPrior)
    let queuedLook =
      base.pendingFilmBaseInitialization == .preservingLook
      ? LookRecipe.capturing(base, id: "queued", title: "Queued look") : nil
    var next = classification.filmBase.applyingInvert(to: base)
    next.filmBaseChosenByUser = false
    next.pendingFilmBaseInitialization = nil
    if classification.filmBase.filmType == .colourNegative
      || classification.filmBase.filmType == .blackAndWhiteNegative
    {
      next.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    }
    if let look = queuedLook ?? LookRecipe.recommended(for: classification.filmBase).first {
      next = look.applying(to: next)
    }
    return next
  }
}
