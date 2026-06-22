import CoreImage
import FilmScanEngine
import Metal

public final class StillPreviewRenderer: @unchecked Sendable {
  private let source: CIImage
  private let curveLUTLock = NSLock()
  private var curveLUTCache: [CurveLUTKey: CIImage] = [:]

  nonisolated(unsafe) private static let sharedKernel: CIKernel? = {
    CIKernel(source: correctionKernelSource)
  }()
  nonisolated(unsafe) private static let sharedContext: CIContext = {
    let options: [CIContextOption: Any] = [
      .cacheIntermediates: false,
      .workingColorSpace: NSNull(),
      .outputColorSpace: NSNull(),
    ]
    if let device = MTLCreateSystemDefaultDevice() {
      return CIContext(mtlDevice: device, options: options)
    }
    return CIContext(options: [.useSoftwareRenderer: false] as [CIContextOption: Any])
  }()

  public init?(image: UInt16Image) {
    guard
      let cgImage = image.makePreviewCGImage16(),
      let kernel = Self.sharedKernel
    else {
      return nil
    }

    source = CIImage(cgImage: cgImage)
    correctionKernel = kernel
  }

  private let correctionKernel: CIKernel

  public func render(parameters: ProcessingParameters, showOriginal: Bool) -> CGImage? {
    let oriented = orientedSource(parameters: parameters)
    let output: CIImage

    if showOriginal || parameters.filmType == .cropOnly {
      output = oriented
    } else {
      let lutImage = curveLUTImage(parameters: parameters)

      let fnp = parameters.filmNegativeParams
      let fnEnabled = parameters.filmNegativeParams.enabled
        && (parameters.filmType == .colourNegative || parameters.filmType == .blackAndWhiteNegative)
        && fnp.measuredMedians != nil
      let (fnRExp, fnGExp, fnBExp): (Float, Float, Float)
      let (fnRMult, fnGMult, fnBMult): (Float, Float, Float)

      if fnEnabled, let medians = fnp.measuredMedians {
        fnRExp = Float(-(fnp.greenExp * fnp.redRatio))
        fnGExp = Float(-fnp.greenExp)
        fnBExp = Float(-(fnp.greenExp * fnp.blueRatio))
        let multipliers = FilmNegativeProcessing.computeMultipliers(
          medians: medians,
          params: fnp
        )
        fnRMult = Float(multipliers.r)
        fnGMult = Float(multipliers.g)
        fnBMult = Float(multipliers.b)
      } else {
        fnRExp = 0; fnGExp = 0; fnBExp = 0
        fnRMult = 1; fnGMult = 1; fnBMult = 1
      }

      guard
        let corrected = correctionKernel.apply(
          extent: oriented.extent,
          roiCallback: { inputIndex, destinationRect in
            inputIndex == 1 ? lutImage.extent : destinationRect
          },
          arguments: [
            oriented,
            lutImage,
            Float(parameters.filmType.rawValue),
            Float(parameters.temperature),
            Float(parameters.tint),
            Float(parameters.gamma),
            Float(parameters.shadows),
            Float(parameters.highlights),
            Float(parameters.saturation),
            Float(parameters.photoAdjustments.exposureEV),
            Float(parameters.photoAdjustments.brightness),
            Float(parameters.photoAdjustments.contrast),
            Float(parameters.photoAdjustments.highlights),
            Float(parameters.photoAdjustments.shadows),
            Float(parameters.photoAdjustments.temperatureShiftMired),
            Float(parameters.photoAdjustments.tint),
            Float(parameters.photoAdjustments.saturation),
            Float(parameters.photoAdjustments.vibrance),
            Float(parameters.highlightWheel.hue),
            Float(parameters.highlightWheel.strength),
            Float(parameters.midtoneWheel.hue),
            Float(parameters.midtoneWheel.strength),
            Float(parameters.shadowWheel.hue),
            Float(parameters.shadowWheel.strength),
            Float(fnEnabled ? 1 : 0),
            fnRExp,
            fnGExp,
            fnBExp,
            fnRMult,
            fnGMult,
            fnBMult,
          ]
        )
      else {
        return nil
      }
      output = corrected
    }

    return Self.sharedContext.createCGImage(
      output,
      from: output.extent,
      format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
    )
  }

  private func curveLUTImage(parameters: ProcessingParameters) -> CIImage {
    let key = CurveLUTKey(parameters: parameters)
    curveLUTLock.lock()
    defer { curveLUTLock.unlock() }
    if let cached = curveLUTCache[key] {
      return cached
    }
    let image = Self.makeCurveLUTImage(parameters: parameters)
    if curveLUTCache.count >= 8 {
      curveLUTCache.removeAll(keepingCapacity: true)
    }
    curveLUTCache[key] = image
    return image
  }

  private func orientedSource(parameters: ProcessingParameters) -> CIImage {
    let rotated: CIImage
    switch ((parameters.rotation % 4) + 4) % 4 {
    case 1:
      rotated = source.oriented(.right)
    case 2:
      rotated = source.oriented(.down)
    case 3:
      rotated = source.oriented(.left)
    default:
      rotated = source
    }

    guard parameters.flip else {
      return rotated
    }
    return rotated.transformed(
      by: CGAffineTransform(translationX: rotated.extent.maxX, y: 0)
        .scaledBy(x: -1, y: 1)
    )
  }

  static func makeCurveLUTImage(parameters: ProcessingParameters) -> CIImage {
    let hasAnyCurve = parameters.curveEnabled || parameters.redCurveEnabled
      || parameters.greenCurveEnabled || parameters.blueCurveEnabled
    let overallLUT = parameters.curveEnabled
      ? FilmProcessing.buildCurveLUT(controlPoints: parameters.curveControlPoints) : nil
    let redLUT = parameters.redCurveEnabled
      ? FilmProcessing.buildCurveLUT(controlPoints: parameters.redCurveControlPoints) : nil
    let greenLUT = parameters.greenCurveEnabled
      ? FilmProcessing.buildCurveLUT(controlPoints: parameters.greenCurveControlPoints) : nil
    let blueLUT = parameters.blueCurveEnabled
      ? FilmProcessing.buildCurveLUT(controlPoints: parameters.blueCurveControlPoints) : nil

    let width = 256
    let height = 256
    var pixels = [UInt8](repeating: 0, count: width * height * 4)

    for y in 0..<height {
      for x in 0..<width {
        let flatIndex = y * width + x
        let offset = flatIndex * 4

        let rOut: UInt16
        let gOut: UInt16
        let bOut: UInt16

        if hasAnyCurve {
          let rIdx = UInt16(flatIndex)
          rOut = redLUT?[Int(rIdx)] ?? overallLUT?[Int(rIdx)] ?? rIdx
          gOut = greenLUT?[Int(rIdx)] ?? overallLUT?[Int(rIdx)] ?? rIdx
          bOut = blueLUT?[Int(rIdx)] ?? overallLUT?[Int(rIdx)] ?? rIdx
        } else {
          rOut = UInt16(flatIndex)
          gOut = UInt16(flatIndex)
          bOut = UInt16(flatIndex)
        }

        pixels[offset] = UInt8(rOut >> 8)
        pixels[offset + 1] = UInt8(gOut >> 8)
        pixels[offset + 2] = UInt8(bOut >> 8)
        pixels[offset + 3] = 255
      }
    }

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGBitmapInfo(
      rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )

    guard
      let data = CFDataCreate(nil, pixels, pixels.count),
      let provider = CGDataProvider(data: data),
      let cgImage = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo,
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
      )
    else {
      return CIImage(color: CIColor(red: 0, green: 0, blue: 0))
    }

    return CIImage(cgImage: cgImage)
  }

  private static let correctionKernelSource = """
    vec3 rgbToHsv(vec3 rgb) {
      float mx = max(rgb.r, max(rgb.g, rgb.b));
      float mn = min(rgb.r, min(rgb.g, rgb.b));
      float delta = mx - mn;
      float hue = 0.0;
      if (delta > 0.0) {
        if (mx == rgb.r) {
          hue = (rgb.g - rgb.b) / delta;
          hue -= floor(hue / 6.0) * 6.0;
        } else if (mx == rgb.g) {
          hue = (rgb.b - rgb.r) / delta + 2.0;
        } else {
          hue = (rgb.r - rgb.g) / delta + 4.0;
        }
        hue /= 6.0;
        if (hue < 0.0) {
          hue += 1.0;
        }
      }
      return vec3(hue, mx > 0.0 ? delta / mx : 0.0, mx);
    }

    vec3 hsvToRgb(vec3 hsv) {
      if (hsv.y == 0.0) {
        return vec3(hsv.z);
      }
      float h6 = hsv.x * 6.0;
      int sector = int(floor(h6));
      float fraction = h6 - float(sector);
      float p = hsv.z * (1.0 - hsv.y);
      float q = hsv.z * (1.0 - hsv.y * fraction);
      float t = hsv.z * (1.0 - hsv.y * (1.0 - fraction));
      if (sector == 0) return vec3(hsv.z, t, p);
      if (sector == 1) return vec3(q, hsv.z, p);
      if (sector == 2) return vec3(p, hsv.z, t);
      if (sector == 3) return vec3(p, q, hsv.z);
      if (sector == 4) return vec3(t, p, hsv.z);
      return vec3(hsv.z, p, q);
    }

    float filmNegativeSrgbToLinear(float value) {
      float x = clamp(value, 0.0, 1.0);
      return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
    }

    float filmNegativeLinearToSrgb(float value) {
      float x = clamp(value, 0.0, 1.0);
      return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
    }

    float filmNegativeToneCurve(float value) {
      float first = clamp(value / 0.8854460, 0.0, 1.0);
      float x0, y0, ypp0, x1, y1, ypp1;
      if (first <= 0.03975058) {
        x0 = 0.0; y0 = 0.0; ypp0 = 0.0;
        x1 = 0.03975058; y1 = 0.02017177; ypp1 = 6.2215877;
      } else if (first <= 0.54669745) {
        x0 = 0.03975058; y0 = 0.02017177; ypp0 = 6.2215877;
        x1 = 0.54669745; y1 = 0.69419975; ypp1 = -3.6885633;
      } else {
        x0 = 0.54669745; y0 = 0.69419975; ypp0 = -3.6885633;
        x1 = 1.0; y1 = 1.0; ypp1 = 0.0;
      }
      float h = x1 - x0;
      float a = (x1 - first) / h;
      float b = (first - x0) / h;
      float result = a * y0 + b * y1
        + ((a * a * a - a) * ypp0 + (b * b * b - b) * ypp1) * h * h / 6.0;
      return clamp(result, 0.0, 1.0);
    }

    vec3 filmNegativeLinearValue(vec3 value, vec3 exponent, vec3 multiplier) {
      vec3 linear = vec3(filmNegativeSrgbToLinear(value.r),
                         filmNegativeSrgbToLinear(value.g),
                         filmNegativeSrgbToLinear(value.b));
      vec3 working = vec3(
        0.6274039 * linear.r + 0.3292830 * linear.g + 0.0433131 * linear.b,
        0.0690973 * linear.r + 0.9195404 * linear.g + 0.0113623 * linear.b,
        0.0163914 * linear.r + 0.0880133 * linear.g + 0.8955953 * linear.b);
      return multiplier * pow(max(working, vec3(1.0 / 65535.0)), exponent);
    }

    vec3 filmNegativeDisplayFromLinear(vec3 inverted) {
      vec3 displayLinear = vec3(
        1.6604910 * inverted.r - 0.5876411 * inverted.g - 0.0728499 * inverted.b,
        -0.1245505 * inverted.r + 1.1328999 * inverted.g - 0.0083494 * inverted.b,
        -0.0181508 * inverted.r - 0.1005789 * inverted.g + 1.1187297 * inverted.b);
      return vec3(
        filmNegativeToneCurve(filmNegativeLinearToSrgb(displayLinear.r)),
        filmNegativeToneCurve(filmNegativeLinearToSrgb(displayLinear.g)),
        filmNegativeToneCurve(filmNegativeLinearToSrgb(displayLinear.b)));
    }

    vec3 displayLinearValue(vec3 value) {
      vec3 linear = vec3(filmNegativeSrgbToLinear(value.r),
                         filmNegativeSrgbToLinear(value.g),
                         filmNegativeSrgbToLinear(value.b));
      return vec3(
        0.6274039 * linear.r + 0.3292830 * linear.g + 0.0433131 * linear.b,
        0.0690973 * linear.r + 0.9195404 * linear.g + 0.0113623 * linear.b,
        0.0163914 * linear.r + 0.0880133 * linear.g + 0.8955953 * linear.b);
    }

    vec3 displayFromLinear(vec3 value) {
      vec3 displayLinear = vec3(
        1.6604910 * value.r - 0.5876411 * value.g - 0.0728499 * value.b,
        -0.1245505 * value.r + 1.1328999 * value.g - 0.0083494 * value.b,
        -0.0181508 * value.r - 0.1005789 * value.g + 1.1187297 * value.b);
      return vec3(
        filmNegativeLinearToSrgb(displayLinear.r),
        filmNegativeLinearToSrgb(displayLinear.g),
        filmNegativeLinearToSrgb(displayLinear.b));
    }

    bool protectedColorInGamut(vec3 value, float ceiling) {
      return min(value.r, min(value.g, value.b)) >= 0.0
        && max(value.r, max(value.g, value.b)) <= ceiling;
    }

    vec3 protectedColor(
      vec3 rgb,
      float temperatureMired,
      float tint,
      float saturation,
      float vibrance
    ) {
      const vec3 luminanceWeights = vec3(0.2626983, 0.6780, 0.0593017);
      float luminance = dot(rgb, luminanceWeights);
      if (luminance <= 0.0) return rgb;

      vec3 neutral = vec3(luminance);
      vec3 chroma = rgb - neutral;
      float mx = max(rgb.r, max(rgb.g, rgb.b));
      float mn = min(rgb.r, min(rgb.g, rgb.b));
      float saturationMetric = clamp((mx - mn) / max(abs(mx), 1e-9), 0.0, 1.0);
      float gamutProtection = 1.0 - 0.75 * smoothstep(0.75, 1.0, saturationMetric);
      float highlightProtection = 1.0 - 0.85 * smoothstep(0.75, 1.5, luminance);

      float saturationFactor = pow(2.0, clamp(saturation, -1.0, 1.0));
      float protectedSaturation = 1.0
        + (saturationFactor - 1.0) * gamutProtection * highlightProtection;
      float boundedVibrance = clamp(vibrance, -1.0, 1.0);
      float vibranceFactor;
      if (boundedVibrance >= 0.0) {
        float selectivity = (1.0 - saturationMetric) * (1.0 - saturationMetric);
        vibranceFactor = 1.0 + boundedVibrance * selectivity
          * gamutProtection * highlightProtection;
      } else {
        vibranceFactor = 1.0 + boundedVibrance * highlightProtection;
      }
      chroma *= max(protectedSaturation * vibranceFactor, 0.0);

      float temperature = clamp(temperatureMired / 100.0, -1.0, 1.0);
      float boundedTint = clamp(tint, -1.0, 1.0);
      float shift = 0.08 * luminance * highlightProtection;
      float temperatureGreen = -(0.2626983 - 0.0593017) / 0.6780;
      float tintGreen = -(0.2626983 + 0.0593017) / 0.6780;
      chroma += vec3(temperature, temperature * temperatureGreen, -temperature) * shift;
      chroma += vec3(boundedTint, boundedTint * tintGreen, boundedTint) * shift;

      vec3 desired = neutral + chroma;
      float ceiling = max(1.0, luminance * 1.5);
      if (protectedColorInGamut(desired, ceiling)) return desired;

      float lower = 0.0;
      float upper = 1.0;
      for (int iteration = 0; iteration < 24; iteration++) {
        float amount = (lower + upper) * 0.5;
        if (protectedColorInGamut(neutral + chroma * amount, ceiling)) {
          lower = amount;
        } else {
          upper = amount;
        }
      }
      return neutral + chroma * lower;
    }

    float highlightMask(float lum) {
      if (lum <= 0.3) return 0.0;
      if (lum >= 0.7) return 1.0;
      float t = (lum - 0.3) / 0.4;
      return t * t * (3.0 - 2.0 * t);
    }

    float midtoneMask(float lum) {
      float centered = abs(lum - 0.5);
      if (centered >= 0.5) return 0.0;
      float t = 1.0 - centered * 2.0;
      return t * t * (3.0 - 2.0 * t);
    }

    float shadowMask(float lum) {
      if (lum <= 0.3) return 1.0;
      if (lum >= 0.7) return 0.0;
      float t = (0.7 - lum) / 0.4;
      return t * t * (3.0 - 2.0 * t);
    }

    vec3 wheelGain(vec3 rgb, vec3 push, float mask) {
      if (mask <= 0.0 || (push.r == 0.0 && push.g == 0.0 && push.b == 0.0)) {
        return rgb;
      }
      vec3 gain = vec3(1.0) + push * mask;
      return rgb * gain;
    }

    vec3 wheelPush(float hue, float strength) {
      if (strength <= 0.0) return vec3(0.0);
      vec3 full = hsvToRgb(vec3(hue / 360.0, 1.0, 1.0)) * 2.0 - 1.0;
      return full * strength * 0.3;
    }

    const float linearTonePivot = 0.18;
    const float linearToneMinGain = 0.0005;

    vec3 linearToneAdjustments(
      vec3 rgb,
      float exposureEV,
      float brightness,
      float contrast,
      float highlights,
      float shadows
    ) {
      float exposureGain = pow(2.0, exposureEV);
      float brightnessOffset = brightness * 0.18;
      float contrastGamma = pow(2.0, contrast);

      rgb *= exposureGain;
      rgb += vec3(brightnessOffset);

      if (abs(contrast) > 0.0) {
        float luminance = dot(rgb, vec3(0.2626983, 0.6780, 0.0593017));
        if (luminance > 0.0) {
          float normalized = luminance / linearTonePivot;
          float adjustedLuminance = pow(
            clamp(normalized, 1e-12, 1e12), contrastGamma) * linearTonePivot;
          float scale = adjustedLuminance / luminance;
          rgb *= scale;
        }
      }

      if (abs(highlights) > 0.0 || abs(shadows) > 0.0) {
        float luminance = dot(rgb, vec3(0.2626983, 0.6780, 0.0593017));

        if (abs(highlights) > 0.0) {
          float highlightWeight = smoothstep(0.5, 2.0, luminance);
          float highlightGain = max(
            1.0 - highlights * 0.8 * highlightWeight, linearToneMinGain);
          rgb *= highlightGain;
        }

        if (abs(shadows) > 0.0) {
          float shadowWeight = 1.0 - smoothstep(0.0, 0.5, luminance);
          float shadowGain = max(
            1.0 + shadows * 0.8 * shadowWeight, linearToneMinGain);
          rgb *= shadowGain;
        }
      }

      return rgb;
    }

    kernel vec4 correction(
      sampler image,
      sampler lutImage,
      float filmType,
      float temperature,
      float tint,
      float gamma,
      float shadows,
      float highlights,
      float saturation,
      float photoExposureEV,
      float photoBrightness,
      float photoContrast,
      float photoHighlights,
      float photoShadows,
      float photoTemperatureMired,
      float photoTint,
      float photoSaturation,
      float photoVibrance,
      float highlightHue,
      float highlightStrength,
      float midtoneHue,
      float midtoneStrength,
      float shadowHue,
      float shadowStrength,
      float filmNegativeEnabled,
      float fnRExp,
      float fnGExp,
      float fnBExp,
      float fnRMult,
      float fnGMult,
      float fnBMult
    ) {
      vec4 pixel = sample(image, samplerCoord(image));
      vec3 rgb = pixel.rgb;
      bool sensorBlack = max(rgb.r, max(rgb.g, rgb.b))
        <= 256.0 / 65535.0;
      bool isBW = (filmType == 0.0);
      bool useProtectedColor = filmNegativeEnabled == 1.0 && !isBW
        && (photoTemperatureMired != 0.0 || photoTint != 0.0
          || photoSaturation != 0.0 || photoVibrance != 0.0);
      bool useLinearTone = abs(photoExposureEV) > 0.0
        || abs(photoBrightness) > 0.0 || abs(photoContrast) > 0.0
        || abs(photoHighlights) > 0.0 || abs(photoShadows) > 0.0;

      if (filmNegativeEnabled == 1.0) {
        vec3 filmLinear = filmNegativeLinearValue(
          rgb, vec3(fnRExp, fnGExp, fnBExp), vec3(fnRMult, fnGMult, fnBMult));
        if (useLinearTone) {
          filmLinear = linearToneAdjustments(
            filmLinear, photoExposureEV, photoBrightness, photoContrast,
            photoHighlights, photoShadows);
        }
        if (useProtectedColor) {
          filmLinear = protectedColor(
            filmLinear, photoTemperatureMired, photoTint, photoSaturation, photoVibrance);
        }
        rgb = filmNegativeDisplayFromLinear(filmLinear);
        if (isBW) {
          float gray = dot(rgb, vec3(0.299, 0.587, 0.114));
          rgb = vec3(gray);
        }
      } else {
        if (isBW) {
          float gray = dot(rgb, vec3(0.299, 0.587, 0.114));
          rgb = vec3(1.0 - gray);
        } else if (filmType == 1.0) {
          rgb = 1.0 - rgb;
        }
        if (useLinearTone) {
          vec3 linear = displayLinearValue(rgb);
          linear = linearToneAdjustments(
            linear, photoExposureEV, photoBrightness, photoContrast,
            photoHighlights, photoShadows);
          rgb = displayFromLinear(linear);
        }
      }

      if (!isBW && !useProtectedColor) {
        rgb *= vec3(
          1.0 + temperature / 200.0 + tint / 400.0,
          1.0 - tint / 200.0,
          1.0 - temperature / 200.0 + tint / 400.0
        );
      }

      if (!useLinearTone && (gamma != 0.0 || shadows != 0.0 || highlights != 0.0)) {
        rgb = clamp(rgb, 0.0, 1.0);
        if (gamma != 0.0) {
          rgb = pow(rgb, vec3(pow(2.0, -gamma / 100.0)));
        }
        if (shadows != 0.0) {
          float coefficient = 4.15e-5 * shadows * shadows + 0.02185 * shadows;
          vec3 delta = min(rgb - 0.75, 0.0);
          rgb += coefficient * delta * delta * rgb;
        }
        if (highlights != 0.0) {
          float coefficient =
            -4.15e-5 * highlights * highlights + 0.02185 * highlights;
          vec3 delta = max(rgb - 0.25, 0.0);
          rgb += coefficient * delta * delta * (1.0 - rgb);
        }
      }

      if (!isBW) {
        float idxR = clamp(rgb.r * 65535.0, 0.0, 65535.0);
        float idxG = clamp(rgb.g * 65535.0, 0.0, 65535.0);
        float idxB = clamp(rgb.b * 65535.0, 0.0, 65535.0);
        float outR = sample(lutImage, vec2(mod(idxR, 256.0) + 0.5, floor(idxR / 256.0) + 0.5)).r;
        float outG = sample(lutImage, vec2(mod(idxG, 256.0) + 0.5, floor(idxG / 256.0) + 0.5)).g;
        float outB = sample(lutImage, vec2(mod(idxB, 256.0) + 0.5, floor(idxB / 256.0) + 0.5)).b;
        rgb = vec3(outR, outG, outB);
      }

      if (!isBW && (highlightStrength > 0.0 || midtoneStrength > 0.0 || shadowStrength > 0.0)) {
        float lum = dot(rgb, vec3(0.299, 0.587, 0.114));
        vec3 hp = wheelPush(highlightHue, highlightStrength);
        vec3 mp = wheelPush(midtoneHue, midtoneStrength);
        vec3 sp = wheelPush(shadowHue, shadowStrength);
        rgb = wheelGain(rgb, hp, highlightMask(lum));
        rgb = wheelGain(rgb, mp, midtoneMask(lum));
        rgb = wheelGain(rgb, sp, shadowMask(lum));
        float newLum = dot(rgb, vec3(0.299, 0.587, 0.114));
        if (newLum > 0.0) {
          rgb *= lum / newLum;
        }
      }

      if (!isBW && !useProtectedColor && saturation != 100.0) {
        vec3 hsv = rgbToHsv(clamp(rgb, 0.0, 1.0));
        hsv.y = clamp(hsv.y * saturation / 100.0, 0.0, 1.0);
        rgb = hsvToRgb(hsv);
      }
      if (filmNegativeEnabled == 1.0 && sensorBlack) {
        rgb = vec3(0.0);
      }
      return vec4(clamp(rgb, 0.0, 1.0), pixel.a);
    }
    """
}

private struct CurveLUTKey: Hashable {
  let curveEnabled: Bool
  let curveControlPoints: [CurvePoint]
  let redCurveEnabled: Bool
  let redCurveControlPoints: [CurvePoint]
  let greenCurveEnabled: Bool
  let greenCurveControlPoints: [CurvePoint]
  let blueCurveEnabled: Bool
  let blueCurveControlPoints: [CurvePoint]

  init(parameters: ProcessingParameters) {
    curveEnabled = parameters.curveEnabled
    curveControlPoints = parameters.curveControlPoints
    redCurveEnabled = parameters.redCurveEnabled
    redCurveControlPoints = parameters.redCurveControlPoints
    greenCurveEnabled = parameters.greenCurveEnabled
    greenCurveControlPoints = parameters.greenCurveControlPoints
    blueCurveEnabled = parameters.blueCurveEnabled
    blueCurveControlPoints = parameters.blueCurveControlPoints
  }
}
