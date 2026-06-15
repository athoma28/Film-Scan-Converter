import CoreImage
import FilmScanEngine
import Metal

public final class StillPreviewRenderer: @unchecked Sendable {
  private let context: CIContext
  private let source: CIImage
  private let correctionKernel: CIKernel
  private let curveLUTLock = NSLock()
  private var curveLUTCache: [CurveLUTKey: CIImage] = [:]

  public init?(image: UInt16Image) {
    guard
      let cgImage = image.makePreviewCGImage16(),
      let kernel = CIKernel(source: Self.correctionKernelSource)
    else {
      return nil
    }

    if let device = MTLCreateSystemDefaultDevice() {
      context = CIContext(
        mtlDevice: device,
        options: [
          .cacheIntermediates: false,
          .workingColorSpace: NSNull(),
          .outputColorSpace: NSNull(),
        ]
      )
    } else {
      context = CIContext(
        options: [
          .useSoftwareRenderer: false,
          .cacheIntermediates: false,
          .workingColorSpace: NSNull(),
          .outputColorSpace: NSNull(),
        ]
      )
    }
    source = CIImage(cgImage: cgImage)
    correctionKernel = kernel
  }

  public func render(parameters: ProcessingParameters, showOriginal: Bool) -> CGImage? {
    let oriented = orientedSource(parameters: parameters)
    let output: CIImage

    if showOriginal || parameters.filmType == .cropOnly {
      output = oriented
    } else {
      let lutImage = curveLUTImage(parameters: parameters)
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
            Float(parameters.highlightWheel.hue),
            Float(parameters.highlightWheel.strength),
            Float(parameters.midtoneWheel.hue),
            Float(parameters.midtoneWheel.strength),
            Float(parameters.shadowWheel.hue),
            Float(parameters.shadowWheel.strength),
          ]
        )
      else {
        return nil
      }
      output = corrected
    }

    return context.createCGImage(
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
      float highlightHue,
      float highlightStrength,
      float midtoneHue,
      float midtoneStrength,
      float shadowHue,
      float shadowStrength
    ) {
      vec4 pixel = sample(image, samplerCoord(image));
      vec3 rgb = pixel.rgb;
      bool isBW = (filmType == 0.0);

      if (isBW) {
        float gray = dot(rgb, vec3(0.299, 0.587, 0.114));
        rgb = vec3(1.0 - gray);
      } else if (filmType == 1.0) {
        rgb = 1.0 - rgb;
      }

      if (!isBW) {
        rgb *= vec3(
          1.0 + temperature / 200.0 + tint / 400.0,
          1.0 - tint / 200.0,
          1.0 - temperature / 200.0 + tint / 400.0
        );
      }

      if (gamma != 0.0 || shadows != 0.0 || highlights != 0.0) {
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

      if (!isBW && saturation != 100.0) {
        vec3 hsv = rgbToHsv(clamp(rgb, 0.0, 1.0));
        hsv.y = clamp(hsv.y * saturation / 100.0, 0.0, 1.0);
        rgb = hsvToRgb(hsv);
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
