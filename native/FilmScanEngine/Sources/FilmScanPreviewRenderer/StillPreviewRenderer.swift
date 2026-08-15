import CoreGraphics
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
  private static let outputColorSpace = CGColorSpace(
    name: CGColorSpace.sRGB
  )!
  nonisolated(unsafe) private static let sharedContext: CIContext = {
    let options: [CIContextOption: Any] = [
      .cacheIntermediates: false,
      .workingColorSpace: NSNull(),
      .outputColorSpace: NSNull(),
    ]
    let devices = MTLCopyAllDevices()
    let device =
      devices.first(where: { !$0.isLowPower })
      ?? devices.first
      ?? MTLCreateSystemDefaultDevice()
    if let device {
      return CIContext(mtlDevice: device, options: options)
    }
    return CIContext(options: [.useSoftwareRenderer: false] as [CIContextOption: Any])
  }()

  public static func warmUp() {
    _ = sharedKernel
    _ = sharedContext
  }

  public init?(image: UInt16Image) {
    guard
      let rgba = image.rgba16Data(),
      let kernel = Self.sharedKernel
    else {
      return nil
    }

    source = CIImage(
      bitmapData: rgba,
      bytesPerRow: image.width * 4 * MemoryLayout<UInt16>.stride,
      size: CGSize(width: image.width, height: image.height),
      format: .RGBA16,
      colorSpace: nil
    )
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
      let dyeMixing = parameters.filmDyeMixing.clamped()
      let usesCalibratedMonochrome =
        parameters.filmType == .blackAndWhiteNegative
        && fnp.rendering == .calibratedMonochrome
      let usesCalibratedColor =
        parameters.filmType == .colourNegative
        && fnp.rendering == .calibratedColor
      let fnEnabled =
        parameters.filmNegativeParams.enabled
        && (parameters.filmType == .colourNegative || parameters.filmType == .blackAndWhiteNegative)
        && (usesCalibratedMonochrome || usesCalibratedColor || fnp.measuredMedians != nil)
      let renderingMode: Float =
        switch fnp.rendering {
        case .powerLaw: 0
        case .calibratedMonochrome: 1
        case .calibratedColor: 2
        }
      let calibratedColorProfile: Float =
        switch fnp.calibratedColorProfile {
        case .generic: 0
        case .fuji400Fresh: 1
        case .fuji200Expired: 2
        case .cinestill800T: 3
        case .harmanPhoenixII: 4
        }
      let calibratedMonochromeProfile: Float =
        switch fnp.calibratedMonochromeProfile {
        case .generic: 0
        case .shanghaiGP3: 1
        }
      let (fnRExp, fnGExp, fnBExp): (Float, Float, Float)
      let (fnRMult, fnGMult, fnBMult): (Float, Float, Float)

      if fnEnabled {
        switch fnp.rendering {
        case .powerLaw:
          if let medians = fnp.measuredMedians {
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
            fnRExp = 0
            fnGExp = 0
            fnBExp = 0
            fnRMult = 1
            fnGMult = 1
            fnBMult = 1
          }
        case .calibratedColor:
          let gains = FilmNegativeProcessing.calibratedColorInputGains(
            measuredMedians: fnp.measuredMedians,
            profile: fnp.calibratedColorProfile
          )
          fnRExp = 0
          fnGExp = 0
          fnBExp = 0
          fnRMult = Float(gains.red)
          fnGMult = Float(gains.green)
          fnBMult = Float(gains.blue)
        case .calibratedMonochrome:
          let gain = Float(
            FilmNegativeProcessing.calibratedMonochromeInputGain(
              measuredMedians: fnp.measuredMedians,
              profile: fnp.calibratedMonochromeProfile
            )
          )
          fnRExp = 0
          fnGExp = 0
          fnBExp = 0
          fnRMult = gain
          fnGMult = gain
          fnBMult = gain
        }
      } else {
        fnRExp = 0
        fnGExp = 0
        fnBExp = 0
        fnRMult = 1
        fnGMult = 1
        fnBMult = 1
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
            Float(
              fnEnabled && fnp.rendering == .powerLaw
                ? FilmNegativeProcessing.calibrationTargetFraction
                : 0.18
            ),
            Float(parameters.photoAdjustments.temperatureShiftMired),
            Float(parameters.photoAdjustments.tint),
            Float(parameters.photoAdjustments.saturation),
            Float(parameters.photoAdjustments.vibrance),
            Float(dyeMixing.redFromGreen),
            Float(dyeMixing.redFromBlue),
            Float(dyeMixing.greenFromRed),
            Float(dyeMixing.greenFromBlue),
            Float(dyeMixing.blueFromRed),
            Float(dyeMixing.blueFromGreen),
            Float(parameters.highlightWheel.hue),
            Float(parameters.highlightWheel.strength),
            Float(parameters.midtoneWheel.hue),
            Float(parameters.midtoneWheel.strength),
            Float(parameters.shadowWheel.hue),
            Float(parameters.shadowWheel.strength),
            Float(fnEnabled ? 1 : 0),
            renderingMode,
            calibratedColorProfile,
            calibratedMonochromeProfile,
            Float(fnp.monochromeExposureEV),
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
      colorSpace: Self.outputColorSpace
    )
  }

  /// Computes bounded clipping and tone statistics from the displayed image.
  /// The analysis proxy is capped so interactive rendering does not retain a
  /// second full-size pixel buffer.
  public static func statistics(
    for image: CGImage,
    maximumDimension: Int = 256
  ) -> RenderReadyImageStatistics? {
    guard maximumDimension > 0, image.width > 0, image.height > 0 else { return nil }
    let scale = min(
      1,
      Double(maximumDimension) / Double(max(image.width, image.height))
    )
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let context = CGContext(
        data: &rgba,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.noneSkipLast.rawValue
      )
    else {
      return nil
    }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var bgr = [Double](repeating: 0, count: width * height * 3)
    for pixelIndex in 0..<(width * height) {
      let source = pixelIndex * 4
      let destination = pixelIndex * 3
      bgr[destination] = Double(rgba[source + 2]) / 255
      bgr[destination + 1] = Double(rgba[source + 1]) / 255
      bgr[destination + 2] = Double(rgba[source]) / 255
    }
    return RenderReadyLinearImage(width: width, height: height, pixels: bgr).statistics()
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
    let hasAnyCurve =
      parameters.curveEnabled || parameters.redCurveEnabled
      || parameters.greenCurveEnabled || parameters.blueCurveEnabled
    let overallLUT =
      parameters.curveEnabled
      ? FilmProcessing.buildCurveLUT(controlPoints: parameters.curveControlPoints) : nil
    let redLUT =
      parameters.redCurveEnabled
      ? FilmProcessing.buildCurveLUT(controlPoints: parameters.redCurveControlPoints) : nil
    let greenLUT =
      parameters.greenCurveEnabled
      ? FilmProcessing.buildCurveLUT(controlPoints: parameters.greenCurveControlPoints) : nil
    let blueLUT =
      parameters.blueCurveEnabled
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

    // This is numeric lookup data, not an sRGB picture. Going through a
    // color-managed CGImage can silently reshape the curve before sampling.
    return CIImage(
      bitmapData: Data(pixels),
      bytesPerRow: width * 4,
      size: CGSize(width: width, height: height),
      format: .RGBA8,
      colorSpace: nil
    )
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

    float calibratedMonochromeKnot(float profile, float knot) {
      if (profile < 0.5) {
        if (knot < 0.5) return 0.989069;
        if (knot < 1.5) return 0.912663;
        if (knot < 2.5) return 0.668040;
        if (knot < 3.5) return 0.603132;
        if (knot < 4.5) return 0.488223;
        if (knot < 5.5) return 0.330530;
        if (knot < 6.5) return 0.157710;
        if (knot < 7.5) return 0.105823;
        if (knot < 8.5) return 0.105823;
        if (knot < 9.5) return 0.105823;
        return 0.067593;
      }
      if (knot < 0.5) return 0.988401;
      if (knot < 1.5) return 0.919551;
      if (knot < 2.5) return 0.788751;
      if (knot < 3.5) return 0.676859;
      if (knot < 4.5) return 0.517770;
      if (knot < 5.5) return 0.355288;
      if (knot < 6.5) return 0.199164;
      if (knot < 7.5) return 0.140077;
      if (knot < 8.5) return 0.132008;
      if (knot < 9.5) return 0.092534;
      return 0.067556;
    }

    float calibratedMonochromeCurve(
      float value, float inputGain, float negativeExposureEV, float profile
    ) {
      float exposed = clamp(
        value * inputGain * pow(2.0, negativeExposureEV), 0.0, 1.0);
      float position = exposed * 10.0;
      float lower = min(floor(position), 9.0);
      return mix(
        calibratedMonochromeKnot(profile, lower),
        calibratedMonochromeKnot(profile, lower + 1.0),
        position - lower);
    }

    vec3 calibratedColorKnot(float profile, float knot) {
      if (profile < 0.5) {
        if (knot < 0.5) return vec3(0.988782, 0.981603, 0.985590);
        if (knot < 1.5) return vec3(0.906913, 0.862303, 0.928206);
        if (knot < 2.5) return vec3(0.741342, 0.575805, 0.733601);
        if (knot < 3.5) return vec3(0.529294, 0.393775, 0.590298);
        if (knot < 4.5) return vec3(0.377395, 0.241577, 0.308451);
        if (knot < 5.5) return vec3(0.246425, 0.190320, 0.273508);
        if (knot < 6.5) return vec3(0.174431, 0.091074, 0.231637);
        if (knot < 7.5) return vec3(0.096998, 0.043509, 0.057239);
        if (knot < 8.5) return vec3(0.063358, 0.037671, 0.057239);
        if (knot < 9.5) return vec3(0.025520, 0.029825, 0.057239);
        return vec3(0.025520, 0.025845, 0.057239);
      }
      if (profile < 1.5) {
        if (knot < 0.5) return vec3(0.988695, 0.982016, 0.984934);
        if (knot < 1.5) return vec3(0.899821, 0.868660, 0.932758);
        if (knot < 2.5) return vec3(0.757199, 0.595692, 0.768483);
        if (knot < 3.5) return vec3(0.506845, 0.381230, 0.549015);
        if (knot < 4.5) return vec3(0.313549, 0.234961, 0.313488);
        if (knot < 5.5) return vec3(0.253077, 0.213014, 0.255865);
        if (knot < 6.5) return vec3(0.167284, 0.114352, 0.255865);
        if (knot < 7.5) return vec3(0.110408, 0.041374, 0.134999);
        if (knot < 8.5) return vec3(0.041514, 0.028878, 0.061323);
        if (knot < 9.5) return vec3(0.029620, 0.028878, 0.052189);
        return vec3(0.018251, 0.019974, 0.042113);
      }
      if (profile < 2.5) {
        if (knot < 0.5) return vec3(0.992840, 0.989718, 0.992886);
        if (knot < 1.5) return vec3(0.964433, 0.929469, 0.959548);
        if (knot < 2.5) return vec3(0.772915, 0.776278, 0.809359);
        if (knot < 3.5) return vec3(0.772915, 0.717912, 0.807061);
        if (knot < 4.5) return vec3(0.650805, 0.584919, 0.745133);
        if (knot < 5.5) return vec3(0.581862, 0.377581, 0.609145);
        if (knot < 6.5) return vec3(0.445023, 0.216584, 0.401956);
        if (knot < 7.5) return vec3(0.300384, 0.172346, 0.256013);
        if (knot < 8.5) return vec3(0.122844, 0.075729, 0.208724);
        if (knot < 9.5) return vec3(0.087376, 0.060105, 0.094601);
        return vec3(0.049887, 0.030462, 0.037899);
      }
      if (profile < 3.5) {
        if (knot < 0.5) return vec3(0.889071, 0.976831, 0.983561);
        if (knot < 1.5) return vec3(0.800569, 0.778123, 0.873425);
        if (knot < 2.5) return vec3(0.675436, 0.466709, 0.583469);
        if (knot < 3.5) return vec3(0.619374, 0.292708, 0.399432);
        if (knot < 4.5) return vec3(0.417016, 0.192789, 0.242909);
        if (knot < 5.5) return vec3(0.216966, 0.150298, 0.242909);
        if (knot < 6.5) return vec3(0.117165, 0.150298, 0.242909);
        if (knot < 7.5) return vec3(0.117165, 0.150298, 0.185946);
        if (knot < 8.5) return vec3(0.117165, 0.068440, 0.094080);
        if (knot < 9.5) return vec3(0.078848, 0.053849, 0.094080);
        return vec3(0.078848, 0.053849, 0.094080);
      }
      if (knot < 0.5) return vec3(0.952454, 0.974144, 0.972354);
      if (knot < 1.5) return vec3(0.754535, 0.846462, 0.909126);
      if (knot < 2.5) return vec3(0.458264, 0.543931, 0.688301);
      if (knot < 3.5) return vec3(0.317229, 0.524965, 0.688301);
      if (knot < 4.5) return vec3(0.161046, 0.296099, 0.551931);
      if (knot < 5.5) return vec3(0.108709, 0.140592, 0.326745);
      if (knot < 6.5) return vec3(0.056521, 0.090988, 0.144854);
      if (knot < 7.5) return vec3(0.037348, 0.087881, 0.095234);
      if (knot < 8.5) return vec3(0.021589, 0.013066, 0.095234);
      if (knot < 9.5) return vec3(0.017122, 0.011410, 0.092993);
      return vec3(0.012818, 0.010492, 0.071834);
    }

    float calibratedColorChannel(
      float value, float inputGain, float channel, float negativeExposureEV,
      float profile
    ) {
      float exposed = clamp(
        value * inputGain * pow(2.0, negativeExposureEV), 0.0, 1.0);
      float position = exposed * 10.0;
      float lower = min(floor(position), 9.0);
      vec3 result = mix(
        calibratedColorKnot(profile, lower),
        calibratedColorKnot(profile, lower + 1.0),
        position - lower);
      return channel == 0.0 ? result.r : (channel == 1.0 ? result.g : result.b);
    }

    vec3 calibratedColorCurve(
      vec3 value, vec3 inputGain, float negativeExposureEV, float profile
    ) {
      return vec3(
        calibratedColorChannel(
          value.r, inputGain.r, 0.0, negativeExposureEV, profile),
        calibratedColorChannel(
          value.g, inputGain.g, 1.0, negativeExposureEV, profile),
        calibratedColorChannel(
          value.b, inputGain.b, 2.0, negativeExposureEV, profile));
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

    vec3 filmDyeMixing(
      vec3 rgb,
      float redFromGreen,
      float redFromBlue,
      float greenFromRed,
      float greenFromBlue,
      float blueFromRed,
      float blueFromGreen
    ) {
      return vec3(
        rgb.r + redFromGreen * (rgb.g - rgb.r) + redFromBlue * (rgb.b - rgb.r),
        rgb.g + greenFromRed * (rgb.r - rgb.g) + greenFromBlue * (rgb.b - rgb.g),
        rgb.b + blueFromRed * (rgb.r - rgb.b) + blueFromGreen * (rgb.g - rgb.b));
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

      vec3 lowerBounds = vec3(1.0);
      if (chroma.r < 0.0) lowerBounds.r = luminance / -chroma.r;
      else if (chroma.r > 0.0) lowerBounds.r = (ceiling - luminance) / chroma.r;
      if (chroma.g < 0.0) lowerBounds.g = luminance / -chroma.g;
      else if (chroma.g > 0.0) lowerBounds.g = (ceiling - luminance) / chroma.g;
      if (chroma.b < 0.0) lowerBounds.b = luminance / -chroma.b;
      else if (chroma.b > 0.0) lowerBounds.b = (ceiling - luminance) / chroma.b;
      float amount = clamp(min(lowerBounds.r, min(lowerBounds.g, lowerBounds.b)), 0.0, 1.0);
      return neutral + chroma * amount;
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

    const float linearToneMinGain = 0.0005;

    vec3 linearToneAdjustments(
      vec3 rgb,
      float exposureEV,
      float brightness,
      float contrast,
      float highlights,
      float shadows,
      float referenceLuminance
    ) {
      float linearTonePivot = clamp(referenceLuminance, 1e-6, 16.0);
      float exposureGain = pow(2.0, exposureEV);
      float brightnessOffset = brightness * linearTonePivot;
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
          float highlightWeight = smoothstep(
            linearTonePivot * 2.0, linearTonePivot * 6.0, luminance);
          float highlightGain = max(
            1.0 - highlights * 0.8 * highlightWeight, linearToneMinGain);
          rgb *= highlightGain;
        }

        if (abs(shadows) > 0.0) {
          float shadowWeight = 1.0 - smoothstep(
            0.0, linearTonePivot * 2.0, luminance);
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
      float photoToneReference,
      float photoTemperatureMired,
      float photoTint,
      float photoSaturation,
      float photoVibrance,
      float dyeRedFromGreen,
      float dyeRedFromBlue,
      float dyeGreenFromRed,
      float dyeGreenFromBlue,
      float dyeBlueFromRed,
      float dyeBlueFromGreen,
      float highlightHue,
      float highlightStrength,
      float midtoneHue,
      float midtoneStrength,
      float shadowHue,
      float shadowStrength,
      float filmNegativeEnabled,
      float filmNegativeRendering,
      float calibratedColorProfile,
      float calibratedMonochromeProfile,
      float monochromeExposureEV,
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
        <= 1024.0 / 65535.0;
      bool isBW = (filmType == 0.0);
      bool isNegative = isBW || filmType == 1.0;
      bool useProtectedColor = filmNegativeEnabled == 1.0 && !isBW
        && (photoTemperatureMired != 0.0 || photoTint != 0.0
          || photoSaturation != 0.0 || photoVibrance != 0.0);
      bool useDyeMixing = filmType == 1.0
        && (dyeRedFromGreen != 0.0 || dyeRedFromBlue != 0.0
          || dyeGreenFromRed != 0.0 || dyeGreenFromBlue != 0.0
          || dyeBlueFromRed != 0.0 || dyeBlueFromGreen != 0.0);
      bool useLinearTone = abs(photoExposureEV) > 0.0
        || abs(photoBrightness) > 0.0 || abs(photoContrast) > 0.0
        || abs(photoHighlights) > 0.0 || abs(photoShadows) > 0.0;

      bool useCalibratedMonochrome = isBW && filmNegativeRendering == 1.0;
      bool useCalibratedColor = !isBW && filmType == 1.0
        && filmNegativeRendering == 2.0;
      if (filmNegativeEnabled == 1.0 && useCalibratedMonochrome) {
        float gray = dot(rgb, vec3(0.299, 0.587, 0.114));
        rgb = vec3(
          calibratedMonochromeCurve(
            gray, fnGMult, monochromeExposureEV, calibratedMonochromeProfile));
        if (useLinearTone) {
          vec3 linear = displayLinearValue(rgb);
          linear = linearToneAdjustments(
            linear, photoExposureEV, photoBrightness, photoContrast,
            photoHighlights, photoShadows, photoToneReference);
          rgb = displayFromLinear(linear);
        }
      } else if (filmNegativeEnabled == 1.0 && useCalibratedColor) {
        rgb = calibratedColorCurve(
          rgb, vec3(fnRMult, fnGMult, fnBMult), monochromeExposureEV,
          calibratedColorProfile);
        if (useDyeMixing || useLinearTone || useProtectedColor) {
          vec3 linear = displayLinearValue(rgb);
          if (useDyeMixing) {
            linear = filmDyeMixing(
              linear,
              dyeRedFromGreen, dyeRedFromBlue,
              dyeGreenFromRed, dyeGreenFromBlue,
              dyeBlueFromRed, dyeBlueFromGreen);
          }
          if (useLinearTone) {
            linear = linearToneAdjustments(
              linear, photoExposureEV, photoBrightness, photoContrast,
              photoHighlights, photoShadows, photoToneReference);
          }
          if (useProtectedColor) {
            linear = protectedColor(
              linear, photoTemperatureMired, photoTint, photoSaturation, photoVibrance);
          }
          rgb = displayFromLinear(linear);
        }
      } else if (filmNegativeEnabled == 1.0) {
        vec3 filmLinear = filmNegativeLinearValue(
          rgb, vec3(fnRExp, fnGExp, fnBExp), vec3(fnRMult, fnGMult, fnBMult));
        if (useDyeMixing) {
          filmLinear = filmDyeMixing(
            filmLinear,
            dyeRedFromGreen, dyeRedFromBlue,
            dyeGreenFromRed, dyeGreenFromBlue,
            dyeBlueFromRed, dyeBlueFromGreen);
        }
        if (useLinearTone) {
          filmLinear = linearToneAdjustments(
            filmLinear, photoExposureEV, photoBrightness, photoContrast,
            photoHighlights, photoShadows, photoToneReference);
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
        if (useDyeMixing || useLinearTone) {
          vec3 linear = displayLinearValue(rgb);
          if (useDyeMixing) {
            linear = filmDyeMixing(
              linear,
              dyeRedFromGreen, dyeRedFromBlue,
              dyeGreenFromRed, dyeGreenFromBlue,
              dyeBlueFromRed, dyeBlueFromGreen);
          }
          if (useLinearTone) {
            linear = linearToneAdjustments(
              linear, photoExposureEV, photoBrightness, photoContrast,
              photoHighlights, photoShadows, photoToneReference);
          }
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
      if (isNegative && sensorBlack) {
        rgb = vec3(1.0);
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
