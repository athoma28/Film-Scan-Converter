import CoreImage
import FilmScanEngine
import Foundation
import Metal

public final class SceneDisplayRenderer: @unchecked Sendable {
  private static let maximumFiniteKernelValue = sqrt(Float.greatestFiniteMagnitude)

  nonisolated(unsafe) private static let sharedKernel = CIKernel(source: kernelSource)
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

  private let source: CIImage
  private let width: Int
  private let height: Int

  public init?(sceneLinear: [Double], width: Int, height: Int) {
    guard
      width > 0,
      height > 0,
      sceneLinear.count == width * height * 3,
      Self.sharedKernel != nil
    else {
      return nil
    }

    var rgba = [Float](repeating: 1, count: width * height * 4)
    for pixelIndex in 0..<(width * height) {
      let bgrBase = pixelIndex * 3
      let rgbaBase = pixelIndex * 4
      rgba[rgbaBase] = Self.finiteKernelValue(sceneLinear[bgrBase + 2])
      rgba[rgbaBase + 1] = Self.finiteKernelValue(sceneLinear[bgrBase + 1])
      rgba[rgbaBase + 2] = Self.finiteKernelValue(sceneLinear[bgrBase])
    }

    let data = rgba.withUnsafeBytes { Data($0) }
    source = CIImage(
      bitmapData: data,
      bytesPerRow: width * 4 * MemoryLayout<Float>.size,
      size: CGSize(width: width, height: height),
      format: .RGBAf,
      colorSpace: nil
    )
    self.width = width
    self.height = height
  }

  public func render(parameters: DisplayRenderingParameters) -> [Double]? {
    guard let kernel = Self.sharedKernel else { return nil }

    let exposureGain = exp2(parameters.exposureEV)
    let blueGain = Self.finiteKernelGain(
      min(exposureGain * parameters.whiteBalance.blue, parameters.maximumSceneGain)
    )
    let greenGain = Self.finiteKernelGain(
      min(exposureGain * parameters.whiteBalance.green, parameters.maximumSceneGain)
    )
    let redGain = Self.finiteKernelGain(
      min(exposureGain * parameters.whiteBalance.red, parameters.maximumSceneGain)
    )

    guard
      let output = kernel.apply(
        extent: source.extent,
        roiCallback: { _, destinationRect in destinationRect },
        arguments: [
          source,
          redGain,
          greenGain,
          blueGain,
          Float(parameters.toneMap == .reinhard ? 1 : 0),
        ]
      )
    else {
      return nil
    }

    var rgba = [Float](repeating: 0, count: width * height * 4)
    rgba.withUnsafeMutableBytes { buffer in
      guard let address = buffer.baseAddress else { return }
      Self.sharedContext.render(
        output,
        toBitmap: address,
        rowBytes: width * 4 * MemoryLayout<Float>.size,
        bounds: output.extent,
        format: .RGBAf,
        colorSpace: nil
      )
    }

    var bgr = [Double](repeating: 0, count: width * height * 3)
    for pixelIndex in 0..<(width * height) {
      let rgbaBase = pixelIndex * 4
      let bgrBase = pixelIndex * 3
      bgr[bgrBase] = Double(rgba[rgbaBase + 2])
      bgr[bgrBase + 1] = Double(rgba[rgbaBase + 1])
      bgr[bgrBase + 2] = Double(rgba[rgbaBase])
    }
    return bgr
  }

  private static func finiteKernelValue(_ value: Double) -> Float {
    guard !value.isNaN && value > 0 else { return 0 }
    return Float(min(value, Double(maximumFiniteKernelValue)))
  }

  private static func finiteKernelGain(_ value: Double) -> Float {
    Float(min(max(value, 0), Double(maximumFiniteKernelValue)))
  }

  private static let kernelSource = """
    kernel vec4 displayRender(
      sampler image,
      float redGain,
      float greenGain,
      float blueGain,
      float useReinhard
    ) {
      vec4 pixel = sample(image, samplerCoord(image));
      vec3 rgb = max(pixel.rgb, vec3(0.0));
      rgb *= vec3(redGain, greenGain, blueGain);
      if (useReinhard == 1.0) {
        rgb = rgb / (vec3(1.0) + rgb);
      }
      return vec4(clamp(rgb, 0.0, 1.0), 1.0);
    }
    """
}
