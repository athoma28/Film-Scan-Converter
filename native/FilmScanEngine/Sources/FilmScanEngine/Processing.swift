import Foundation

private func clamp(_ value: Float, _ lo: Float, _ hi: Float) -> Float {
  min(max(value, lo), hi)
}
public enum FilmProcessing {
  public static func correctedPreview(
    image: UInt16Image,
    parameters: ProcessingParameters,
    flatField: UInt16Image? = nil
  ) -> UInt16Image {
    if parameters.densityPipelineEnabled,
      parameters.densityBaseDensity != nil,
      (parameters.filmType == .colourNegative
        || parameters.filmType == .blackAndWhiteNegative)
    {
      return correctedPreviewDensity(
        image: image,
        parameters: parameters,
        flatField: flatField
      )
    }
    return correctedPreviewPowerLaw(image: image, parameters: parameters)
  }

  private static func correctedPreviewPowerLaw(
    image: UInt16Image,
    parameters: ProcessingParameters
  ) -> UInt16Image {
    let cropped = parameters.cropRect.flatMap {
      PerspectiveTransform.crop(image, normalizedRect: $0, borderPercent: parameters.borderCrop)
    } ?? image
    var working = cropped.rotated(
      quarterTurns: parameters.rotation,
      flipHorizontally: parameters.flip
    )
    guard parameters.filmType != .cropOnly else {
      return working
    }

    var usedLinearColorSeam = false
    var usedLinearToneSeam = false
    if parameters.filmType == .blackAndWhiteNegative {
      if parameters.filmNegativeParams.enabled {
        if parameters.photoAdjustments.hasToneAdjustment {
          let renderReady = FilmNegativeProcessing.powerLawRenderReadyLinear(
            image: working, params: parameters.filmNegativeParams
          ).applyingLinearToneAdjustments(parameters.photoAdjustments)
          working = FilmNegativeProcessing.renderPowerLawDisplay(renderReady)
          usedLinearToneSeam = true
        } else {
          working = FilmNegativeProcessing.applyPowerLawInversion(
            image: working, params: parameters.filmNegativeParams
          )
        }
        working = grayscale(working, inverted: false)
      } else {
        working = grayscale(working, inverted: true)
      }
    } else if parameters.filmType == .colourNegative {
      if parameters.filmNegativeParams.enabled {
        let needsLinearSeam = parameters.photoAdjustments.hasColorAdjustment
          || parameters.photoAdjustments.hasToneAdjustment
        if needsLinearSeam {
          var renderReady = FilmNegativeProcessing.powerLawRenderReadyLinear(
            image: working,
            params: parameters.filmNegativeParams
          )
          if parameters.photoAdjustments.hasToneAdjustment {
            renderReady = renderReady.applyingLinearToneAdjustments(
              parameters.photoAdjustments)
            usedLinearToneSeam = true
          }
          if parameters.photoAdjustments.hasColorAdjustment {
            renderReady = renderReady.applyingProtectedColorAdjustments(
              parameters.photoAdjustments)
            usedLinearColorSeam = true
          }
          working = FilmNegativeProcessing.renderPowerLawDisplay(renderReady)
        } else {
          working = FilmNegativeProcessing.applyPowerLawInversion(
            image: working, params: parameters.filmNegativeParams
          )
        }
      } else {
        working = inverted(working)
      }
    }

    if parameters.photoAdjustments.hasToneAdjustment && !usedLinearToneSeam {
      working = applySemanticToneToDisplayImage(
        working, parameters: parameters.photoAdjustments)
      usedLinearToneSeam = true
    }

    let adjustWhiteBalance =
      working.channels == 3 && !usedLinearColorSeam
        && (parameters.temperature != 0 || parameters.tint != 0)
    let adjustExposure = !usedLinearToneSeam
      && (parameters.gamma != 0 || parameters.shadows != 0 || parameters.highlights != 0)
    let adjustCurves =
      working.channels == 3 && (parameters.curveEnabled || parameters.redCurveEnabled
        || parameters.greenCurveEnabled || parameters.blueCurveEnabled)
    let adjustColorWheels =
      working.channels == 3 && (!parameters.highlightWheel.isNeutral
        || !parameters.midtoneWheel.isNeutral || !parameters.shadowWheel.isNeutral)
    let adjustSaturation = working.channels == 3 && !usedLinearColorSeam
      && parameters.saturation != 100
    guard adjustWhiteBalance || adjustExposure || adjustCurves || adjustColorWheels
      || adjustSaturation
    else {
      return working
    }

    var values = working.pixels.map(Double.init)
    let pixelCount = working.width * working.height
    let channels = working.channels

    if adjustWhiteBalance {
      values = wbAdjustCoeff(
        image: values,
        width: working.width,
        height: working.height,
        channels: channels,
        temp: parameters.temperature,
        tint: parameters.tint
      )
    }
    if adjustExposure {
      values = exposure(
        image: values,
        gamma: parameters.gamma,
        shadows: parameters.shadows,
        highlights: parameters.highlights
      )
    }
    if adjustCurves {
      values = applyCurves(
        image: values,
        pixelCount: pixelCount,
        channels: channels,
        parameters: parameters
      )
    }
    if adjustColorWheels {
      values = applyColorWheels(
        image: values,
        pixelCount: pixelCount,
        channels: channels,
        parameters: parameters
      )
    }
    if adjustSaturation {
      values = satAdjust(
        image: values,
        width: working.width,
        height: working.height,
        channels: channels,
        saturation: parameters.saturation
      )
    }

    return UInt16Image(
      width: working.width,
      height: working.height,
      channels: working.channels,
      pixels: values.map { UInt16(min(max($0, 0), 65535)) }
    )
  }

  public static func correctedPreviewDensity(
    image: UInt16Image,
    parameters: ProcessingParameters,
    flatField: UInt16Image? = nil
  ) -> UInt16Image {
    let croppedImage = parameters.cropRect.flatMap {
      PerspectiveTransform.crop(image, normalizedRect: $0, borderPercent: parameters.borderCrop)
    } ?? image
    let sourceFlatField = flatField.flatMap { field in
      field.channels == image.channels
        ? field.resized(width: image.width, height: image.height)
        : nil
    }
    let croppedFlatField = sourceFlatField.flatMap { field in
      parameters.cropRect.flatMap {
        PerspectiveTransform.crop(field, normalizedRect: $0, borderPercent: parameters.borderCrop)
      } ?? field
    }
    let working = croppedImage.rotated(
      quarterTurns: parameters.rotation,
      flipHorizontally: parameters.flip
    )
    let orientedFlatField = croppedFlatField?.rotated(
      quarterTurns: parameters.rotation,
      flipHorizontally: parameters.flip
    )
    guard parameters.filmType != .cropOnly else {
      return working
    }

    guard parameters.densityPipelineEnabled,
      let baseDensity = parameters.densityBaseDensity,
      working.channels == 3
    else {
      return working
    }

    let ff = orientedFlatField ?? Self.unityFlatField(for: working)
    var renderReady = FilmNegativeProcessing.densityToRenderReadyLinear(
      image: working,
      flatField: ff,
      baseDensity: baseDensity,
      c41Profile: parameters.densityC41Profile
    )
    if parameters.photoAdjustments.hasToneAdjustment {
      renderReady = renderReady.applyingLinearToneAdjustments(parameters.photoAdjustments)
    }
    let usedLinearSeam = parameters.filmType == .colourNegative
      && parameters.photoAdjustments.hasColorAdjustment
    if usedLinearSeam {
      renderReady = renderReady.applyingProtectedColorAdjustments(parameters.photoAdjustments)
    }
    var display = FilmNegativeProcessing.renderDisplay(
      sceneLinear: renderReady.pixels,
      parameters: parameters.densityDisplayParams
    )

    if parameters.filmType == .blackAndWhiteNegative {
      let pixelCount = working.width * working.height
      for i in 0..<pixelCount {
        let b = display[i * 3]
        let g = display[i * 3 + 1]
        let r = display[i * 3 + 2]
        let gray = 0.114 * b + 0.587 * g + 0.299 * r
        display[i * 3] = gray
        display[i * 3 + 1] = gray
        display[i * 3 + 2] = gray
      }
    }

    let adjustCurves =
      working.channels == 3 && (parameters.curveEnabled || parameters.redCurveEnabled
        || parameters.greenCurveEnabled || parameters.blueCurveEnabled)
    let adjustColorWheels =
      working.channels == 3 && (!parameters.highlightWheel.isNeutral
        || !parameters.midtoneWheel.isNeutral || !parameters.shadowWheel.isNeutral)
    let adjustSaturation = working.channels == 3 && !usedLinearSeam
      && parameters.saturation != 100

    var values = display.map { min(max($0, 0), 1) * 65535.0 }
    let pixelCount = working.width * working.height
    let channels = working.channels

    if adjustCurves {
      values = applyCurves(
        image: values,
        pixelCount: pixelCount,
        channels: channels,
        parameters: parameters
      )
    }
    if adjustColorWheels {
      values = applyColorWheels(
        image: values,
        pixelCount: pixelCount,
        channels: channels,
        parameters: parameters
      )
    }
    if adjustSaturation {
      values = satAdjust(
        image: values,
        width: working.width,
        height: working.height,
        channels: channels,
        saturation: parameters.saturation
      )
    }

    return UInt16Image(
      width: working.width,
      height: working.height,
      channels: working.channels,
      pixels: values.map { UInt16(min(max($0, 0), 65535)) }
    )
  }

  private static func unityFlatField(for image: UInt16Image) -> UInt16Image {
    let count = image.width * image.height * image.channels
    let pixels = [UInt16](repeating: 65535, count: count)
    return UInt16Image(
      width: image.width, height: image.height, channels: image.channels,
      pixels: pixels)
  }

  private static func applySemanticToneToDisplayImage(
    _ image: UInt16Image,
    parameters: PhotoAdjustmentParameters
  ) -> UInt16Image {
    guard image.channels == 3 else { return image }
    var linearPixels = [Double](repeating: 0, count: image.pixels.count)
    for pixelIndex in 0..<(image.width * image.height) {
      let base = pixelIndex * 3
      let linear = FilmNegativeProcessing.linearSRGBToRec2020(
        red: FilmNegativeProcessing.sRGBToLinear(Double(image.pixels[base + 2]) / 65_535),
        green: FilmNegativeProcessing.sRGBToLinear(Double(image.pixels[base + 1]) / 65_535),
        blue: FilmNegativeProcessing.sRGBToLinear(Double(image.pixels[base]) / 65_535)
      )
      linearPixels[base] = linear.blue
      linearPixels[base + 1] = linear.green
      linearPixels[base + 2] = linear.red
    }
    let adjusted = RenderReadyLinearImage(
      width: image.width, height: image.height, pixels: linearPixels
    ).applyingLinearToneAdjustments(parameters)
    var output = [UInt16](repeating: 0, count: image.pixels.count)
    for pixelIndex in 0..<(image.width * image.height) {
      let base = pixelIndex * 3
      let display = FilmNegativeProcessing.linearRec2020ToSRGB(
        red: adjusted.pixels[base + 2],
        green: adjusted.pixels[base + 1],
        blue: adjusted.pixels[base]
      )
      output[base] = UInt16(
        min(max(FilmNegativeProcessing.linearToSRGB(display.blue) * 65_535, 0), 65_535))
      output[base + 1] = UInt16(
        min(max(FilmNegativeProcessing.linearToSRGB(display.green) * 65_535, 0), 65_535))
      output[base + 2] = UInt16(
        min(max(FilmNegativeProcessing.linearToSRGB(display.red) * 65_535, 0), 65_535))
    }
    return UInt16Image(
      width: image.width, height: image.height, channels: image.channels, pixels: output)
  }

  public static func wbAdjustCoeff(
    image: [Double],
    width: Int,
    height: Int,
    channels: Int,
    temp: Int,
    tint: Int
  ) -> [Double] {
    precondition(channels == 3, "White balance requires a 3-channel BGR image")
    guard temp != 0 || tint != 0 else {
      return image
    }

    let tempD = Double(temp)
    let tintD = Double(tint)
    let multiplier = 200.0
    let bCoeff = 1.0 - tempD / multiplier + tintD / multiplier / 2.0
    let gCoeff = 1.0 - tintD / multiplier
    let rCoeff = 1.0 + tempD / multiplier + tintD / multiplier / 2.0

    var result = image
    let pixelCount = width * height
    for i in 0..<pixelCount {
      let base = i * 3
      result[base] *= bCoeff
      result[base + 1] *= gCoeff
      result[base + 2] *= rCoeff
    }
    return result
  }

  public static func satAdjust(
    image: [Double],
    width: Int,
    height: Int,
    channels: Int,
    saturation: Int
  ) -> [Double] {
    precondition(channels == 3, "Saturation adjustment requires a 3-channel BGR image")
    guard saturation != 100 else {
      return image
    }

    let satFactor = Float(saturation) / 100.0
    let pixelCount = width * height
    var result = [Double](repeating: 0, count: pixelCount * 3)

    for i in 0..<pixelCount {
      let base = i * 3
      let r = Float(min(max(0, image[base + 2]), 65535)) / 65535.0
      let g = Float(min(max(0, image[base + 1]), 65535)) / 65535.0
      let b = Float(min(max(0, image[base]), 65535)) / 65535.0

      var (h, s, v) = rgbToHsvFloat32(r: r, g: g, b: b)
      s = min(max(s * satFactor, 0), 1)
      let (r2, g2, b2) = hsvToRgbFloat32(h: h, s: s, v: v)

      result[base] = Double(b2) * 65535.0
      result[base + 1] = Double(g2) * 65535.0
      result[base + 2] = Double(r2) * 65535.0
    }
    return result
  }

  public static func exposure(
    image: [Double],
    gamma: Int,
    shadows: Int,
    highlights: Int
  ) -> [Double] {
    let gammaExponent = pow(2.0, -Double(gamma) / 100.0)
    let shadowsCoefficient = 4.15e-5 * pow(Double(shadows), 2) + 0.02185 * Double(shadows)
    let highlightsCoefficient = -4.15e-5 * pow(Double(highlights), 2) + 0.02185 * Double(highlights)

    return image.map { input in
      var value = Float(min(max(input, 0), 65535) / 65535)

      if gamma != 0 {
        value = Float(pow(Double(value), gammaExponent))
      }

      if shadows != 0 {
        let delta = min(Double(value) - 0.75, 0)
        value = Float(Double(value) + shadowsCoefficient * delta * delta * Double(value))
      }

      if highlights != 0 {
        let delta = max(Double(value) - 0.25, 0)
        value = Float(
          Double(value) + highlightsCoefficient * delta * delta * (1 - Double(value))
        )
      }

      value *= 65535
      return Double(value)
    }
  }

  private static func inverted(_ image: UInt16Image) -> UInt16Image {
    UInt16Image(
      width: image.width,
      height: image.height,
      channels: image.channels,
      pixels: image.pixels.map { UInt16.max - $0 }
    )
  }

  private static func grayscale(_ image: UInt16Image, inverted: Bool) -> UInt16Image {
    guard image.channels == 3 else {
      return inverted ? self.inverted(image) : image
    }

    var pixels = [UInt16]()
    pixels.reserveCapacity(image.width * image.height)
    for index in stride(from: 0, to: image.pixels.count, by: 3) {
      let b = UInt64(image.pixels[index])
      let g = UInt64(image.pixels[index + 1])
      let r = UInt64(image.pixels[index + 2])
      let gray = UInt16((1868 * b + 9617 * g + 4899 * r + 8192) >> 14)
      pixels.append(inverted ? UInt16.max - gray : gray)
    }
    return UInt16Image(width: image.width, height: image.height, channels: 1, pixels: pixels)
  }

  public static func applyCurves(
    image: [Double],
    pixelCount: Int,
    channels: Int,
    parameters: ProcessingParameters
  ) -> [Double] {
    let overallLUT = parameters.curveEnabled
      ? buildCurveLUT(controlPoints: parameters.curveControlPoints) : nil
    let redLUT = parameters.redCurveEnabled
      ? buildCurveLUT(controlPoints: parameters.redCurveControlPoints) : nil
    let greenLUT = parameters.greenCurveEnabled
      ? buildCurveLUT(controlPoints: parameters.greenCurveControlPoints) : nil
    let blueLUT = parameters.blueCurveEnabled
      ? buildCurveLUT(controlPoints: parameters.blueCurveControlPoints) : nil

    var result = image
    for i in 0..<pixelCount {
      let base = i * channels
      let b = UInt16(min(max(result[base], 0), 65535))
      let g = UInt16(min(max(result[base + 1], 0), 65535))
      let r = UInt16(min(max(result[base + 2], 0), 65535))

      let outR = redLUT?[Int(r)] ?? overallLUT?[Int(r)] ?? r
      let outG = greenLUT?[Int(g)] ?? overallLUT?[Int(g)] ?? g
      let outB = blueLUT?[Int(b)] ?? overallLUT?[Int(b)] ?? b

      result[base + 2] = Double(outR)
      result[base + 1] = Double(outG)
      result[base] = Double(outB)
    }
    return result
  }

  public static func applyColorWheels(
    image: [Double],
    pixelCount: Int,
    channels: Int,
    parameters: ProcessingParameters
  ) -> [Double] {
    var result = image

    for i in 0..<pixelCount {
      let base = i * channels
      let b = min(max(result[base], 0), 65535) / 65535.0
      let g = min(max(result[base + 1], 0), 65535) / 65535.0
      let r = min(max(result[base + 2], 0), 65535) / 65535.0

      let luminance = 0.299 * r + 0.587 * g + 0.114 * b

      let rgb = [
        applySingleWheel(
          channel: r, luminance: luminance,
          wheel: parameters.highlightWheel,
          mask: highlightMask(luminance),
          channelIndex: 0
        ),
        applySingleWheel(
          channel: g, luminance: luminance,
          wheel: parameters.highlightWheel,
          mask: highlightMask(luminance),
          channelIndex: 1
        ),
        applySingleWheel(
          channel: b, luminance: luminance,
          wheel: parameters.highlightWheel,
          mask: highlightMask(luminance),
          channelIndex: 2
        ),
      ]

      let afterHighlights = [
        applySingleWheel(
          channel: rgb[0], luminance: luminance,
          wheel: parameters.midtoneWheel,
          mask: midtoneMask(luminance),
          channelIndex: 0
        ),
        applySingleWheel(
          channel: rgb[1], luminance: luminance,
          wheel: parameters.midtoneWheel,
          mask: midtoneMask(luminance),
          channelIndex: 1
        ),
        applySingleWheel(
          channel: rgb[2], luminance: luminance,
          wheel: parameters.midtoneWheel,
          mask: midtoneMask(luminance),
          channelIndex: 2
        ),
      ]

      let afterMidtones = [
        applySingleWheel(
          channel: afterHighlights[0], luminance: luminance,
          wheel: parameters.shadowWheel,
          mask: shadowMask(luminance),
          channelIndex: 0
        ),
        applySingleWheel(
          channel: afterHighlights[1], luminance: luminance,
          wheel: parameters.shadowWheel,
          mask: shadowMask(luminance),
          channelIndex: 1
        ),
        applySingleWheel(
          channel: afterHighlights[2], luminance: luminance,
          wheel: parameters.shadowWheel,
          mask: shadowMask(luminance),
          channelIndex: 2
        ),
      ]

      let finalR = afterMidtones[0]
      let finalG = afterMidtones[1]
      let finalB = afterMidtones[2]

      let newLuminance = 0.299 * finalR + 0.587 * finalG + 0.114 * finalB
      let lumRatio = luminance / max(newLuminance, 1e-9)

      result[base + 2] = min(max(finalR * lumRatio, 0), 1) * 65535.0
      result[base + 1] = min(max(finalG * lumRatio, 0), 1) * 65535.0
      result[base] = min(max(finalB * lumRatio, 0), 1) * 65535.0
    }

    return result
  }

  public static func buildCurveLUT(controlPoints: [CurvePoint]) -> [UInt16]? {
    guard controlPoints.count >= 2 else { return nil }
    let sorted = controlPoints.sorted { $0.input < $1.input }
    var lut = [UInt16](repeating: 0, count: 65536)
    var cpIndex = 0
    for i in 0..<65536 {
      let x = Double(i) / 65535.0
      while cpIndex + 1 < sorted.count && sorted[cpIndex + 1].input < x {
        cpIndex += 1
      }
      let lo = sorted[cpIndex]
      let hi = cpIndex + 1 < sorted.count ? sorted[cpIndex + 1] : lo
      let range = hi.input - lo.input
      let t = range > 0 ? min(max((x - lo.input) / range, 0), 1) : 1.0
      let y = lo.output + t * (hi.output - lo.output)
      lut[i] = UInt16(min(max(y * 65535.0, 0), 65535))
    }
    return lut
  }

  public static func highlightMask(_ luminance: Double) -> Double {
    if luminance <= 0.3 { return 0 }
    if luminance >= 0.7 { return 1 }
    let t = (luminance - 0.3) / 0.4
    return t * t * (3 - 2 * t)
  }

  public static func midtoneMask(_ luminance: Double) -> Double {
    let centered = abs(luminance - 0.5)
    if centered >= 0.5 { return 0 }
    let t = 1.0 - centered * 2.0
    return t * t * (3 - 2 * t)
  }

  public static func shadowMask(_ luminance: Double) -> Double {
    if luminance <= 0.3 { return 1 }
    if luminance >= 0.7 { return 0 }
    let t = (0.7 - luminance) / 0.4
    return t * t * (3 - 2 * t)
  }

  public static func wheelRGB(_ wheel: ColorWheel) -> (r: Double, g: Double, b: Double) {
    guard wheel.strength > 0, wheel.strength <= 1 else {
      return (0, 0, 0)
    }
    let (r, g, b) = hsvToRgbFloat64(h: wheel.hue / 360.0, s: 1.0, v: 1.0)
    let pushR = (r * 2.0 - 1.0) * wheel.strength * 0.3
    let pushG = (g * 2.0 - 1.0) * wheel.strength * 0.3
    let pushB = (b * 2.0 - 1.0) * wheel.strength * 0.3
    return (pushR, pushG, pushB)
  }

  private static func applySingleWheel(
    channel: Double,
    luminance _: Double,
    wheel: ColorWheel,
    mask: Double,
    channelIndex: Int
  ) -> Double {
    guard !wheel.isNeutral, mask > 0 else { return channel }
    let (pr, pg, pb) = Self.wheelRGB(wheel)
    let push: Double
    switch channelIndex {
    case 0: push = pr
    case 1: push = pg
    default: push = pb
    }
    let gain = 1.0 + push * mask
    return channel * gain
  }

}

private func rgbToHsvFloat32(r: Float, g: Float, b: Float) -> (h: Float, s: Float, v: Float) {
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  let delta = mx - mn

  let v = mx
  let s = mx > 0 ? delta / mx : 0

  var h: Float = 0
  if delta > 0 {
    if mx == r {
      h = 60.0 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
    } else if mx == g {
      h = 60.0 * ((b - r) / delta + 2)
    } else {
      h = 60.0 * ((r - g) / delta + 4)
    }
  }
  if h < 0 { h += 360 }

  return (h / 360.0, s, v)
}

private func hsvToRgbFloat32(h: Float, s: Float, v: Float) -> (r: Float, g: Float, b: Float) {
  if s == 0 {
    return (v, v, v)
  }

  let h6 = h * 6.0
  let i = Int(floor(h6))
  let f = h6 - Float(i)

  let p = v * (1 - s)
  let q = v * (1 - s * f)
  let t = v * (1 - s * (1 - f))

  switch i % 6 {
  case 0: return (v, t, p)
  case 1: return (q, v, p)
  case 2: return (p, v, t)
  case 3: return (p, q, v)
  case 4: return (t, p, v)
  default: return (v, p, q)
  }
}

private func hsvToRgbFloat64(h: Double, s: Double, v: Double) -> (r: Double, g: Double, b: Double)
{
  if s == 0 {
    return (v, v, v)
  }

  let h6 = h * 6.0
  let i = Int(floor(h6))
  let f = h6 - Double(i)

  let p = v * (1 - s)
  let q = v * (1 - s * f)
  let t = v * (1 - s * (1 - f))

  switch i % 6 {
  case 0: return (v, t, p)
  case 1: return (q, v, p)
  case 2: return (p, v, t)
  case 3: return (p, q, v)
  case 4: return (t, p, v)
  default: return (v, p, q)
  }
}
