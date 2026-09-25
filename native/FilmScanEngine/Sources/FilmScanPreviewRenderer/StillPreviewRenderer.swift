import CoreGraphics
import CoreImage
import FilmScanEngine
import Metal

public final class StillPreviewRenderer: @unchecked Sendable {
  private let source: CIImage
  /// RGBA16 bitmap retained by the Core Image source, in addition to the
  /// caller's UInt16 source and analysis arrays. Excludes transient GPU/output
  /// allocations, which Core Image manages separately.
  public let retainedRGBAByteCount: Int
  private let densityAnalysisCache = DensityPrintAnalysisCache()
  private let curveLUTLock = NSLock()
  private var curveLUTCache: [CurveLUTKey: CIImage] = [:]

  nonisolated(unsafe) private static let sharedKernel: CIKernel? = {
    CIKernel(source: correctionKernelSource)
  }()
  private static let outputColorSpace = CGColorSpace(
    name: CGColorSpace.sRGB
  )!
  // Metal device/resource creation and CIContext rendering support concurrent
  // callers. Every render below owns a separate destination buffer.
  nonisolated(unsafe) private static let sharedDevice: MTLDevice? = {
    let devices = MTLCopyAllDevices()
    return devices.first(where: { !$0.isLowPower })
      ?? devices.first ?? MTLCreateSystemDefaultDevice()
  }()
  nonisolated(unsafe) private static let sharedContext: CIContext = {
    let options: [CIContextOption: Any] = [
      .cacheIntermediates: false,
      .workingFormat: CIFormat.RGBAf,
      .workingColorSpace: NSNull(),
      .outputColorSpace: NSNull(),
    ]
    if let device = sharedDevice {
      return CIContext(mtlDevice: device, options: options)
    }
    return CIContext(options: [.useSoftwareRenderer: false] as [CIContextOption: Any])
  }()

  public static func warmUp() {
    _ = sharedKernel
    _ = sharedContext
  }

  public init?(image: UInt16Image, analysisImage: UInt16Image? = nil) {
    guard
      let rgba = image.rgba16Data(),
      let kernel = Self.sharedKernel
    else {
      return nil
    }

    self.analysisImage = analysisImage ?? image
    retainedRGBAByteCount = rgba.count
    source = CIImage(
      bitmapData: rgba,
      bytesPerRow: image.width * 4 * MemoryLayout<UInt16>.stride,
      size: CGSize(width: image.width, height: image.height),
      format: .RGBA16,
      colorSpace: nil
    )
    correctionKernel = kernel
  }

  private let analysisImage: UInt16Image
  private let correctionKernel: CIKernel

  /// The per-pixel graph supports quarter turns, flipping, and manual crops.
  /// Version 1 density edits retain cropped analysis and their CPU route.
  /// Version 2 shares immutable sensor-frame analysis across CPU/GPU/proxies.
  /// Cropped Original/crop-only views retain exact CPU UInt16-to-UInt8 packing.
  public static func supports(parameters: ProcessingParameters, showOriginal: Bool) -> Bool {
    guard !parameters.densityPipelineEnabled,
      parameters.cropRect == nil,
      parameters.perspectiveCrop == nil,
      abs(parameters.straightenAngle) < 0.000_001
    else { return false }
    if parameters.manualCrop != nil && (showOriginal || parameters.filmType == .cropOnly) {
      return false
    }
    if parameters.manualCrop != nil,
      parameters.filmNegativeParams.enabled,
      parameters.filmNegativeParams.rendering == .powerLaw,
      parameters.filmNegativeParams.measuredMedians == nil,
      parameters.filmType == .colourNegative || parameters.filmType == .blackAndWhiteNegative
    {
      // The CPU computes missing medians from the cropped source. The GPU
      // power-law branch requires medians already resolved by the model.
      return false
    }
    let croppedDensityPrint =
      parameters.manualCrop != nil
      && parameters.filmType == .colourNegative
      && parameters.filmNegativeParams.enabled
      && parameters.filmNegativeParams.rendering == .densityPrint
    return !croppedDensityPrint || parameters.photoAdjustments.usesPhotographicTone
  }

  /// Adds source-dependent precision checks to the geometry-only static gate.
  /// Density normalization divides a Float log/floor difference by the measured
  /// range. Below 0.001 log units, cancellation can amplify a sub-micro-unit
  /// error by more than 1,000 before print contrast and grading. Such flat scans
  /// use the existing Double CPU path; cached analysis makes this check reusable.
  /// The first check can perform bounded image analysis. Call it on a rendering
  /// worker, not from UI event handling on the main actor.
  public func supports(parameters: ProcessingParameters, showOriginal: Bool) -> Bool {
    guard Self.supports(parameters: parameters, showOriginal: showOriginal) else { return false }
    let negative = parameters.filmNegativeParams
    guard !showOriginal,
      parameters.filmType == .colourNegative,
      negative.enabled,
      negative.rendering == .densityPrint
    else { return true }
    let analysis = densityPrintAnalysis(parameters: parameters)
    let spans = [
      analysis.ceils.blue - analysis.floors.blue,
      analysis.ceils.green - analysis.floors.green,
      analysis.ceils.red - analysis.floors.red,
    ]
    return spans.allSatisfy { $0.isFinite && abs($0) >= 0.001 }
  }

  /// Correction precedes resampling. Regions use normalized, top-left image
  /// coordinates; Core Image propagates the crop/scale's sampling halo upstream.
  public func render(
    parameters: ProcessingParameters, showOriginal: Bool,
    maximumDimension: Int? = nil, normalizedRegion: CGRect? = nil
  ) -> CGImage? {
    guard var output = correctedGraph(parameters: parameters, showOriginal: showOriginal) else {
      return nil
    }
    if let region = normalizedRegion {
      guard !region.isNull, !region.isInfinite, region.width > 0, region.height > 0 else {
        return nil
      }
      let rect = Self.regionBounds(region, in: output.extent)
      guard !rect.isEmpty else { return nil }
      output = output.cropped(to: rect)
    }
    if let maximumDimension {
      guard maximumDimension > 0 else { return nil }
      let scale = min(1, CGFloat(maximumDimension) / max(output.extent.width, output.extent.height))
      if scale < 1 {
        output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      }
    }
    if maximumDimension == nil, normalizedRegion == nil,
      output.extent.width * output.extent.height >= 4_194_304,
      let materialized = Self.sharedBitmap(output)
    {
      // Avoid Core Image's tiled GPU-to-bitmap readback for complete large
      // rasters. Small previews and bounded viewport requests keep their path.
      return materialized
    }
    return Self.sharedContext.createCGImage(
      output, from: output.extent, format: .RGBA8, colorSpace: Self.outputColorSpace,
      deferred: false)
  }

  /// Synchronously renders a complete opaque raster into its final storage on
  /// unified-memory devices. The caller excludes scaling and viewport resampling.
  /// No precision/processing change and no retained intermediate image.
  /// Internal so small geometry/lifetime fixtures can exercise the same writer.
  static func sharedBitmap(_ image: CIImage) -> CGImage? {
    guard let device = sharedDevice, device.hasUnifiedMemory else { return nil }
    let bounds = image.extent
    // Keep the single-texture path bounded; other extents use Core Image's
    // existing tiling, scaling and allocation-failure handling.
    guard !bounds.isEmpty, !bounds.isInfinite, !bounds.isNull,
      bounds == bounds.integral, bounds.width <= 16_384, bounds.height <= 16_384
    else { return nil }
    let width = Int(bounds.width)
    let height = Int(bounds.height)
    let alignment = device.minimumLinearTextureAlignment(for: .rgba8Unorm)
    guard alignment > 0 else { return nil }
    let rowBytes = ((width * 4 + alignment - 1) / alignment) * alignment
    guard rowBytes * height <= device.maxBufferLength,
      let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared)
    else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead, .shaderWrite]
    guard let texture = buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: rowBytes)
    else { return nil }
    let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
    destination.colorSpace = outputColorSpace
    destination.isFlipped = true
    destination.alphaMode = .premultiplied
    do {
      let task = try sharedContext.startTask(
        toRender: image, from: bounds, to: destination, at: .zero)
      // Publishing earlier would expose GPU writes to AppKit/statistics readers.
      _ = try task.waitUntilCompleted()
    } catch { return nil }
    // The provider owns the buffer until the last image/bitmap representation
    // releases it. It is never reused by a later render, including concurrent
    // requests. bytesPerRow also carries the padded payload into app accounting.
    let owner = Unmanaged.passRetained(buffer as AnyObject)
    guard
      let provider = CGDataProvider(
        dataInfo: owner.toOpaque(), data: buffer.contents(), size: buffer.length,
        releaseData: { info, _, _ in
          if let info { Unmanaged<AnyObject>.fromOpaque(info).release() }
        })
    else {
      owner.release()
      return nil
    }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: rowBytes, space: outputColorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }

  static func regionBounds(_ region: CGRect, in extent: CGRect) -> CGRect {
    // Normalizing an integer source coordinate and multiplying it back can
    // produce 63.99999999999999. Snap numerical noise before outward rounding
    // so a native-pixel viewport does not gain a pixel and stretch its raster.
    func snap(_ value: CGFloat) -> CGFloat {
      let integer = value.rounded()
      return abs(value - integer) < 1e-7 ? integer : value
    }
    let left = snap(extent.minX + region.minX * extent.width)
    let right = snap(extent.minX + region.maxX * extent.width)
    let bottom = snap(extent.maxY - region.maxY * extent.height)
    let top = snap(extent.maxY - region.minY * extent.height)
    return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
      .integral.intersection(extent)
  }

  private func correctedGraph(parameters: ProcessingParameters, showOriginal: Bool) -> CIImage? {
    guard supports(parameters: parameters, showOriginal: showOriginal) else { return nil }
    let oriented = croppedSource(parameters: parameters)
    let output: CIImage

    if showOriginal || parameters.filmType == .cropOnly {
      output = oriented
    } else {
      let lutImage = curveLUTImage(parameters: parameters)

      var fnp = parameters.filmNegativeParams
      if parameters.photoAdjustments.usesPhotographicTone, fnp.enabled, fnp.measuredMedians == nil {
        fnp.measuredMedians = FilmNegativeProcessing.computeMedians(
          image: analysisImage.resizedToFit(maxDimension: 256))
      }
      let dyeMixing = parameters.filmDyeMixing.clamped()
      let usesCalibratedMonochrome =
        parameters.filmType == .blackAndWhiteNegative
        && fnp.rendering == .calibratedMonochrome
      let usesCalibratedColor =
        parameters.filmType == .colourNegative
        && fnp.rendering == .calibratedColor
      let usesDensityPrint =
        parameters.filmType == .colourNegative
        && fnp.rendering == .densityPrint
      let fnEnabled =
        parameters.filmNegativeParams.enabled
        && (parameters.filmType == .colourNegative || parameters.filmType == .blackAndWhiteNegative)
        && (usesCalibratedMonochrome || usesCalibratedColor || usesDensityPrint
          || fnp.measuredMedians != nil)
      let renderingMode: Float =
        switch fnp.rendering {
        case .powerLaw: 0
        case .calibratedMonochrome: 1
        case .calibratedColor: 2
        case .densityPrint: 3
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
        case .densityPrint:
          fnRExp = 0
          fnGExp = 0
          fnBExp = 0
          fnRMult = 1
          fnGMult = 1
          fnBMult = 1
        }
      } else {
        fnRExp = 0
        fnGExp = 0
        fnBExp = 0
        fnRMult = 1
        fnGMult = 1
        fnBMult = 1
      }

      let densityAnalysis =
        usesDensityPrint && fnEnabled
        ? densityPrintAnalysis(parameters: parameters)
        : nil
      let dp = densityAnalysis
      func densityFloat(_ value: Double) -> Float { Float(value) }

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
            Float(parameters.photoAdjustments.schemaVersion),
            Float(parameters.photoAdjustments.whites),
            Float(parameters.photoAdjustments.blacks),
            Float(parameters.photoAdjustments.shadowFloor),
            Float(parameters.photoAdjustments.midtoneLevel),
            Float(parameters.photoAdjustments.highlightCeiling),
            Float(
              fnEnabled && fnp.rendering == .powerLaw
                ? FilmNegativeProcessing.calibrationTargetFraction
                : 0.18
            ),
            Float(parameters.photoAdjustments.temperatureShiftMired),
            Float(parameters.photoAdjustments.tint),
            Float(parameters.photoAdjustments.saturation),
            Float(parameters.photoAdjustments.vibrance),
            Float(parameters.photoAdjustments.warmHueRecovery ?? 0),
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
            densityFloat(dp?.unmixBlue.blue ?? 1),
            densityFloat(dp?.unmixBlue.green ?? 0),
            densityFloat(dp?.unmixBlue.red ?? 0),
            densityFloat(dp?.unmixGreen.blue ?? 0),
            densityFloat(dp?.unmixGreen.green ?? 1),
            densityFloat(dp?.unmixGreen.red ?? 0),
            densityFloat(dp?.unmixRed.blue ?? 0),
            densityFloat(dp?.unmixRed.green ?? 0),
            densityFloat(dp?.unmixRed.red ?? 1),
            densityFloat(dp?.floors.blue ?? 0),
            densityFloat(dp?.floors.green ?? 0),
            densityFloat(dp?.floors.red ?? 0),
            densityFloat(dp?.ceils.blue ?? 1),
            densityFloat(dp?.ceils.green ?? 1),
            densityFloat(dp?.ceils.red ?? 1),
            densityFloat(dp?.slopes.blue ?? 2.9),
            densityFloat(dp?.slopes.green ?? 2.9),
            densityFloat(dp?.slopes.red ?? 2.9),
            densityFloat(dp?.pivots.blue ?? 0.2),
            densityFloat(dp?.pivots.green ?? 0.2),
            densityFloat(dp?.pivots.red ?? 0.2),
            densityFloat(dp?.curvatures.blue ?? 0),
            densityFloat(dp?.curvatures.green ?? 0),
            densityFloat(dp?.curvatures.red ?? 0),
            densityFloat(dp?.paperDMin.blue ?? 0),
            densityFloat(dp?.paperDMin.green ?? 0),
            densityFloat(dp?.paperDMin.red ?? 0),
            densityFloat(dp?.paperDMax ?? 2.3),
            densityFloat(dp?.paperMidtoneGamma ?? 0.15),
            densityFloat(dp?.paperGammaWidth ?? 0.6),
            densityFloat(dp?.toeSharpnessBase ?? 4.0),
            densityFloat(dp?.shoulderSharpnessBase ?? 3.0),
            densityFloat(dp?.toeHeight ?? 0.90),
            densityFloat(dp?.shoulderHeight ?? 0.35),
            densityFloat(dp?.referenceLinear ?? 0.75),
            densityFloat(dp?.dyeMixBlue.blue ?? 1),
            densityFloat(dp?.dyeMixBlue.green ?? 0),
            densityFloat(dp?.dyeMixBlue.red ?? 0),
            densityFloat(dp?.dyeMixGreen.blue ?? 0),
            densityFloat(dp?.dyeMixGreen.green ?? 1),
            densityFloat(dp?.dyeMixGreen.red ?? 0),
            densityFloat(dp?.dyeMixRed.blue ?? 0),
            densityFloat(dp?.dyeMixRed.green ?? 0),
            densityFloat(dp?.dyeMixRed.red ?? 1),
          ]
        )
      else {
        return nil
      }
      output = corrected
    }

    return output
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

  private func densityPrintAnalysis(parameters: ProcessingParameters) -> DensityPrintAnalysis {
    let profile = DensityPrintProcessing.resolvedProfile(from: parameters.filmNegativeParams)
    let paper = DensityPrintProcessing.resolvedPaper(for: parameters)
    return densityAnalysisCache.analysis(
      profile: profile, paper: paper,
      version: parameters.photoAdjustments.schemaVersion
    ) {
      DensityPrintProcessing.analyze(
        image: parameters.photoAdjustments.usesPhotographicTone
          ? analysisImage.resizedToFit(maxDimension: 256) : analysisImage, profile: profile,
        paper: paper)
    }
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

  private func croppedSource(parameters: ProcessingParameters) -> CIImage {
    let oriented = orientedSource(parameters: parameters)
    guard let crop = parameters.manualCrop,
      let bounds = ImageGeometry.pixelBounds(
        for: crop,
        imageWidth: Int(oriented.extent.width),
        imageHeight: Int(oriented.extent.height))
    else { return oriented }
    let rect = CGRect(
      x: oriented.extent.minX + CGFloat(bounds.x),
      y: oriented.extent.maxY - CGFloat(bounds.y + bounds.height),
      width: CGFloat(bounds.width),
      height: CGFloat(bounds.height))
    return oriented.cropped(to: rect).transformed(
      by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
  }

  static func makeCurveLUTImage(parameters: ProcessingParameters) -> CIImage {
    let hasAnyCurve =
      parameters.curveEnabled || parameters.redCurveEnabled
      || parameters.greenCurveEnabled || parameters.blueCurveEnabled
    let overallLUT =
      parameters.curveEnabled
      ? FilmProcessing.buildCurveLUT(controlPoints: parameters.curveControlPoints) : nil
    let redLUT =
      parameters.filmType.supportsColorCorrections && parameters.redCurveEnabled
      ? FilmProcessing.buildCurveLUT(controlPoints: parameters.redCurveControlPoints) : nil
    let greenLUT =
      parameters.filmType.supportsColorCorrections && parameters.greenCurveEnabled
      ? FilmProcessing.buildCurveLUT(controlPoints: parameters.greenCurveControlPoints) : nil
    let blueLUT =
      parameters.filmType.supportsColorCorrections && parameters.blueCurveEnabled
      ? FilmProcessing.buildCurveLUT(controlPoints: parameters.blueCurveControlPoints) : nil

    let width = 256
    let height = 256
    var pixels = [UInt16](repeating: 0, count: width * height * 4)

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

        pixels[offset] = rOut
        pixels[offset + 1] = gOut
        pixels[offset + 2] = bOut
        pixels[offset + 3] = 65_535
      }
    }

    // This is numeric lookup data, not an sRGB picture. Going through a
    // color-managed CGImage can silently reshape the curve before sampling.
    let modern = parameters.photoAdjustments.usesPhotographicTone
    let data = modern ? pixels.withUnsafeBytes { Data($0) } : Data(pixels.map { UInt8($0 >> 8) })
    return CIImage(
      bitmapData: data,
      bytesPerRow: width * 4 * (modern ? 2 : 1),
      size: CGSize(width: width, height: height),
      format: modern ? .RGBA16 : .RGBA8,
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

    vec3 recoverWarmHue(vec3 rgb, float amount, float tolerance) {
      if (amount <= 0.0) return rgb;
      vec3 linear = vec3(
        1.6604910 * rgb.r - 0.5876411 * rgb.g - 0.0728499 * rgb.b,
        -0.1245505 * rgb.r + 1.1328999 * rgb.g - 0.0083494 * rgb.b,
        -0.0181508 * rgb.r - 0.1005789 * rgb.g + 1.1187297 * rgb.b);
      if (min(linear.r, min(linear.g, linear.b)) < -tolerance
        || max(linear.r, max(linear.g, linear.b)) > 1.0 + tolerance) return rgb;
      vec3 display = displayFromLinear(rgb);
      float mx = max(display.r, max(display.g, display.b));
      float mn = min(display.r, min(display.g, display.b));
      float delta = mx - mn;
      if (delta <= 1e-8 || mx <= 1e-8) return rgb;
      float hue;
      if (mx == display.r) hue = 60.0 * (display.g - display.b) / delta;
      else if (mx == display.g) hue = 60.0 * (2.0 + (display.b - display.r) / delta);
      else hue = 60.0 * (4.0 + (display.r - display.g) / delta);
      float saturation = delta / mx;
      float weight = clamp(amount, 0.0, 1.0) * smoothstep(18.0, 34.0, hue)
        * (1.0 - smoothstep(70.0, 160.0, hue)) * smoothstep(0.28, 0.58, saturation)
        * (1.0 - smoothstep(0.7, 1.0, max(linear.r, max(linear.g, linear.b))));
      if (weight <= 0.0) return rgb;
      float shiftedHue = (hue + 60.0 * weight) / 60.0;
      float chroma = mx * saturation * (1.0 - 0.25 * weight);
      float x = chroma * (1.0 - abs(mod(shiftedHue, 2.0) - 1.0));
      vec3 shifted;
      if (shiftedHue < 1.0) shifted = vec3(chroma, x, 0.0);
      else if (shiftedHue < 2.0) shifted = vec3(x, chroma, 0.0);
      else shifted = vec3(0.0, chroma, x);
      vec3 recovered = displayLinearValue(shifted + vec3(mx - chroma));
      const vec3 weights = vec3(0.2626983, 0.6780, 0.0593017);
      return recovered * (dot(rgb, weights) / max(dot(recovered, weights), 1e-9));
    }

    vec3 protectedColor(
      vec3 rgb,
      float temperatureMired,
      float tint,
      float saturation,
      float vibrance,
      float warmHueRecovery,
      float recoveryTolerance
    ) {
      rgb = recoverWarmHue(rgb, warmHueRecovery, recoveryTolerance);
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
      float shift = \(ProtectedColorAdjustment.opponentShiftScale) * luminance * highlightProtection;
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

    float photoEncode(float x) {
      return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
    }
    float photoDecode(float x) {
      return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
    }
    vec3 photoTo2020(vec3 x) {
      return vec3(dot(x, vec3(0.6274039, 0.3292830, 0.0433131)),
        dot(x, vec3(0.0690973, 0.9195404, 0.0113623)),
        dot(x, vec3(0.0163914, 0.0880133, 0.8955953)));
    }
    vec3 photoDisplay(vec3 x) {
      vec3 linear = vec3(dot(x, vec3(1.6604910, -0.5876411, -0.0728499)),
        dot(x, vec3(-0.1245505, 1.1328999, -0.0083494)),
        dot(x, vec3(-0.0181508, -0.1005789, 1.1187297)));
      return vec3(photoEncode(linear.r), photoEncode(linear.g), photoEncode(linear.b));
    }
    float photoBend(float x, float amount) {
      float w = x * (1.0 - x);
      return x + amount * w * w;
    }
    float photoShoulder(float x) {
      if (x <= 0.98) return x;
      float d = x - 0.98;
      return 0.98 + 0.02 * d / (d + 0.02);
    }
    float photoFocusedBend(float t, float amount, bool highlights) {
      float gain = pow(2.0, 2.0 * amount * (highlights ? t : 1.0 - t));
      return t * gain / (1.0 - t + t * gain);
    }
    float photoTailBend(float t, float amount, bool highlights) {
      float gain = pow(2.0, 3.0 * amount * (highlights ? t : 1.0 - t));
      return t * gain / (1.0 - t + t * gain);
    }
    float photoVersionFourRanges(float x, float highlights, float shadows,
      float whites, float blacks) {
      if (shadows != 0.0 && x < 0.72) {
        x = 0.72 * photoBend(x / 0.72, 4.0 * clamp(shadows, -1.0, 1.0));
      }
      if (highlights != 0.0 && x > 0.28 && x < 1.0) {
        x = 0.28 + 0.72 * photoBend((x - 0.28) / 0.72,
          4.0 * clamp(highlights, -1.0, 1.0));
      }
      if (blacks != 0.0 && x < 0.28) {
        x = 0.28 * photoFocusedBend(x / 0.28, clamp(blacks, -1.0, 1.0), false);
      }
      if (whites != 0.0 && x > 0.5 && x < 1.0) {
        x = 0.5 + 0.5 * photoTailBend((x - 0.5) / 0.5,
          clamp(whites, -1.0, 1.0), true);
      }
      return x;
    }
    float photoVersionFourLevels(float x, float shadowFloor, float midtoneLevel,
      float highlightCeiling) {
      if (midtoneLevel != 0.0 && x > 0.18 && x < 0.82) {
        x = 0.18 + 0.64 * photoBend((x - 0.18) / 0.64,
          4.0 * clamp(midtoneLevel, -1.0, 1.0));
      }
      float floorAmount = clamp(shadowFloor, -1.0, 1.0);
      float ceilingAmount = clamp(highlightCeiling, -1.0, 1.0);
      float black = floorAmount >= 0.0 ? 0.12 * floorAmount : 0.08 * floorAmount;
      float white = ceilingAmount >= 0.0
        ? 1.0 + 0.10 * ceilingAmount : 1.0 + 0.16 * ceilingAmount;
      return black + (white - black) * x;
    }
    vec3 photoTone(vec3 rgb, float exposure, float brightness, float contrast,
      float highlights, float shadows, float whites, float blacks,
      float shadowFloor, float midtoneLevel, float highlightCeiling, float version) {
      float y = dot(rgb, vec3(0.2626983, 0.678, 0.0593017));
      float gain = pow(2.0, clamp(exposure, -4.0, 4.0));
      float positive = max(y, 0.0);
      float exposed = positive * gain / (1.0 + positive * max(gain - 1.0, 0.0));
      float x = photoEncode(exposed);
      if (x < 1.0) x = photoBend(x, 4.0 * clamp(brightness, -1.0, 1.0));
      if (contrast != 0.0 && x > 0.0 && x < 1.0) {
        float pivot = photoEncode(0.18);
        float power = pow(2.0, clamp(contrast, -1.0, 1.0) * 0.8);
        if (x < pivot) x = pivot * pow(x / pivot, power);
        else x = 1.0 - (1.0 - pivot) * pow((1.0 - x) / (1.0 - pivot), power);
      }
      bool hasVersionFourControl = highlights != 0.0 || shadows != 0.0
        || whites != 0.0 || blacks != 0.0 || shadowFloor != 0.0
        || midtoneLevel != 0.0 || highlightCeiling != 0.0;
      if (version >= 4.0 && hasVersionFourControl) {
        x = photoVersionFourRanges(x, highlights, shadows, whites, blacks);
        x = photoEncode(photoShoulder(photoDecode(x)));
        x = photoVersionFourLevels(x, shadowFloor, midtoneLevel, highlightCeiling);
      } else {
        if (x < 0.65) {
          float amount = clamp(shadows, -1.0, 1.0);
          x = 0.65 * (version >= 3.0 && amount != 0.0
            ? photoFocusedBend(x / 0.65, amount, false)
            : photoBend(x / 0.65, 4.0 * amount));
        }
        if (x > 0.4 && x < 1.0) {
          float amount = clamp(highlights, -1.0, 1.0);
          x = 0.4 + 0.6 * (version >= 3.0 && amount != 0.0
            ? photoFocusedBend((x - 0.4) / 0.6, amount, true)
            : photoBend((x - 0.4) / 0.6, 4.0 * amount));
        }
        x = photoEncode(photoShoulder(photoDecode(x)));
        float black = clamp(blacks, -1.0, 1.0) * 0.12;
        x = (x + black) / (1.0 + black);
        x *= pow(2.0, clamp(whites, -1.0, 1.0) * 0.5);
      }
      float target = photoDecode(x);
      return y > 1e-12 ? rgb * (target / y) : vec3(target);
    }
    vec3 photoGamut(vec3 rgb) {
      float y = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
      if (y <= 0.0 || y >= 1.0) return vec3(y);
      vec3 d = rgb - vec3(y);
      vec3 distance = max(d / (1.0 - y), -d / y);
      float extent = max(distance.r, max(distance.g, distance.b));
      if (extent <= 0.8) return rgb;
      float extra = extent - 0.8;
      return vec3(y) + d * ((0.8 + 0.2 * extra / (extra + 0.2)) / extent);
    }
    float photoMonoKnot(float profile, float knot) {
      return 0.997 * calibratedMonochromeKnot(profile, knot) + 0.003 * (1.0 - knot / 10.0);
    }
    float photoMonochrome(float value, float gain, float ev, float profile) {
      float x = max(value * gain * pow(2.0, ev), 0.0);
      if (x > 1.0) {
        float end = photoMonoKnot(profile, 10.0);
        float rate = max(10.0 * (photoMonoKnot(profile, 9.0) - end) / max(end, 1e-9), 0.01);
        return end * exp(-rate * (x - 1.0));
      }
      float position = x * 10.0;
      float lower = min(floor(position), 9.0);
      return mix(photoMonoKnot(profile, lower), photoMonoKnot(profile, lower + 1.0), position - lower);
    }
    vec3 photoColorKnot(float profile, float knot) {
      return 0.997 * calibratedColorKnot(profile, knot) + vec3(0.003 * (1.0 - knot / 10.0));
    }
    float photoColor(float value, float gain, float ev, float profile, float channel) {
      float x = max(value * gain * pow(2.0, ev), 0.0);
      vec3 result;
      if (x > 1.0) {
        vec3 end = photoColorKnot(profile, 10.0);
        vec3 rate = max(10.0 * (photoColorKnot(profile, 9.0) - end) / max(end, vec3(1e-9)), vec3(0.01));
        result = end * exp(-rate * (x - 1.0));
      } else {
        float position = x * 10.0;
        float lower = min(floor(position), 9.0);
        result = mix(photoColorKnot(profile, lower), photoColorKnot(profile, lower + 1.0), position - lower);
      }
      return channel == 0.0 ? result.r : (channel == 1.0 ? result.g : result.b);
    }
    vec3 photoCurve(sampler table, vec3 rgb) {
      vec3 position = rgb * 65535.0;
      vec3 lower = clamp(floor(position), 0.0, 65534.0);
      vec3 upper = lower + vec3(1.0);
      if (rgb.r < 0.0) { lower.r = 0.0; upper.r = 256.0; }
      if (rgb.g < 0.0) { lower.g = 0.0; upper.g = 256.0; }
      if (rgb.b < 0.0) { lower.b = 0.0; upper.b = 256.0; }
      if (rgb.r > 1.0) { lower.r = 65279.0; upper.r = 65535.0; }
      if (rgb.g > 1.0) { lower.g = 65279.0; upper.g = 65535.0; }
      if (rgb.b > 1.0) { lower.b = 65279.0; upper.b = 65535.0; }
      vec3 a = vec3(sample(table, vec2(mod(lower.r, 256.0) + 0.5, floor(lower.r / 256.0) + 0.5)).r,
        sample(table, vec2(mod(lower.g, 256.0) + 0.5, floor(lower.g / 256.0) + 0.5)).g,
        sample(table, vec2(mod(lower.b, 256.0) + 0.5, floor(lower.b / 256.0) + 0.5)).b);
      vec3 b = vec3(sample(table, vec2(mod(upper.r, 256.0) + 0.5, floor(upper.r / 256.0) + 0.5)).r,
        sample(table, vec2(mod(upper.g, 256.0) + 0.5, floor(upper.g / 256.0) + 0.5)).g,
        sample(table, vec2(mod(upper.b, 256.0) + 0.5, floor(upper.b / 256.0) + 0.5)).b);
      return a + (b - a) * ((position - lower) / (upper - lower));
    }

    const float linearToneMinGain = 0.0005;

    vec3 linearToneAdjustments(
      vec3 rgb,
      float exposureEV,
      float brightness,
      float contrast,
      float highlights,
      float shadows,
      float referenceLuminance,
      float version,
      float whites,
      float blacks,
      float shadowFloor,
      float midtoneLevel,
      float highlightCeiling
    ) {
      if (version >= 2.0) return photoTone(rgb, exposureEV, brightness, contrast,
        highlights, shadows, whites, blacks, shadowFloor, midtoneLevel, highlightCeiling, version);
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

    float densityLog10(float x) {
      return log(max(x, 1e-6)) / log(10.0);
    }

    float densitySoftplus(float x) {
      if (x > 20.0) return x;
      if (x < -20.0) return exp(x);
      return log(1.0 + exp(x));
    }

    float densityTanh(float x) {
      float e2 = exp(clamp(2.0 * x, -40.0, 40.0));
      return (e2 - 1.0) / (e2 + 1.0);
    }

    float densityNormalizeLog(float value, float floorV, float ceilV) {
      float delta = ceilV - floorV;
      if (abs(delta) < 1e-6) {
        delta = delta >= 0.0 ? 1e-6 : -1e-6;
      }
      return (value - floorV) / delta;
    }

    float densityPrintCurve(
      float x,
      float slope,
      float pivot,
      float curv,
      float dMin,
      float dMax,
      float midGamma,
      float gammaWidth,
      float toeSharp,
      float shSharp,
      float toeH,
      float shH,
      float vStar
    ) {
      float slopeMin = 2.0;
      float slopeMax = 10.0;
      float slopeNorm = clamp((slope - slopeMin) / (slopeMax - slopeMin), 0.0, 1.0);
      float toe = (0.15 * 0.35 / 0.90) * slopeNorm;
      float shoulder = 0.12 * slopeNorm;
      float ts = 0.85;
      float width = 2.5;
      float aHL = shSharp * width / max(width, 1e-6);
      float aSHBase = toeSharp * width / max(width, 1e-6);
      float dMinEff = max(0.0, dMin + shoulder * ts * shH);
      float toeEff = toe * ts;
      float dMaxEff = toeEff >= 0.0 ? dMax - toeEff * toeH : dMax;
      float aSH = toeEff >= 0.0 ? aSHBase : aSHBase * (1.0 - toeEff * 4.0);
      float dMaxBound = max(dMaxEff, dMinEff + 0.1);
      float v = slope * (x - pivot) + curv * x * x;
      v += midGamma * gammaWidth * densityTanh((v - vStar) / gammaWidth);
      float v1 = dMinEff + densitySoftplus(aHL * (v - dMinEff)) / aHL;
      return dMaxBound - densitySoftplus(aSH * (dMaxBound - v1)) / aSH;
    }

    float densityEncodeReflectance(float density, float dMax, float version) {
      float transmittance = pow(10.0, -density);
      float black = pow(10.0, -dMax);
      transmittance = (transmittance - black) / (1.0 - black);
      if (version >= 2.0) return transmittance;
      return filmNegativeLinearToSrgb(clamp(transmittance, 0.0, 1.0));
    }

    vec3 densityPrintInvert(
      vec3 rgb,
      vec3 umB,
      vec3 umG,
      vec3 umR,
      vec3 floors,
      vec3 ceils,
      vec3 slopes,
      vec3 pivots,
      vec3 curvs,
      vec3 dMin,
      vec3 dyeB,
      vec3 dyeG,
      vec3 dyeR,
      float dMax,
      float midGamma,
      float gammaWidth,
      float toeSharp,
      float shSharp,
      float toeH,
      float shH,
      float vStar,
      float version
    ) {
      float linR = max(filmNegativeSrgbToLinear(rgb.r), 1e-6);
      float linG = max(filmNegativeSrgbToLinear(rgb.g), 1e-6);
      float linB = max(filmNegativeSrgbToLinear(rgb.b), 1e-6);
      vec3 logs = vec3(densityLog10(linB), densityLog10(linG), densityLog10(linR));
      float uB = dot(umB, logs);
      float uG = dot(umG, logs);
      float uR = dot(umR, logs);
      float nB = densityNormalizeLog(uB, floors.x, ceils.x);
      float nG = densityNormalizeLog(uG, floors.y, ceils.y);
      float nR = densityNormalizeLog(uR, floors.z, ceils.z);
      float densB = densityPrintCurve(
        nB, slopes.x, pivots.x, curvs.x, dMin.x, dMax,
        midGamma, gammaWidth, toeSharp, shSharp, toeH, shH, vStar);
      float densG = densityPrintCurve(
        nG, slopes.y, pivots.y, curvs.y, dMin.y, dMax,
        midGamma, gammaWidth, toeSharp, shSharp, toeH, shH, vStar);
      float densR = densityPrintCurve(
        nR, slopes.z, pivots.z, curvs.z, dMin.z, dMax,
        midGamma, gammaWidth, toeSharp, shSharp, toeH, shH, vStar);
      vec3 excess = vec3(densB - dMin.x, densG - dMin.y, densR - dMin.z);
      densB = dMin.x + dot(dyeB, excess);
      densG = dMin.y + dot(dyeG, excess);
      densR = dMin.z + dot(dyeR, excess);
      return vec3(
        densityEncodeReflectance(densR, dMax, version),
        densityEncodeReflectance(densG, dMax, version),
        densityEncodeReflectance(densB, dMax, version)
      );
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
      float photoVersion,
      float photoWhites,
      float photoBlacks,
      float photoShadowFloor,
      float photoMidtoneLevel,
      float photoHighlightCeiling,
      float photoToneReference,
      float photoTemperatureMired,
      float photoTint,
      float photoSaturation,
      float photoVibrance,
      float photoWarmHueRecovery,
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
      float fnBMult,
      float dpUmBb,
      float dpUmBg,
      float dpUmBr,
      float dpUmGb,
      float dpUmGg,
      float dpUmGr,
      float dpUmRb,
      float dpUmRg,
      float dpUmRr,
      float dpFloorB,
      float dpFloorG,
      float dpFloorR,
      float dpCeilB,
      float dpCeilG,
      float dpCeilR,
      float dpSlopeB,
      float dpSlopeG,
      float dpSlopeR,
      float dpPivotB,
      float dpPivotG,
      float dpPivotR,
      float dpCurvB,
      float dpCurvG,
      float dpCurvR,
      float dpDMinB,
      float dpDMinG,
      float dpDMinR,
      float dpDMax,
      float dpMidGamma,
      float dpGammaWidth,
      float dpToeSharp,
      float dpShSharp,
      float dpToeH,
      float dpShH,
      float dpVStar,
      float dpDyeBb,
      float dpDyeBg,
      float dpDyeBr,
      float dpDyeGb,
      float dpDyeGg,
      float dpDyeGr,
      float dpDyeRb,
      float dpDyeRg,
      float dpDyeRr
    ) {
      vec4 pixel = sample(image, samplerCoord(image));
      vec3 rgb = pixel.rgb;
      bool sensorBlack = max(rgb.r, max(rgb.g, rgb.b))
        <= 1024.0 / 65535.0;
      bool isBW = (filmType == 0.0);
      bool isNegative = isBW || filmType == 1.0;
      bool modernTone = photoVersion >= 2.0;
      bool useProtectedColor = (modernTone || filmNegativeEnabled == 1.0) && !isBW
        && (photoTemperatureMired != 0.0 || photoTint != 0.0
          || photoSaturation != 0.0 || photoVibrance != 0.0 || photoWarmHueRecovery != 0.0);
      bool useDyeMixing = filmType == 1.0
        && (dyeRedFromGreen != 0.0 || dyeRedFromBlue != 0.0
          || dyeGreenFromRed != 0.0 || dyeGreenFromBlue != 0.0
          || dyeBlueFromRed != 0.0 || dyeBlueFromGreen != 0.0);
      bool useLinearTone = modernTone || abs(photoExposureEV) > 0.0
        || abs(photoBrightness) > 0.0 || abs(photoContrast) > 0.0
        || abs(photoHighlights) > 0.0 || abs(photoShadows) > 0.0;

      bool useCalibratedMonochrome = isBW && filmNegativeRendering == 1.0;
      bool useCalibratedColor = !isBW && filmType == 1.0
        && filmNegativeRendering == 2.0;
      bool useDensityPrint = !isBW && filmType == 1.0
        && filmNegativeRendering == 3.0;
      if (filmNegativeEnabled == 1.0 && useCalibratedMonochrome) {
        float gray = dot(rgb, vec3(0.299, 0.587, 0.114));
        rgb = vec3(modernTone
          ? photoMonochrome(gray, fnGMult, monochromeExposureEV, calibratedMonochromeProfile)
          : calibratedMonochromeCurve(gray, fnGMult, monochromeExposureEV, calibratedMonochromeProfile));
        if (useLinearTone) {
          vec3 linear = displayLinearValue(rgb);
          linear = linearToneAdjustments(
            linear, photoExposureEV, photoBrightness, photoContrast,
            photoHighlights, photoShadows, photoToneReference, photoVersion, photoWhites,
            photoBlacks, photoShadowFloor, photoMidtoneLevel, photoHighlightCeiling);
          rgb = modernTone ? photoDisplay(linear) : displayFromLinear(linear);
        }
      } else if (filmNegativeEnabled == 1.0 && useCalibratedColor) {
        if (modernTone) {
          rgb = vec3(photoColor(rgb.r, fnRMult, monochromeExposureEV, calibratedColorProfile, 0.0),
            photoColor(rgb.g, fnGMult, monochromeExposureEV, calibratedColorProfile, 1.0),
            photoColor(rgb.b, fnBMult, monochromeExposureEV, calibratedColorProfile, 2.0));
        } else {
          rgb = calibratedColorCurve(rgb, vec3(fnRMult, fnGMult, fnBMult),
            monochromeExposureEV, calibratedColorProfile);
        }
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
              photoHighlights, photoShadows, photoToneReference, photoVersion, photoWhites,
              photoBlacks, photoShadowFloor, photoMidtoneLevel, photoHighlightCeiling);
          }
          if (useProtectedColor) {
            linear = protectedColor(
              linear, photoTemperatureMired, photoTint, photoSaturation, photoVibrance, photoWarmHueRecovery, modernTone ? 1e-6 : 0.0);
          }
          rgb = modernTone ? photoDisplay(linear) : displayFromLinear(linear);
        }
      } else if (filmNegativeEnabled == 1.0 && useDensityPrint) {
        rgb = densityPrintInvert(
          rgb,
          vec3(dpUmBb, dpUmBg, dpUmBr),
          vec3(dpUmGb, dpUmGg, dpUmGr),
          vec3(dpUmRb, dpUmRg, dpUmRr),
          vec3(dpFloorB, dpFloorG, dpFloorR),
          vec3(dpCeilB, dpCeilG, dpCeilR),
          vec3(dpSlopeB, dpSlopeG, dpSlopeR),
          vec3(dpPivotB, dpPivotG, dpPivotR),
          vec3(dpCurvB, dpCurvG, dpCurvR),
          vec3(dpDMinB, dpDMinG, dpDMinR),
          vec3(dpDyeBb, dpDyeBg, dpDyeBr),
          vec3(dpDyeGb, dpDyeGg, dpDyeGr),
          vec3(dpDyeRb, dpDyeRg, dpDyeRr),
          dpDMax,
          dpMidGamma,
          dpGammaWidth,
          dpToeSharp,
          dpShSharp,
          dpToeH,
          dpShH,
          dpVStar,
          photoVersion
        );
        if (useDyeMixing || useLinearTone || useProtectedColor) {
          vec3 linear = modernTone ? photoTo2020(rgb) : displayLinearValue(rgb);
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
              photoHighlights, photoShadows, photoToneReference, photoVersion, photoWhites,
              photoBlacks, photoShadowFloor, photoMidtoneLevel, photoHighlightCeiling);
          }
          if (useProtectedColor) {
            linear = protectedColor(
              linear, photoTemperatureMired, photoTint, photoSaturation, photoVibrance, photoWarmHueRecovery, modernTone ? 1e-6 : 0.0);
          }
          rgb = modernTone ? photoDisplay(linear) : displayFromLinear(linear);
        }
      } else if (filmNegativeEnabled == 1.0) {
        vec3 filmLinear = filmNegativeLinearValue(
          rgb, vec3(fnRExp, fnGExp, fnBExp), vec3(fnRMult, fnGMult, fnBMult));
        if (modernTone) filmLinear *= 4.32;
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
            photoHighlights, photoShadows, photoToneReference, photoVersion, photoWhites,
            photoBlacks, photoShadowFloor, photoMidtoneLevel, photoHighlightCeiling);
        }
        if (useProtectedColor) {
          filmLinear = protectedColor(
            filmLinear, photoTemperatureMired, photoTint, photoSaturation, photoVibrance, photoWarmHueRecovery, modernTone ? 1e-6 : 0.0);
        }
        rgb = modernTone ? photoDisplay(filmLinear) : filmNegativeDisplayFromLinear(filmLinear);
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
        if (useDyeMixing || useLinearTone || (modernTone && useProtectedColor)) {
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
              photoHighlights, photoShadows, photoToneReference, photoVersion, photoWhites,
              photoBlacks, photoShadowFloor, photoMidtoneLevel, photoHighlightCeiling);
          }
          if (modernTone && useProtectedColor) {
            linear = protectedColor(linear, photoTemperatureMired, photoTint,
              photoSaturation, photoVibrance, photoWarmHueRecovery, modernTone ? 1e-6 : 0.0);
          }
          rgb = modernTone ? photoDisplay(linear) : displayFromLinear(linear);
        }
      }

      if (!modernTone && !isBW && !useProtectedColor) {
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

      if (modernTone) {
        rgb = photoCurve(lutImage, rgb);
      } else {
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

      if (!modernTone && !isBW && !useProtectedColor && saturation != 100.0) {
        vec3 hsv = rgbToHsv(clamp(rgb, 0.0, 1.0));
        hsv.y = clamp(hsv.y * saturation / 100.0, 0.0, 1.0);
        rgb = hsvToRgb(hsv);
      }
      if (modernTone) rgb = photoGamut(rgb);
      if (isNegative && sensorBlack) {
        rgb = vec3(1.0);
      }
      return vec4(clamp(rgb, 0.0, 1.0), pixel.a);
    }
    """
}

private struct CurveLUTKey: Hashable {
  let photographicTone: Bool
  let curveEnabled: Bool
  let curveControlPoints: [CurvePoint]
  let redCurveEnabled: Bool
  let redCurveControlPoints: [CurvePoint]
  let greenCurveEnabled: Bool
  let greenCurveControlPoints: [CurvePoint]
  let blueCurveEnabled: Bool
  let blueCurveControlPoints: [CurvePoint]

  init(parameters: ProcessingParameters) {
    photographicTone = parameters.photoAdjustments.usesPhotographicTone
    curveEnabled = parameters.curveEnabled
    curveControlPoints = parameters.curveControlPoints
    redCurveEnabled = parameters.filmType.supportsColorCorrections && parameters.redCurveEnabled
    redCurveControlPoints = parameters.redCurveControlPoints
    greenCurveEnabled = parameters.filmType.supportsColorCorrections && parameters.greenCurveEnabled
    greenCurveControlPoints = parameters.greenCurveControlPoints
    blueCurveEnabled = parameters.filmType.supportsColorCorrections && parameters.blueCurveEnabled
    blueCurveControlPoints = parameters.blueCurveControlPoints
  }
}
