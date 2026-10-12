import CoreGraphics
import FilmScanEngine
import Foundation
import Observation

/// A source revision and the settings a factory look does not replace. Keeping
/// slider-only changes out of this key avoids redoing identical look previews.
struct PresetPreviewKey: Equatable, Sendable {
  let sourcePath: String
  let sourceGeneration: Int
  let baseParameters: ProcessingParameters

  init(sourceURL: URL, sourceGeneration: Int, parameters: ProcessingParameters) {
    sourcePath = sourceURL.standardizedFileURL.path
    self.sourceGeneration = sourceGeneration
    baseParameters = LookRecipe.cleanInvert.applying(to: parameters)
  }
}

/// Capture existing immutable buffers only. No decoding, image preparation, or
/// bitmap conversion takes place on the caller's main actor.
struct PresetPreviewRequest: Sendable {
  let key: PresetPreviewKey
  let source: UInt16Image
  let parameters: ProcessingParameters
  let flatField: UInt16Image?
}

struct PresetPreviewThumbnail: Identifiable, Sendable {
  let recipe: LookRecipe
  let image: CGImage
  var id: String { recipe.id }
}

struct PresetPreviewBatch: Sendable {
  let thumbnails: [PresetPreviewThumbnail]
  let elapsedMilliseconds: Double
}

enum PresetPreviewOutcome: Sendable {
  case completed(PresetPreviewBatch)
  case budgetExceeded(elapsedMilliseconds: Double)
  case cancelled
  case failed
}

enum PresetPreviewRenderer {
  static let maximumDimension = 160
  static let budget: Duration = .milliseconds(500)

  /// The measured budget includes downsampling, source analysis, flat-field
  /// preparation, every factory render, and all display-bitmap packing. It does
  /// not include RAW decoding: callers must provide an already decoded source.
  static func render(
    _ request: PresetPreviewRequest, budget: Duration = budget
  ) -> PresetPreviewOutcome {
    let start = ContinuousClock.now
    func elapsedMilliseconds() -> Double {
      let elapsed = start.duration(to: .now).components
      return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }
    func interruption() -> PresetPreviewOutcome? {
      if start.duration(to: .now) >= budget {
        return .budgetExceeded(elapsedMilliseconds: elapsedMilliseconds())
      }
      if Task.isCancelled { return .cancelled }
      return nil
    }
    if let interrupted = interruption() { return interrupted }
    let sensor = request.source.resizedToFit(maxDimension: 256)
    let source = request.source.resizedToFit(maxDimension: maximumDimension)
    var parameters = request.parameters
    if parameters.filmNegativeParams.enabled,
      parameters.filmNegativeParams.measuredMedians == nil
    {
      parameters.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(
        image: sensor)
    }
    let field =
      parameters.densityPipelineEnabled
      ? request.flatField?.resized(width: source.width, height: source.height) : nil
    let preparation = CPUPreviewPreparationCache(image: source, analysisImage: sensor)
    if let interrupted = interruption() { return interrupted }
    var thumbnails: [PresetPreviewThumbnail] = []
    thumbnails.reserveCapacity(LookRecipe.factory.count)
    for recipe in LookRecipe.factory {
      if let interrupted = interruption() { return interrupted }
      let rendered = preparation.render(
        parameters: recipe.applying(to: parameters), flatField: field)
      if let interrupted = interruption() { return interrupted }
      guard let bitmap = rendered.resizedToFit(maxDimension: maximumDimension).makePreviewCGImage()
      else { return .failed }
      thumbnails.append(PresetPreviewThumbnail(recipe: recipe, image: bitmap))
    }
    if let interrupted = interruption() { return interrupted }
    return .completed(
      PresetPreviewBatch(thumbnails: thumbnails, elapsedMilliseconds: elapsedMilliseconds()))
  }
}

/// Publishes a complete strip, never partial tiles. An over-budget calculation
/// disables this optional feature for the session instead of retrying expensive
/// work on every selection or edit. Named preset controls remain available.
@Observable
@MainActor
final class PresetPreviewStore {
  private(set) var thumbnails: [PresetPreviewThumbnail] = []
  private(set) var isRendering = false
  private(set) var disabledForSession = false
  private(set) var lastElapsedMilliseconds: Double?
  private var key: PresetPreviewKey?
  private var generation = 0
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private let renderer: @Sendable (PresetPreviewRequest) -> PresetPreviewOutcome

  init(
    renderer: @escaping @Sendable (PresetPreviewRequest) -> PresetPreviewOutcome = {
      PresetPreviewRenderer.render($0)
    }
  ) {
    self.renderer = renderer
  }

  /// A view can reject stale tiles in its very first update, before its
  /// onChange callback schedules the replacement request.
  func thumbnails(for requestedKey: PresetPreviewKey?) -> [PresetPreviewThumbnail] {
    guard key == requestedKey else { return [] }
    return thumbnails
  }

  func update(_ request: PresetPreviewRequest?) {
    guard request?.key != key else { return }
    generation += 1
    task?.cancel()
    task = nil
    thumbnails = []
    isRendering = false
    key = request?.key
    guard let request, !disabledForSession else { return }
    let revision = generation
    let render = renderer
    isRendering = true
    task = Task { [weak self] in
      let worker = Task.detached(priority: .utility) { render(request) }
      let result = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard let self else { return }
      // Even a superseded calculation that proved too costly trips the circuit
      // breaker; changing scans must not restart the same expensive pattern.
      if case .budgetExceeded(let milliseconds) = result {
        self.disabledForSession = true
        self.lastElapsedMilliseconds = milliseconds
        self.generation += 1
        self.task?.cancel()
        self.task = nil
        self.thumbnails = []
        self.isRendering = false
        return
      }
      guard !Task.isCancelled, self.generation == revision else { return }
      self.task = nil
      self.isRendering = false
      if case .completed(let batch) = result {
        self.lastElapsedMilliseconds = batch.elapsedMilliseconds
        self.thumbnails = batch.thumbnails
      }
    }
  }
}
