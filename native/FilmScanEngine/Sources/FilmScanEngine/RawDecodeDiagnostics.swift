import Foundation

/// Opt-in camera-scan decode diagnostics: SHA-256 digests captured at RAW
/// stage boundaries so a repeated-decode determinism run can isolate the first
/// divergent stage without storing full intermediates. Digests compare runs of
/// the same build on the same machine; they hash raw buffer bytes and are not
/// a cross-platform identity contract.
public struct RawDecodeDiagnostics: Codable, Equatable, Sendable {
  /// Unpacked-mosaic width in photosites, folded into the mosaic digest.
  public let mosaicRawWidth: Int
  /// Unpacked-mosaic height in photosites, folded into the mosaic digest.
  public let mosaicRawHeight: Int
  /// LibRaw CFA filter descriptor folded into the mosaic digest (9 = X-Trans).
  public let mosaicFilters: UInt32
  /// Number of CFA-pattern bytes folded into the mosaic digest (36 for
  /// X-Trans, 0 when the CFA is fully described by `mosaicFilters`).
  public let mosaicCFABytes: Int
  /// After unpack: mosaic dimensions/CFA metadata plus the raw mosaic.
  public let unpackedMosaicSHA256: String
  /// Inside the demosaic callback, immediately after interpolation returns,
  /// before the remaining `dcraw_process` stages.
  public let demosaicedSHA256: String
  /// The image returned by `dcraw_make_mem_image` (after the preview
  /// downsample when that path runs), before the ISO-adaptive filter.
  public let processedImageSHA256: String
  /// The same buffer after the ISO-adaptive filter.
  public let postISOImageSHA256: String
  /// The Swift-owned RGB image after the BGR copy/swizzle boundary.
  public let swiftImageSHA256: String

  public init(
    mosaicRawWidth: Int,
    mosaicRawHeight: Int,
    mosaicFilters: UInt32,
    mosaicCFABytes: Int,
    unpackedMosaicSHA256: String,
    demosaicedSHA256: String,
    processedImageSHA256: String,
    postISOImageSHA256: String,
    swiftImageSHA256: String
  ) {
    self.mosaicRawWidth = mosaicRawWidth
    self.mosaicRawHeight = mosaicRawHeight
    self.mosaicFilters = mosaicFilters
    self.mosaicCFABytes = mosaicCFABytes
    self.unpackedMosaicSHA256 = unpackedMosaicSHA256
    self.demosaicedSHA256 = demosaicedSHA256
    self.processedImageSHA256 = processedImageSHA256
    self.postISOImageSHA256 = postISOImageSHA256
    self.swiftImageSHA256 = swiftImageSHA256
  }

  /// Whether every required camera-scan boundary contains a valid SHA-256
  /// digest and the unpacked mosaic has a non-empty shape.
  public var hasCompleteStageDigests: Bool {
    mosaicRawWidth > 0
      && mosaicRawHeight > 0
      && mosaicCFABytes == (mosaicFilters == 9 ? 36 : 0)
      && [
        unpackedMosaicSHA256,
        demosaicedSHA256,
        processedImageSHA256,
        postISOImageSHA256,
        swiftImageSHA256,
      ].allSatisfy(isLowercaseSHA256)
  }
}

/// One named stage-boundary digest in pipeline order.
public struct StageBoundaryDigest: Codable, Equatable, Sendable {
  public let boundary: String
  public let sha256: String

  public init(boundary: String, sha256: String) {
    self.boundary = boundary
    self.sha256 = sha256
  }
}

/// Whether one stage boundary held the same digest across repeated decodes.
public struct StageBoundaryAgreement: Codable, Equatable, Sendable {
  public let boundary: String
  public let distinctDigests: Int
  public let allAgree: Bool

  public init(boundary: String, distinctDigests: Int, allAgree: Bool) {
    self.boundary = boundary
    self.distinctDigests = distinctDigests
    self.allAgree = allAgree
  }
}

/// Comparison helpers for repeated camera-scan decodes. The boundary order is
/// pipeline order, so the first disagreement in `agreement(_:)` is the first
/// stage a threaded candidate allowed to diverge.
public enum RawDecodeDeterminism {
  /// The decode stage boundaries in pipeline order: unpacked mosaic,
  /// demosaiced image, processed image, post-ISO image, Swift image.
  public static func boundaryDigests(of diagnostics: RawDecodeDiagnostics)
    -> [StageBoundaryDigest]
  {
    [
      StageBoundaryDigest(boundary: "unpackedMosaic", sha256: diagnostics.unpackedMosaicSHA256),
      StageBoundaryDigest(boundary: "demosaicedImage", sha256: diagnostics.demosaicedSHA256),
      StageBoundaryDigest(boundary: "processedImage", sha256: diagnostics.processedImageSHA256),
      StageBoundaryDigest(boundary: "postISOImage", sha256: diagnostics.postISOImageSHA256),
      StageBoundaryDigest(boundary: "swiftImage", sha256: diagnostics.swiftImageSHA256),
    ]
  }

  /// Per-boundary agreement across repeated diagnostics, in pipeline order.
  public static func agreement(_ samples: [RawDecodeDiagnostics])
    -> [StageBoundaryAgreement]
  {
    guard let first = samples.first else { return [] }
    let boundaries = boundaryDigests(of: first)
    return boundaries.indices.map { index in
      let digests = samples.map { boundaryDigests(of: $0)[index].sha256 }
      let distinct = Set(digests).count
      return StageBoundaryAgreement(
        boundary: boundaries[index].boundary,
        distinctDigests: distinct,
        allAgree: digests.allSatisfy(isLowercaseSHA256) && distinct == 1
      )
    }
  }
}

private func isLowercaseSHA256(_ digest: String) -> Bool {
  digest.utf8.count == 64
    && digest.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
}
