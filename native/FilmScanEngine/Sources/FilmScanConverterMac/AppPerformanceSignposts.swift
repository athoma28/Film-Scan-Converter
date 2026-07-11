import Foundation
import os.signpost

enum AppPerformanceStage: String, CaseIterable, Sendable {
  case queueWait = "Queue Wait"
  case settingsAndClassification = "Settings and Classification"
  case decode = "Decode"
  case flatFieldLookup = "Flat Field Lookup"
  case correction = "Correction"
  case geometryAndFrame = "Geometry and Frame"
  case writeAndFinalize = "Write and Finalize"
  case cleanup = "Cleanup"
  case thumbnailExtraction = "Thumbnail Extraction"
  case standardPreviewDecode = "Standard Preview Decode"
  case authoritativeReplacement = "Authoritative Replacement"
  case firstCorrectedPreview = "First Corrected Preview"
  case selectionReceived = "Selection Received"
  case metadataRead = "Metadata and Dimensions"
  case previewConversion = "1000px Conversion"
  case analysis = "Classification and Median Calibration"
  case rendererSetup = "Preview Renderer Setup"
  case gpuRender = "GPU Render"
  case displayPublication = "Display Publication"
  case rawDetailQueueDelay = "RAW Detail Queue Delay"
}

struct AppPerformanceInterval: @unchecked Sendable {
  let stage: AppPerformanceStage
  let signpostID: OSSignpostID
  let correlationID: String
  let filename: String
}

enum AppPerformanceSignposts {
  private static let log = OSLog(
    subsystem: "film.scan.converter", category: "AppPathPerformance")

  static func begin(
    _ stage: AppPerformanceStage,
    correlationID: String,
    filename: String
  ) -> AppPerformanceInterval {
    let interval = AppPerformanceInterval(
      stage: stage,
      signpostID: OSSignpostID(log: log),
      correlationID: correlationID,
      filename: filename
    )
    emit(.begin, interval: interval)
    return interval
  }

  static func end(_ interval: AppPerformanceInterval) {
    emit(.end, interval: interval)
  }

  private static func emit(
    _ type: OSSignpostType,
    interval: AppPerformanceInterval
  ) {
    switch interval.stage {
    case .queueWait: emit(type, name: "Queue Wait", interval: interval)
    case .settingsAndClassification:
      emit(type, name: "Settings and Classification", interval: interval)
    case .decode: emit(type, name: "Decode", interval: interval)
    case .flatFieldLookup: emit(type, name: "Flat Field Lookup", interval: interval)
    case .correction: emit(type, name: "Correction", interval: interval)
    case .geometryAndFrame: emit(type, name: "Geometry and Frame", interval: interval)
    case .writeAndFinalize: emit(type, name: "Write and Finalize", interval: interval)
    case .cleanup: emit(type, name: "Cleanup", interval: interval)
    case .thumbnailExtraction: emit(type, name: "Thumbnail Extraction", interval: interval)
    case .standardPreviewDecode: emit(type, name: "Standard Preview Decode", interval: interval)
    case .authoritativeReplacement:
      emit(type, name: "Authoritative Replacement", interval: interval)
    case .firstCorrectedPreview: emit(type, name: "First Corrected Preview", interval: interval)
    case .selectionReceived: emit(type, name: "Selection Received", interval: interval)
    case .metadataRead: emit(type, name: "Metadata and Dimensions", interval: interval)
    case .previewConversion: emit(type, name: "1000px Conversion", interval: interval)
    case .analysis: emit(type, name: "Classification and Median Calibration", interval: interval)
    case .rendererSetup: emit(type, name: "Preview Renderer Setup", interval: interval)
    case .gpuRender: emit(type, name: "GPU Render", interval: interval)
    case .displayPublication: emit(type, name: "Display Publication", interval: interval)
    case .rawDetailQueueDelay: emit(type, name: "RAW Detail Queue Delay", interval: interval)
    }
  }

  private static func emit(
    _ type: OSSignpostType,
    name: StaticString,
    interval: AppPerformanceInterval
  ) {
    os_signpost(
      type,
      log: log,
      name: name,
      signpostID: interval.signpostID,
      "file=%{public}s correlation=%{public}s",
      interval.filename,
      interval.correlationID
    )
  }
}
