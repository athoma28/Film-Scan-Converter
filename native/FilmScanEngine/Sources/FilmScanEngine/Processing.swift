import Foundation

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
      working = grayscale(working, inverted: true)
    } else if parameters.filmType == .colourNegative {
      working = inverted(working)
    }

    let adjustWhiteBalance =
      working.channels == 3 && (parameters.temperature != 0 || parameters.tint != 0)
    let adjustExposure =
      parameters.gamma != 0 || parameters.shadows != 0 || parameters.highlights != 0
    let adjustSaturation = working.channels == 3 && parameters.saturation != 100
    guard adjustWhiteBalance || adjustExposure || adjustSaturation else {
      return working
    }

    var values = working.pixels.map(Double.init)
    if adjustWhiteBalance {
      values = wbAdjustCoeff(
        image: values,
        width: working.width,
        height: working.height,
        channels: working.channels,
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
    if adjustSaturation {
      values = satAdjust(
        image: values,
        width: working.width,
        height: working.height,
        channels: working.channels,
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
