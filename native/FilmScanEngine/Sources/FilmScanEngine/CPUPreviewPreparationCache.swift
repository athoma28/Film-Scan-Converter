import Foundation

/// One immutable-source session cache. Geometry and Darkroom analysis survive
/// point edits and cached revisits; a source replacement requires a new owner.
/// The density/flat-field path keeps its
/// sensor-space reference implementation until its preparation can be shared.
public final class CPUPreviewPreparationCache: @unchecked Sendable {
  private let image: UInt16Image
  private let analysisImage: UInt16Image?
  private let lock = NSLock()
  private let memoryLock = NSLock()
  private var geometryBytes = 0
  private var geometryKey: ProcessingParameters?
  private var prepared: UInt16Image?
  private var overview: UInt16Image?
  private var overviewBound: Int?
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

  /// A supported GPU render can bypass preparation after geometry changes.
  /// Release only the incompatible work, preserving this source's owner and
  /// matching geometry for point edits, comparisons, and cached revisits.
  /// Call on a rendering worker: this shares the CPU preparation lock.
  public func discardGeometry(ifIncompatibleWith parameters: ProcessingParameters) {
    lock.lock()
    defer { lock.unlock() }
    guard let geometryKey, geometryKey != Self.geometryKey(for: parameters) else { return }
    clearPreparation()
    updateGeometryBytes()
  }

  public func render(
    parameters: ProcessingParameters, flatField: UInt16Image? = nil
  ) -> UInt16Image {
    // A cache belongs to one immutable source, never to a roll of images.
    guard !parameters.densityPipelineEnabled else {
      discardGeometry(ifIncompatibleWith: parameters)
      return FilmProcessing.correctedPreview(
        image: image, parameters: parameters, flatField: flatField)
    }
    lock.lock()
    defer { lock.unlock() }
    prepare(parameters: parameters)
    guard let prepared else { return image }
    if parameters.photoAdjustments.usesPhotographicTone {
      return FilmProcessing.correctedPhotographicPreview(
        image: image, parameters: parameters,
        preparedGeometry: prepared, densityAnalysis: analysis)
    }
    return FilmProcessing.correctedPreviewPowerLaw(
      image: image, parameters: parameters, preparedGeometry: prepared, densityAnalysis: analysis)
  }

  /// Interactive geometry fallbacks correct a bounded overview and exact visible
  /// sensor pixels. Analysis remains anchored to the immutable source; release
  /// uses `render` to publish the complete authoritative raster.
  public func renderViewport(
    parameters: ProcessingParameters, region: ImageRegion, overviewMaximumDimension: Int
  ) -> (overview: UInt16Image, detail: UInt16Image)? {
    guard parameters.photoAdjustments.usesPhotographicTone,
      !parameters.densityPipelineEnabled, parameters.filmType != .cropOnly,
      overviewMaximumDimension > 0
    else { return nil }
    lock.lock()
    defer { lock.unlock() }
    prepare(parameters: parameters)
    guard let prepared, region.x >= 0, region.y >= 0,
      region.width > 0, region.height > 0,
      region.width <= prepared.width - region.x,
      region.height <= prepared.height - region.y
    else { return nil }
    let bound = min(overviewMaximumDimension, 2_048, max(prepared.width, prepared.height))
    if overviewBound != bound {
      // Nearest-neighbor sampling commutes with photographic point correction:
      // its analysis comes from the immutable sensor, not these overview pixels.
      // Preserve the previous two-stage sample coordinates, including rounding
      // at odd dimensions, but correct only the pixels the caller will display.
      overview = nil
      overview = prepared.resizedToFit(maxDimension: 2_048).resizedToFit(maxDimension: bound)
      overviewBound = bound
      updateGeometryBytes()
    }
    guard let overview else { return nil }
    var pixels = [UInt16]()
    pixels.reserveCapacity(region.width * region.height * prepared.channels)
    for y in region.y..<(region.y + region.height) {
      let start = (y * prepared.width + region.x) * prepared.channels
      pixels.append(contentsOf: prepared.pixels[start..<(start + region.width * prepared.channels)])
    }
    let detailSource = UInt16Image(
      width: region.width, height: region.height, channels: prepared.channels, pixels: pixels)
    let correctedOverview = FilmProcessing.correctedPhotographicPreview(
      image: image, parameters: parameters, preparedGeometry: overview, densityAnalysis: analysis)
    let detail = FilmProcessing.correctedPhotographicPreview(
      image: image, parameters: parameters, preparedGeometry: detailSource,
      densityAnalysis: analysis)
    return (correctedOverview, detail)
  }

  /// Called only while the render lock is held.
  private func prepare(parameters: ProcessingParameters) {
    let key = Self.geometryKey(for: parameters)
    if geometryKey != key {
      // Release the previous warped raster before building its replacement.
      clearPreparation()
      prepared = FilmProcessing.prepareGeometry(image: image, parameters: parameters)
      updateGeometryBytes()
      geometryKey = key
      geometryBuildCount += 1
    }
    guard let prepared else { return }
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
  }

  private static func geometryKey(for parameters: ProcessingParameters) -> ProcessingParameters {
    ProcessingParameters(
      borderCrop: parameters.borderCrop, flip: parameters.flip, rotation: parameters.rotation,
      straightenAngle: parameters.straightenAngle, cropRect: parameters.cropRect,
      cropRectCoordinateSpace: parameters.cropRectCoordinateSpace,
      perspectiveCrop: parameters.perspectiveCrop, manualCrop: parameters.manualCrop,
      dustRepairs: parameters.dustRepairs)
  }

  /// Called only while the render lock is held.
  private func clearPreparation() {
    geometryKey = nil
    prepared = nil
    overview = nil
    overviewBound = nil
    analysis = nil
    analysisProfile = nil
    analysisPaper = nil
    analysisVersion = 0
  }

  private func updateGeometryBytes() {
    func retainedBytes(_ candidate: UInt16Image?, excluding other: UInt16Image) -> Int {
      guard let candidate else { return 0 }
      let sharesStorage = candidate.pixels.withUnsafeBufferPointer { lhs in
        other.pixels.withUnsafeBufferPointer { rhs in lhs.baseAddress == rhs.baseAddress }
      }
      return sharesStorage ? 0 : candidate.pixels.count * MemoryLayout<UInt16>.stride
    }
    let bytes =
      retainedBytes(prepared, excluding: image)
      + retainedBytes(overview, excluding: prepared ?? image)
    memoryLock.lock()
    geometryBytes = bytes
    memoryLock.unlock()
  }
}
