import Foundation

/// One selected-source cache. Geometry and Darkroom analysis survive point edits;
/// a source change replaces the owner. The density/flat-field path keeps its
/// sensor-space reference implementation until its preparation can be shared.
public final class CPUPreviewPreparationCache: @unchecked Sendable {
  private let image: UInt16Image
  private let analysisImage: UInt16Image?
  private let lock = NSLock()
  private let memoryLock = NSLock()
  private var geometryBytes = 0
  private var geometryKey: ProcessingParameters?
  private var prepared: UInt16Image?
  private var analysisProfile: NegativeDensityProfile?
  private var analysisPaper: DensityPaperProfile?
  private var analysis: DensityPrintAnalysis?
  private var analysisVersion = 0
  private(set) var geometryBuildCount = 0
  private(set) var analysisBuildCount = 0

  public init(image: UInt16Image, analysisImage: UInt16Image? = nil) {
    self.image = image
    self.analysisImage = analysisImage
  }

  public var retainedGeometryByteCount: Int {
    memoryLock.lock()
    defer { memoryLock.unlock() }
    return geometryBytes
  }

  public func render(
    parameters: ProcessingParameters, flatField: UInt16Image? = nil
  ) -> UInt16Image {
    // A cache belongs to one immutable source, never to a roll of images.
    guard !parameters.densityPipelineEnabled else {
      return FilmProcessing.correctedPreview(
        image: image, parameters: parameters, flatField: flatField)
    }
    lock.lock()
    defer { lock.unlock() }
    let key = ProcessingParameters(
      borderCrop: parameters.borderCrop, flip: parameters.flip, rotation: parameters.rotation,
      straightenAngle: parameters.straightenAngle, cropRect: parameters.cropRect,
      cropRectCoordinateSpace: parameters.cropRectCoordinateSpace,
      perspectiveCrop: parameters.perspectiveCrop, manualCrop: parameters.manualCrop)
    if geometryKey != key {
      // Release the previous warped raster before building its replacement.
      prepared = nil
      analysis = nil
      analysisProfile = nil
      analysisPaper = nil
      prepared = FilmProcessing.prepareGeometry(image: image, parameters: parameters)
      let sharesSource = prepared!.pixels.withUnsafeBufferPointer { geometry in
        image.pixels.withUnsafeBufferPointer { source in geometry.baseAddress == source.baseAddress
        }
      }
      memoryLock.lock()
      geometryBytes = sharesSource ? 0 : prepared!.pixels.count * MemoryLayout<UInt16>.stride
      memoryLock.unlock()
      geometryKey = key
      geometryBuildCount += 1
    }
    guard let prepared else { return image }
    let fn = parameters.filmNegativeParams
    if parameters.filmType == .colourNegative && fn.enabled && fn.rendering == .densityPrint {
      // Resolved values include edited user profiles; ids alone are insufficient.
      let profile = DensityPrintProcessing.resolvedProfile(from: fn)
      let paper = DensityPrintProcessing.resolvedPaper(for: parameters)
      if analysisProfile != profile || analysisPaper != paper || analysis == nil
        || analysisVersion != parameters.photoAdjustments.schemaVersion
      {
        analysis =
          parameters.photoAdjustments.usesPhotographicTone
          ? FilmProcessing.photographicDensityAnalysis(
            image: analysisImage ?? image, parameters: parameters)
          : DensityPrintProcessing.analyze(image: prepared, profile: profile, paper: paper)
        analysisVersion = parameters.photoAdjustments.schemaVersion
        analysisProfile = profile
        analysisPaper = paper
        analysisBuildCount += 1
      }
    } else {
      analysis = nil
      analysisProfile = nil
      analysisPaper = nil
    }
    if parameters.photoAdjustments.usesPhotographicTone {
      return FilmProcessing.correctedPhotographicPreview(
        image: image, parameters: parameters,
        preparedGeometry: prepared, densityAnalysis: analysis)
    }
    return FilmProcessing.correctedPreviewPowerLaw(
      image: image, parameters: parameters, preparedGeometry: prepared, densityAnalysis: analysis)
  }
}
