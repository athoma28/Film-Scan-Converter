import Foundation

public enum GPUKernelModel {
  public static func gpuKernelEquivalent(
    image: UInt16Image,
    parameters: ProcessingParameters
  ) -> UInt16Image {
    let working = image.rotated(
      quarterTurns: parameters.rotation,
      flipHorizontally: parameters.flip
    )
    guard working.channels == 3, parameters.filmType != .cropOnly else {
      return working
    }

    let pixelCount = working.width * working.height
    var rgb = [Float](repeating: 0, count: pixelCount * 3)

    for i in 0..<pixelCount {
      let base = i * 3
      rgb[base + 2] = Float(working.pixels[base + 2]) / 65535.0  // R
      rgb[base + 1] = Float(working.pixels[base + 1]) / 65535.0  // G
      rgb[base] = Float(working.pixels[base]) / 65535.0          // B
    }

    if parameters.filmType == .blackAndWhiteNegative {
      if parameters.filmNegativeParams.enabled {
        let fnp = parameters.filmNegativeParams
        let rexp = Float(-(fnp.greenExp * fnp.redRatio))
        let gexp = Float(-fnp.greenExp)
        let bexp = Float(-(fnp.greenExp * fnp.blueRatio))
        let multTarget = Float(FilmNegativeProcessing.calibrationTargetFraction)
        let bM: Float
        let gM: Float
        let rM: Float
        if let med = fnp.measuredMedians {
          bM = Float(med.blue) / 65535.0
          gM = Float(med.green) / 65535.0
          rM = Float(med.red) / 65535.0
        } else {
          bM = channelMedianFloat(pixels: rgb, channel: 0, pixelCount: pixelCount)
          gM = channelMedianFloat(pixels: rgb, channel: 1, pixelCount: pixelCount)
          rM = channelMedianFloat(pixels: rgb, channel: 2, pixelCount: pixelCount)
        }
        let bMult = multTarget / pow(max(bM, 1.0 / 65535.0), bexp)
        let gMult = multTarget / pow(max(gM, 1.0 / 65535.0), gexp)
        let rMult = multTarget / pow(max(rM, 1.0 / 65535.0), rexp)
        for i in 0..<pixelCount {
          let base = i * 3
          rgb[base + 2] = clamp(rMult * pow(rgb[base + 2], rexp), 0, 1)
          rgb[base + 1] = clamp(gMult * pow(rgb[base + 1], gexp), 0, 1)
          rgb[base] = clamp(bMult * pow(rgb[base], bexp), 0, 1)
        }
        for i in 0..<pixelCount {
          let base = i * 3
          let gray = 0.299 * rgb[base + 2] + 0.587 * rgb[base + 1] + 0.114 * rgb[base]
          rgb[base + 2] = gray
          rgb[base + 1] = gray
          rgb[base] = gray
        }
      } else {
        for i in 0..<pixelCount {
          let base = i * 3
          let gray = 0.299 * rgb[base + 2] + 0.587 * rgb[base + 1] + 0.114 * rgb[base]
          let inv = 1.0 - gray
          rgb[base + 2] = inv
          rgb[base + 1] = inv
          rgb[base] = inv
        }
      }
    } else {
      if parameters.filmType == .colourNegative {
        if parameters.filmNegativeParams.enabled {
          let fnp = parameters.filmNegativeParams
          let rexp = Float(-(fnp.greenExp * fnp.redRatio))
          let gexp = Float(-fnp.greenExp)
          let bexp = Float(-(fnp.greenExp * fnp.blueRatio))
          let multTarget = Float(FilmNegativeProcessing.calibrationTargetFraction)
          let bM: Float
          let gM: Float
          let rM: Float
          if let med = fnp.measuredMedians {
            bM = Float(med.blue) / 65535.0
            gM = Float(med.green) / 65535.0
            rM = Float(med.red) / 65535.0
          } else {
            bM = channelMedianFloat(pixels: rgb, channel: 0, pixelCount: pixelCount)
            gM = channelMedianFloat(pixels: rgb, channel: 1, pixelCount: pixelCount)
            rM = channelMedianFloat(pixels: rgb, channel: 2, pixelCount: pixelCount)
          }
          let bMult = multTarget / pow(max(bM, 1.0 / 65535.0), bexp)
          let gMult = multTarget / pow(max(gM, 1.0 / 65535.0), gexp)
          let rMult = multTarget / pow(max(rM, 1.0 / 65535.0), rexp)
          for i in 0..<pixelCount {
            let base = i * 3
            rgb[base + 2] = clamp(rMult * pow(rgb[base + 2], rexp), 0, 1)
            rgb[base + 1] = clamp(gMult * pow(rgb[base + 1], gexp), 0, 1)
            rgb[base] = clamp(bMult * pow(rgb[base], bexp), 0, 1)
          }
        } else {
          for i in 0..<pixelCount {
            let base = i * 3
            rgb[base + 2] = 1.0 - rgb[base + 2]
            rgb[base + 1] = 1.0 - rgb[base + 1]
            rgb[base] = 1.0 - rgb[base]
          }
        }
      }

      let rCoeff = 1.0 + Float(parameters.temperature) / 200.0 + Float(parameters.tint) / 400.0
      let gCoeff = 1.0 - Float(parameters.tint) / 200.0
      let bCoeff = 1.0 - Float(parameters.temperature) / 200.0 + Float(parameters.tint) / 400.0

      if parameters.temperature != 0 || parameters.tint != 0 {
        for i in 0..<pixelCount {
          let base = i * 3
          rgb[base + 2] *= rCoeff
          rgb[base + 1] *= gCoeff
          rgb[base] *= bCoeff
        }
      }

    }

    if parameters.gamma != 0 || parameters.shadows != 0 || parameters.highlights != 0 {
      let gammaExponent = powf(2.0, -Float(parameters.gamma) / 100.0)
      let shadowsCoefficient = 4.15e-5 * Float(parameters.shadows) * Float(parameters.shadows)
        + 0.02185 * Float(parameters.shadows)
      let highlightsCoefficient = -4.15e-5 * Float(parameters.highlights) * Float(parameters.highlights)
        + 0.02185 * Float(parameters.highlights)

      for i in 0..<pixelCount {
        let base = i * 3
        var r = clamp(rgb[base + 2], 0, 1)
        var g = clamp(rgb[base + 1], 0, 1)
        var b = clamp(rgb[base], 0, 1)

        if parameters.gamma != 0 {
          r = powf(r, gammaExponent)
          g = powf(g, gammaExponent)
          b = powf(b, gammaExponent)
        }
        if parameters.shadows != 0 {
          let dr = min(r - 0.75, 0)
          let dg = min(g - 0.75, 0)
          let db = min(b - 0.75, 0)
          r += shadowsCoefficient * dr * dr * r
          g += shadowsCoefficient * dg * dg * g
          b += shadowsCoefficient * db * db * b
        }
        if parameters.highlights != 0 {
          let dr = max(r - 0.25, 0)
          let dg = max(g - 0.25, 0)
          let db = max(b - 0.25, 0)
          r += highlightsCoefficient * dr * dr * (1.0 - r)
          g += highlightsCoefficient * dg * dg * (1.0 - g)
          b += highlightsCoefficient * db * db * (1.0 - b)
        }
        rgb[base + 2] = r
        rgb[base + 1] = g
        rgb[base] = b
      }
    }

    let isBW = parameters.filmType == .blackAndWhiteNegative
    let adjustCurves = !isBW && (parameters.curveEnabled || parameters.redCurveEnabled
      || parameters.greenCurveEnabled || parameters.blueCurveEnabled)
    let adjustColorWheels = !isBW && (!parameters.highlightWheel.isNeutral
      || !parameters.midtoneWheel.isNeutral || !parameters.shadowWheel.isNeutral)

    if adjustCurves || adjustColorWheels {
      for i in 0..<pixelCount {
        let base = i * 3
        var r = clamp(rgb[base + 2], 0, 1)
        var g = clamp(rgb[base + 1], 0, 1)
        var b = clamp(rgb[base], 0, 1)

        if adjustCurves {
          let r16 = UInt16(min(max(r * 65535.0, 0), 65535))
          let g16 = UInt16(min(max(g * 65535.0, 0), 65535))
          let b16 = UInt16(min(max(b * 65535.0, 0), 65535))

          let overallLUT = parameters.curveEnabled
            ? FilmProcessing.buildCurveLUT(controlPoints: parameters.curveControlPoints) : nil
          let redLUT = parameters.redCurveEnabled
            ? FilmProcessing.buildCurveLUT(controlPoints: parameters.redCurveControlPoints) : nil
          let greenLUT = parameters.greenCurveEnabled
            ? FilmProcessing.buildCurveLUT(controlPoints: parameters.greenCurveControlPoints) : nil
          let blueLUT = parameters.blueCurveEnabled
            ? FilmProcessing.buildCurveLUT(controlPoints: parameters.blueCurveControlPoints) : nil

          let outR = Float(redLUT?[Int(r16)] ?? overallLUT?[Int(r16)] ?? r16) / 65535.0
          let outG = Float(greenLUT?[Int(g16)] ?? overallLUT?[Int(g16)] ?? g16) / 65535.0
          let outB = Float(blueLUT?[Int(b16)] ?? overallLUT?[Int(b16)] ?? b16) / 65535.0

          r = outR
          g = outG
          b = outB
        }

        if adjustColorWheels {
          let luminance = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)

          let applyWheel = { (ch: Float, ci: Int, wheel: ColorWheel, maskFn: (Double) -> Double) -> Float in
            guard !wheel.isNeutral else { return ch }
            let mask = maskFn(luminance)
            if mask <= 0 { return ch }
            let (pr, pg, pb) = FilmProcessing.wheelRGB(wheel)
            let push: Double
            switch ci {
            case 0: push = pr
            case 1: push = pg
            default: push = pb
            }
            let gain = 1.0 + push * mask
            return Float(Double(ch) * gain)
          }

          r = applyWheel(r, 0, parameters.highlightWheel, FilmProcessing.highlightMask)
          g = applyWheel(g, 1, parameters.highlightWheel, FilmProcessing.highlightMask)
          b = applyWheel(b, 2, parameters.highlightWheel, FilmProcessing.highlightMask)

          r = applyWheel(r, 0, parameters.midtoneWheel, FilmProcessing.midtoneMask)
          g = applyWheel(g, 1, parameters.midtoneWheel, FilmProcessing.midtoneMask)
          b = applyWheel(b, 2, parameters.midtoneWheel, FilmProcessing.midtoneMask)

          r = applyWheel(r, 0, parameters.shadowWheel, FilmProcessing.shadowMask)
          g = applyWheel(g, 1, parameters.shadowWheel, FilmProcessing.shadowMask)
          b = applyWheel(b, 2, parameters.shadowWheel, FilmProcessing.shadowMask)

          let newLum = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
          let lumRatio = luminance / max(newLum, 1e-9)
          r = Float(Double(r) * lumRatio)
          g = Float(Double(g) * lumRatio)
          b = Float(Double(b) * lumRatio)

          r = clamp(r, 0, 1)
          g = clamp(g, 0, 1)
          b = clamp(b, 0, 1)
        }

        rgb[base + 2] = r
        rgb[base + 1] = g
        rgb[base] = b
      }
    }

    if !isBW && parameters.saturation != 100 {
      let satFactor = Float(parameters.saturation) / 100.0
      for i in 0..<pixelCount {
        let base = i * 3
        let r = clamp(rgb[base + 2], 0, 1)
        let g = clamp(rgb[base + 1], 0, 1)
        let b = clamp(rgb[base], 0, 1)
        var (h, s, v) = rgbToHsvFloat32(r: r, g: g, b: b)
        s = clamp(s * satFactor, 0, 1)
        let (r2, g2, b2) = hsvToRgbFloat32(h: h, s: s, v: v)
        rgb[base + 2] = r2
        rgb[base + 1] = g2
        rgb[base] = b2
      }
    }

    var out = [UInt16](repeating: 0, count: pixelCount * 3)
    for i in 0..<pixelCount {
      let base = i * 3
      out[base + 2] = UInt16(clamp(rgb[base + 2], 0, 1) * 65535.0)
      out[base + 1] = UInt16(clamp(rgb[base + 1], 0, 1) * 65535.0)
      out[base] = UInt16(clamp(rgb[base], 0, 1) * 65535.0)
    }

    return UInt16Image(
      width: working.width, height: working.height,
      channels: working.channels, pixels: out
    )
  }
}

private func clamp(_ value: Float, _ lo: Float, _ hi: Float) -> Float {
  min(max(value, lo), hi)
}

private func channelMedianFloat(pixels: [Float], channel: Int, pixelCount: Int) -> Float {
  var vals = [Float]()
  vals.reserveCapacity(pixelCount)
  for i in 0..<pixelCount {
    vals.append(pixels[i * 3 + channel])
  }
  vals.sort()
  guard !vals.isEmpty else { return 0 }
  let mid = vals.count / 2
  if vals.count.isMultiple(of: 2) {
    return (vals[mid - 1] + vals[mid]) / 2.0
  }
  return vals[mid]
}

public enum FilmProcessing {
  public static func correctedPreview(
    image: UInt16Image,
    parameters: ProcessingParameters
  ) -> UInt16Image {
    var working = image.rotated(
      quarterTurns: parameters.rotation,
      flipHorizontally: parameters.flip
    )
    guard parameters.filmType != .cropOnly else {
      return working
    }

    if parameters.filmType == .blackAndWhiteNegative {
      if parameters.filmNegativeParams.enabled {
        working = FilmNegativeProcessing.applyPowerLawInversion(
          image: working, params: parameters.filmNegativeParams
        )
        working = grayscale(working, inverted: false)
      } else {
        working = grayscale(working, inverted: true)
      }
    } else if parameters.filmType == .colourNegative {
      if parameters.filmNegativeParams.enabled {
        working = FilmNegativeProcessing.applyPowerLawInversion(
          image: working, params: parameters.filmNegativeParams
        )
      } else {
        working = inverted(working)
      }
    }

    let adjustWhiteBalance =
      working.channels == 3 && (parameters.temperature != 0 || parameters.tint != 0)
    let adjustExposure =
      parameters.gamma != 0 || parameters.shadows != 0 || parameters.highlights != 0
    let adjustCurves =
      working.channels == 3 && (parameters.curveEnabled || parameters.redCurveEnabled
        || parameters.greenCurveEnabled || parameters.blueCurveEnabled)
    let adjustColorWheels =
      working.channels == 3 && (!parameters.highlightWheel.isNeutral
        || !parameters.midtoneWheel.isNeutral || !parameters.shadowWheel.isNeutral)
    let adjustSaturation = working.channels == 3 && parameters.saturation != 100
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

  public static func histogramEqualisation(
    image: UInt16Image,
    filmType: FilmType,
    blackPoint: Int,
    whitePoint: Int,
    baseDetect: Bool,
    baseRGB: [UInt8]
  ) -> [Double] {
    let sensitivity: Double = 0.2
    let blackPointPercentile: Double = 0.5
    let whitePointPercentile: Double = 99.0

    let width = image.width
    let height = image.height
    let channels = image.channels
    let pixelCount = width * height

    var img = image.pixels.map(Double.init)

    var channelSorted = [[Double]]()
    channelSorted.reserveCapacity(channels)
    for c in 0..<channels {
      var vals = [Double]()
      vals.reserveCapacity(pixelCount)
      for i in stride(from: c, to: img.count, by: channels) {
        vals.append(img[i])
      }
      vals.sort()
      channelSorted.append(vals)
    }

    var blackPoints = [Double](repeating: 0, count: channels)
    if baseDetect && (filmType == .colourNegative || filmType == .slide) {
      for c in 0..<channels {
        let rgbIndex = 2 - c
        let baseVal = Double(baseRGB[rgbIndex]) * 256.0
        if filmType == .colourNegative {
          blackPoints[c] = 65535.0 - baseVal
        } else {
          blackPoints[c] = baseVal
        }
      }
    } else {
      for c in 0..<channels {
        blackPoints[c] = percentile(channelSorted[c], blackPointPercentile)
      }
    }

    let targetBlack = Double(blackPoint) / 100.0 * sensitivity * 65535.0
    var blackOffsets = [Double](repeating: 0, count: channels)
    for c in 0..<channels {
      blackOffsets[c] = targetBlack - blackPoints[c]
    }

    for i in 0..<pixelCount {
      for c in 0..<channels {
        img[i * channels + c] += blackOffsets[c]
      }
    }

    var offsetSorted = [[Double]]()
    offsetSorted.reserveCapacity(channels)
    for c in 0..<channels {
      var vals = [Double]()
      vals.reserveCapacity(pixelCount)
      for i in stride(from: c, to: img.count, by: channels) {
        vals.append(img[i])
      }
      vals.sort()
      offsetSorted.append(vals)
    }

    var whitePoints = [Double](repeating: 0, count: channels)
    for c in 0..<channels {
      whitePoints[c] = percentile(offsetSorted[c], whitePointPercentile)
    }

    let targetWhite = 65535.0 + Double(whitePoint) / 100.0 * sensitivity * 65535.0
    var whiteMultipliers = [Double](repeating: 1.0, count: channels)
    for c in 0..<channels {
      if whitePoints[c] > 0 {
        whiteMultipliers[c] = targetWhite / whitePoints[c]
      }
    }

    for i in 0..<pixelCount {
      for c in 0..<channels {
        img[i * channels + c] *= whiteMultipliers[c]
      }
    }

    return img
  }
}

private func percentile(_ sorted: [Double], _ p: Double) -> Double {
  guard !sorted.isEmpty else { return 0 }
  guard sorted.count > 1 else { return sorted[0] }

  let index = Double(sorted.count - 1) * p / 100.0
  let lower = Int(floor(index))
  let upper = min(lower + 1, sorted.count - 1)
  let fraction = index - Double(lower)
  return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
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
