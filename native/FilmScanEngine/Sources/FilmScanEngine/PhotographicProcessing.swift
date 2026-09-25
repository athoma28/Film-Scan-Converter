import Foundation

extension FilmProcessing {
  /// Version 2 analyzes the immutable sensor frame, so cropping cannot remeter
  /// the photograph. Preview, CPU export and interaction proxies share this input.
  public static func photographicDensityAnalysis(
    image: UInt16Image, parameters: ProcessingParameters
  )
    -> DensityPrintAnalysis
  {
    DensityPrintProcessing.analyze(
      image: image.resizedToFit(maxDimension: 256),
      profile: DensityPrintProcessing.resolvedProfile(from: parameters.filmNegativeParams),
      paper: DensityPrintProcessing.resolvedPaper(from: parameters.filmNegativeParams))
  }

  static func correctedPhotographicPreview(
    image: UInt16Image, parameters: ProcessingParameters, flatField: UInt16Image? = nil,
    preparedGeometry: UInt16Image? = nil, densityAnalysis: DensityPrintAnalysis? = nil
  ) -> UInt16Image {
    var working = preparedGeometry ?? prepareGeometry(image: image, parameters: parameters)
    guard parameters.filmType != .cropOnly else { return working }
    if working.channels == 1 {
      working = UInt16Image(
        width: working.width, height: working.height, channels: 3,
        pixels: working.pixels.flatMap { [$0, $0, $0] })
    }
    let isBW = parameters.filmType == .blackAndWhiteNegative
    let negative = isBW || parameters.filmType == .colourNegative
    var inversion = parameters.filmNegativeParams
    if inversion.enabled, inversion.measuredMedians == nil {
      inversion.measuredMedians = FilmNegativeProcessing.computeMedians(
        image: image.resizedToFit(maxDimension: 256))
    }
    let density: DensityPrintAnalysis? =
      negative && !isBW && inversion.enabled
        && inversion.rendering == .densityPrint
      ? densityAnalysis ?? photographicDensityAnalysis(image: image, parameters: parameters) : nil
    let curves = PhotographicCurves(parameters)

    if parameters.densityPipelineEnabled, let base = parameters.densityBaseDensity,
      negative, inversion.rendering == .powerLaw, working.channels == 3
    {
      let field =
        flatField.map {
          prepareGeometry(
            image: $0.resized(width: image.width, height: image.height), parameters: parameters)
        }
        ?? UInt16Image(
          width: working.width, height: working.height, channels: 3,
          pixels: [UInt16](repeating: 65_535, count: working.pixels.count))
      var linear = FilmNegativeProcessing.densityToRenderReadyLinear(
        image: working,
        flatField: field, baseDensity: base, densityCorrection: parameters.densityCorrection,
        c41Profile: parameters.densityC41Profile)
      let display = parameters.densityDisplayParams
      let whiteBalance = [
        display.whiteBalance.blue, display.whiteBalance.green, display.whiteBalance.red,
      ]
      for i in stride(from: 0, to: linear.pixels.count, by: 3) {
        func channel(_ c: Int) -> Double {
          let value =
            linear.pixels[i + c]
            * min(
              exp2(display.exposureEV) * whiteBalance[c],
              display.maximumSceneGain)
          return PhotographicTone.decode(display.toneMap == .reinhard ? value / (1 + value) : value)
        }
        let rgb = FilmNegativeProcessing.linearSRGBToRec2020(
          red: channel(2), green: channel(1), blue: channel(0))
        linear.pixels[i] = rgb.blue
        linear.pixels[i + 1] = rgb.green
        linear.pixels[i + 2] = rgb.red
      }
      return finishPhotographic(
        linear: linear, sensor: working, parameters: parameters, curves: curves)
    }

    return mapCorrectionBands(working) { band in
      var linear: RenderReadyLinearImage
      if negative, inversion.enabled,
        (isBW && inversion.rendering != .calibratedMonochrome)
          || (!isBW && inversion.rendering != .calibratedColor
            && inversion.rendering != .densityPrint)
      {
        linear = FilmNegativeProcessing.powerLawRenderReadyLinear(image: band, params: inversion)
        // The power-law inverse meters to 1/24; the common photographic seam
        // uses 18% gray. No bounded display curve is baked in before exposure.
        for i in linear.pixels.indices {
          linear.pixels[i] *= 0.18 / FilmNegativeProcessing.calibrationTargetFraction
        }
      } else {
        var values = [Double](repeating: 0, count: band.width * band.height * 3)
        for pixel in 0..<(band.width * band.height) {
          let source = pixel * band.channels
          let b = band.pixels[source]
          let g = band.pixels[source + (band.channels == 3 ? 1 : 0)]
          let r = band.pixels[source + (band.channels == 3 ? 2 : 0)]
          let rgb: (red: Double, green: Double, blue: Double)
          if let density {
            let value = DensityPrintProcessing.renderLinearPixel(
              blue: b, green: g, red: r, analysis: density)
            rgb = FilmNegativeProcessing.linearSRGBToRec2020(
              red: value.red, green: value.green, blue: value.blue)
          } else {
            var channels = [Double(b) / 65_535, Double(g) / 65_535, Double(r) / 65_535]
            if negative && inversion.enabled {
              if isBW {
                let gray = channels[0] * 0.114 + channels[1] * 0.587 + channels[2] * 0.299
                let value = FilmNegativeProcessing.photographicCalibratedValue(
                  gray, channel: 1, params: inversion)
                channels = [value, value, value]
              } else {
                channels = (0..<3).map {
                  FilmNegativeProcessing.photographicCalibratedValue(
                    channels[$0], channel: $0, params: inversion)
                }
              }
            } else if negative {
              if isBW {
                let gray = 1 - (channels[0] * 0.114 + channels[1] * 0.587 + channels[2] * 0.299)
                channels = [gray, gray, gray]
              } else {
                channels = channels.map { 1 - $0 }
              }
            }
            rgb = FilmNegativeProcessing.linearSRGBToRec2020(
              red: PhotographicTone.decode(channels[2]),
              green: PhotographicTone.decode(channels[1]),
              blue: PhotographicTone.decode(channels[0]))
          }
          values[pixel * 3] = rgb.blue
          values[pixel * 3 + 1] = rgb.green
          values[pixel * 3 + 2] = rgb.red
        }
        linear = RenderReadyLinearImage(width: band.width, height: band.height, pixels: values)
      }
      return finishPhotographic(
        linear: linear, sensor: band, parameters: parameters, curves: curves)
    }
  }

  private static func finishPhotographic(
    linear source: RenderReadyLinearImage,
    sensor: UInt16Image, parameters: ProcessingParameters, curves: PhotographicCurves
  ) -> UInt16Image {
    var linear = source
    let isBW = parameters.filmType == .blackAndWhiteNegative
    if parameters.filmType == .colourNegative, !parameters.filmDyeMixing.isNeutral {
      linear.applyFilmDyeMixing(parameters.filmDyeMixing)
    }
    linear.applyLinearToneAdjustments(parameters.photoAdjustments)
    if !isBW, parameters.photoAdjustments.hasColorAdjustment {
      linear.applyProtectedColorAdjustments(parameters.photoAdjustments)
    }
    let pixels = linear.pixels
    var output = [UInt16](repeating: 0, count: pixels.count)
    let wheels = [parameters.highlightWheel, parameters.midtoneWheel, parameters.shadowWheel]
    let pushes = wheels.map { FilmProcessing.wheelRGB($0) }
    processCorrectionPixels(&output, pixelCount: linear.pixelCount) { pixel, output in
      let i = pixel * 3
      let srgb = FilmNegativeProcessing.linearRec2020ToSRGB(
        red: pixels[i + 2], green: pixels[i + 1], blue: pixels[i])
      var r = PhotographicTone.encode(srgb.red)
      var g = PhotographicTone.encode(srgb.green)
      var b = PhotographicTone.encode(srgb.blue)
      if isBW {
        let gray = 0.299 * r + 0.587 * g + 0.114 * b
        r = gray
        g = gray
        b = gray
      }
      r = curves.value(r, channel: 2)
      g = curves.value(g, channel: 1)
      b = curves.value(b, channel: 0)
      if !isBW, wheels.contains(where: { !$0.isNeutral }) {
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        let masks = [highlightMask(y), midtoneMask(y), shadowMask(y)]
        for j in 0..<3 {
          r *= 1 + pushes[j].r * masks[j]
          g *= 1 + pushes[j].g * masks[j]
          b *= 1 + pushes[j].b * masks[j]
        }
        let newY = 0.299 * r + 0.587 * g + 0.114 * b
        if newY > 0 {
          let scale = y / newY
          r *= scale
          g *= scale
          b *= scale
        }
      }
      let mapped = PhotographicTone.displayGamut(red: r, green: g, blue: b)
      let sensorIndex = pixel * sensor.channels
      let sensorBlack =
        parameters.filmType != .slide
        && (0..<sensor.channels).allSatisfy {
          sensor.pixels[sensorIndex + $0] <= FilmNegativeProcessing.sensorBlackThreshold
        }
      func code(_ x: Double) -> UInt16 {
        sensorBlack ? 65_535 : UInt16(min(max(x * 65_535, 0), 65_535).rounded())
      }
      output[i] = code(mapped.blue)
      output[i + 1] = code(mapped.green)
      output[i + 2] = code(mapped.red)
    }
    return UInt16Image(width: linear.width, height: linear.height, channels: 3, pixels: output)
  }
}

/// Float interpolation and endpoint extrapolation defer clipping through curves.
/// The existing master/channel replacement policy is preserved for saved recipes.
struct PhotographicCurves: Sendable {
  let channels: [[UInt16]?]
  init(_ p: ProcessingParameters) {
    let master =
      p.curveEnabled ? FilmProcessing.buildCurveLUT(controlPoints: p.curveControlPoints) : nil
    func curve(_ enabled: Bool, _ points: [CurvePoint]) -> [UInt16]? {
      enabled && p.filmType.supportsColorCorrections
        ? FilmProcessing.buildCurveLUT(controlPoints: points) ?? master : master
    }
    channels = [
      curve(p.blueCurveEnabled, p.blueCurveControlPoints),
      curve(p.greenCurveEnabled, p.greenCurveControlPoints),
      curve(p.redCurveEnabled, p.redCurveControlPoints),
    ]
  }
  func value(_ x: Double, channel: Int) -> Double {
    guard let table = channels[channel] else { return x }
    let position = x * 65_535
    // A one-code endpoint derivative can round to zero in a UInt16 LUT.
    // Estimate the extension across 256 codes so lifted/crushed endpoints can
    // still be recovered by a later curve instead of forming a flat plateau.
    let lower = x < 0 ? 0 : (x > 1 ? 65_279 : min(max(Int(position), 0), 65_534))
    let upper = x < 0 ? 256 : (x > 1 ? 65_535 : lower + 1)
    let fraction = (position - Double(lower)) / Double(upper - lower)
    return (Double(table[lower]) + fraction * (Double(table[upper]) - Double(table[lower])))
      / 65_535
  }
}
