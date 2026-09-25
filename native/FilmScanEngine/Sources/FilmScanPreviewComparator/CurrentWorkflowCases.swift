import FilmScanEngine

struct ComparisonScenario {
  let name: String
  let family: String
  let parameters: ProcessingParameters
  var showOriginal = false
}

/// Exercise the same film-base and public-recipe composition used by Develop.
/// Recommendations are menu hints; saved looks can be applied across film bases.
func currentWorkflowScenarios() -> [ComparisonScenario] {
  var scenarios: [ComparisonScenario] = []
  let toneControls:
    [(String, WritableKeyPath<PhotoAdjustmentParameters, Double>, ClosedRange<Double>)] = [
      ("exposure", \.exposureEV, PhotoAdjustmentParameters.exposureRangeEV),
      ("brightness", \.brightness, PhotoAdjustmentParameters.brightnessRange),
      ("contrast", \.contrast, PhotoAdjustmentParameters.contrastRange),
      ("highlights", \.highlights, PhotoAdjustmentParameters.highlightsRange),
      ("shadows", \.shadows, PhotoAdjustmentParameters.shadowsRange),
      ("whites", \.whites, -1...1),
      ("blacks", \.blacks, -1...1),
      ("shadow-floor", \.shadowFloor, -1...1),
      ("midtone-level", \.midtoneLevel, -1...1),
      ("highlight-ceiling", \.highlightCeiling, -1...1),
    ]
  let colorControls:
    [(String, WritableKeyPath<PhotoAdjustmentParameters, Double>, ClosedRange<Double>)] = [
      (
        "temperature", \.temperatureShiftMired, PhotoAdjustmentParameters.temperatureShiftRangeMired
      ),
      ("tint", \.tint, PhotoAdjustmentParameters.tintRange),
      ("saturation", \.saturation, PhotoAdjustmentParameters.saturationRange),
      ("vibrance", \.vibrance, PhotoAdjustmentParameters.vibranceRange),
    ]

  for base in FilmBase.allCases {
    let inverted = base.applyingInvert(to: ProcessingParameters())
    scenarios.append(.init(name: "\(base.id)/invert", family: "film-base", parameters: inverted))

    var original = LookRecipe.nightLift.applying(to: inverted)
    original.rotation = 1
    original.flip = true
    scenarios.append(
      .init(
        name: "\(base.id)/original-comparison", family: "original", parameters: original,
        showOriginal: true))
    guard base.supportsLooks else {
      scenarios.append(
        .init(name: "original/ignore-look", family: "original", parameters: original))
      continue
    }

    for recipe in LookRecipe.factory {
      scenarios.append(
        .init(
          name: "\(base.id)/\(recipe.id)", family: "factory",
          parameters: recipe.applying(to: inverted)))
    }

    let controls = toneControls + (base.filmType.supportsColorCorrections ? colorControls : [])
    for (name, keyPath, range) in controls {
      for value in [range.lowerBound, range.upperBound] {
        var recipe = LookRecipe.cleanInvert
        recipe.photoAdjustments = PhotoAdjustmentParameters()
        recipe.photoAdjustments[keyPath: keyPath] = value
        scenarios.append(
          .init(
            name: "\(base.id)/\(name)=\(value)", family: "public-controls",
            parameters: recipe.applying(to: inverted)))
      }
    }
    // Version 3 is an explicit candidate. Keep this family bounded to its new
    // ranges, plus one color/tone interaction and the cropped density route.
    let focusedControls: [(String, WritableKeyPath<PhotoAdjustmentParameters, Double>)] = [
      ("highlights", \.highlights), ("shadows", \.shadows),
    ]
    for (name, keyPath) in focusedControls {
      for value in [-1.0, -0.25, 0.25, 1] {
        var recipe = LookRecipe.cleanInvert
        recipe.photoAdjustments = PhotoAdjustmentParameters(schemaVersion: 3)
        recipe.photoAdjustments[keyPath: keyPath] = value
        scenarios.append(
          .init(
            name: "\(base.id)/focused-v3/\(name)=\(value)", family: "focused-tone-v3",
            parameters: recipe.applying(to: inverted)))
      }
    }
    var focused = LookRecipe.cleanInvert
    focused.photoAdjustments = PhotoAdjustmentParameters(
      schemaVersion: 3, exposureEV: 0.5, brightness: 0.1, contrast: 0.1,
      highlights: -0.25, shadows: 0.25,
      temperatureShiftMired: 15, tint: 0.08, saturation: 0.2, vibrance: 0.15)
    let focusedParameters = focused.applying(to: inverted)
    scenarios.append(
      .init(
        name: "\(base.id)/focused-v3/combined", family: "focused-tone-v3",
        parameters: focusedParameters))
    if base.usesDensityPrint {
      var cropped = focusedParameters
      cropped.manualCrop = .init(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
      cropped.rotation = 1
      cropped.flip = true
      scenarios.append(
        .init(
          name: "\(base.id)/focused-v3/cropped", family: "focused-tone-v3",
          parameters: cropped))
    }
    var separated = LookRecipe.cleanInvert
    separated.photoAdjustments = PhotoAdjustmentParameters(
      schemaVersion: 4, exposureEV: 0.35, contrast: 0.12,
      highlights: -0.25, shadows: 0.2, whites: 0.25, blacks: -0.2,
      shadowFloor: 0.18, midtoneLevel: -0.12, highlightCeiling: -0.15)
    if base.filmType.supportsColorCorrections {
      separated.shadowWheel = ColorWheel(hue: 280, strength: 0.3)
      separated.highlightWheel = ColorWheel(hue: 38, strength: 0.25)
    }
    let separatedParameters = separated.applying(to: inverted)
    scenarios.append(
      .init(
        name: "\(base.id)/separated-v4/combined", family: "separated-tone-v4",
        parameters: separatedParameters))
    if base.usesDensityPrint {
      var cropped = separatedParameters
      cropped.manualCrop = .init(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
      cropped.rotation = 1
      scenarios.append(
        .init(
          name: "\(base.id)/separated-v4/cropped", family: "separated-tone-v4",
          parameters: cropped))
    }
    if base.filmType.supportsColorCorrections {
      for value in [0.0, 0.55, 1.0] {
        var recipe = LookRecipe.cleanInvert
        recipe.photoAdjustments.warmHueRecovery = value
        scenarios.append(
          .init(
            name: "\(base.id)/foliage-recovery=\(value)", family: "public-controls",
            parameters: recipe.applying(to: inverted)))
      }
      let mixingControls: [(String, WritableKeyPath<FilmDyeMixingParameters, Double>)] = [
        ("redFromGreen", \.redFromGreen), ("redFromBlue", \.redFromBlue),
        ("greenFromRed", \.greenFromRed), ("greenFromBlue", \.greenFromBlue),
        ("blueFromRed", \.blueFromRed), ("blueFromGreen", \.blueFromGreen),
      ]
      for (name, keyPath) in mixingControls {
        for value in [-0.3, 0.3] {
          var parameters = LookRecipe.cleanInvert.applying(to: inverted)
          parameters.filmDyeMixing[keyPath: keyPath] = value
          scenarios.append(
            .init(
              name: "\(base.id)/\(name)=\(value)", family: "advanced-dye",
              parameters: parameters))
        }
      }
    }
    if base.usesDensityPrint {
      for cleanup in [0.0, 1.0] {
        for separation in [0.0, 1.0] {
          var recipe = LookRecipe.cleanInvert
          recipe.castCleanup = cleanup
          recipe.colorSeparation = separation
          scenarios.append(
            .init(
              name: "\(base.id)/cleanup=\(cleanup)/separation=\(separation)",
              family: "density-controls", parameters: recipe.applying(to: inverted)))
        }
      }
    }

    var combined = LookRecipe.punchyPrint
    combined.photoAdjustments = PhotoAdjustmentParameters(
      exposureEV: 0.6, brightness: 0.12, contrast: 0.25, highlights: -0.35, shadows: 0.3,
      temperatureShiftMired: 25, tint: -0.12, saturation: 0.22, vibrance: 0.35,
      warmHueRecovery: 0.7)
    combined.redCurveEnabled = true
    combined.redCurveControlPoints = [
      .init(input: 0, output: 0.02), .init(input: 0.45, output: 0.55), .init(input: 1, output: 1),
    ]
    combined.greenCurveEnabled = true
    combined.greenCurveControlPoints = [
      .init(input: 0, output: 0), .init(input: 0.55, output: 0.48), .init(input: 1, output: 0.97),
    ]
    combined.blueCurveEnabled = true
    combined.blueCurveControlPoints = [
      .init(input: 0, output: 0.03), .init(input: 0.5, output: 0.43), .init(input: 1, output: 1),
    ]
    combined.highlightWheel = ColorWheel(hue: 35, strength: 0.25)
    combined.midtoneWheel = ColorWheel(hue: 190, strength: 0.15)
    combined.shadowWheel = ColorWheel(hue: 285, strength: 0.3)
    combined.castCleanup = 0.75
    combined.colorSeparation = 0.8
    var parameters = combined.applying(to: inverted)
    parameters.filmDyeMixing = FilmDyeMixingParameters(
      redFromGreen: -0.15, redFromBlue: 0.1, greenFromRed: 0.12,
      greenFromBlue: -0.08, blueFromRed: -0.1, blueFromGreen: 0.15)
    parameters.rotation = 1
    parameters.flip = true
    scenarios.append(
      .init(name: "\(base.id)/combined-rotated", family: "combined", parameters: parameters))
  }
  // Production routes beyond the default density invert, and the crop path
  // that formerly forced every slider edit through a full-resolution CPU render.
  let inversions: [(String, FilmType, FilmNegativeParams)] = [
    ("power-law-color", .colourNegative, .legacyColourNegative),
    ("power-law-mono", .blackAndWhiteNegative, .legacyBlackAndWhite),
    ("calibrated-color", .colourNegative, .colourNegative),
  ]
  for (name, film, inversion) in inversions {
    for recipe in [LookRecipe.cleanInvert, .nightLift, .punchyPrint] {
      var p = ProcessingParameters(
        filmType: film, filmNegativeParams: inversion,
        photoAdjustments: recipe.photoAdjustments)
      p = recipe.applying(to: p)
      scenarios.append(
        .init(name: "\(name)/\(recipe.id)", family: "alternate-invert", parameters: p))
    }
  }
  for base in [FilmBase.colorC41, .colorCyanMask] {
    for rotation in 0...3 {
      var p = LookRecipe.nightLift.applying(to: base.applyingInvert(to: .init()))
      p.manualCrop = .init(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
      p.rotation = rotation
      p.flip = true
      scenarios.append(
        .init(name: "\(base.id)/crop-\(rotation)", family: "cropped-tone", parameters: p))
    }
  }
  return scenarios
}

/// Non-square, unaligned rows and independent RGB values catch channel, hue,
/// threshold, orientation and row-stride errors that neutral fixtures cannot.
func makeColorVolume(width: Int, height: Int) -> UInt16Image {
  let levels: [UInt16] = [0, 1, 1024, 1025, 4096, 8192, 16384, 32768, 49152, 65534, 65535]
  var pixels: [UInt16] = []
  pixels.reserveCapacity(width * height * 3)
  for index in 0..<(width * height) {
    pixels.append(levels[index % levels.count])
    pixels.append(levels[(index / levels.count) % levels.count])
    pixels.append(levels[(index / (levels.count * levels.count)) % levels.count])
  }
  return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
}
