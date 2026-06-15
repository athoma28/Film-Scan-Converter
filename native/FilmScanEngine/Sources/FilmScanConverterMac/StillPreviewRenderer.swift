import CoreImage
import FilmScanEngine
import Metal

final class StillPreviewRenderer: @unchecked Sendable {
  private let context: CIContext
  private let source: CIImage
  private let correctionKernel: CIColorKernel

  init?(image: UInt16Image) {
    guard
      let cgImage = image.makePreviewCGImage16(),
      let kernel = CIColorKernel(source: Self.correctionKernelSource)
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

  func render(parameters: ProcessingParameters, showOriginal: Bool) -> CGImage? {
    let oriented = orientedSource(parameters: parameters)
    let output: CIImage

    if showOriginal || parameters.filmType == .cropOnly {
      output = oriented
    } else {
      guard
        let corrected = correctionKernel.apply(
          extent: oriented.extent,
          arguments: [
            oriented,
            Float(parameters.filmType.rawValue),
            Float(parameters.temperature),
            Float(parameters.tint),
            Float(parameters.gamma),
            Float(parameters.shadows),
            Float(parameters.highlights),
            Float(parameters.saturation),
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

    kernel vec4 correction(
      __sample pixel,
      float filmType,
      float temperature,
      float tint,
      float gamma,
      float shadows,
      float highlights,
      float saturation
    ) {
      vec3 rgb = pixel.rgb;
      if (filmType == 0.0) {
        float gray = dot(rgb, vec3(0.299, 0.587, 0.114));
        rgb = vec3(1.0 - gray);
      } else if (filmType == 1.0) {
        rgb = 1.0 - rgb;
      }

      rgb *= vec3(
        1.0 + temperature / 200.0 + tint / 400.0,
        1.0 - tint / 200.0,
        1.0 - temperature / 200.0 + tint / 400.0
      );

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

      if (saturation != 100.0) {
        vec3 hsv = rgbToHsv(max(rgb, 0.0));
        hsv.y = clamp(hsv.y * saturation / 100.0, 0.0, 1.0);
        rgb = hsvToRgb(hsv);
      }
      return vec4(clamp(rgb, 0.0, 1.0), pixel.a);
    }
    """
}
