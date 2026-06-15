import AppKit
import FilmScanEngine

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var files: [URL] = []
  @Published var selection: URL?
  @Published private(set) var previewImage: NSImage?
  @Published private(set) var decodedImage: UInt16Image?
  @Published private(set) var parameters = ProcessingParameters()
  @Published private(set) var isRendering = false
  @Published var showOriginal = false {
    didSet { scheduleRender() }
  }
  @Published private(set) var status = "Drop film scans into the window to begin."

  private var settingsByPath: [String: ProcessingParameters] = [:]
  private var previewSource: UInt16Image?
  private var previewRenderer: StillPreviewRenderer?
  private var loadTask: Task<Void, Never>?
  private var renderTask: Task<Void, Never>?
  private var pendingRender: PreviewRenderRequest?
  private var renderLoopGeneration = 0

  func importFiles(_ urls: [URL]) {
    let supported = FileDropPolicy.supportedFiles(from: urls)
    guard !supported.isEmpty else {
      status = "No supported image or RAW files were dropped."
      return
    }

    let existing = Set(files.map(\.standardizedFileURL.path))
    files.append(contentsOf: supported.filter { !existing.contains($0.standardizedFileURL.path) })
    selection = supported.first
    loadSelection()
  }

  func loadSelection() {
    loadTask?.cancel()
    cancelRenderLoop()

    guard let selection else {
      previewImage = nil
      decodedImage = nil
      previewSource = nil
      previewRenderer = nil
      status = "Drop film scans into the window to begin."
      return
    }

    previewImage = nil
    decodedImage = nil
    previewSource = nil
    previewRenderer = nil
    parameters = settingsByPath[settingsKey(selection)] ?? ProcessingParameters()
    showOriginal = false
    status = "Decoding \(selection.lastPathComponent)..."

    loadTask = Task { [weak self] in
      guard let self else {
        return
      }
      do {
        let decoded = try await Task.detached(priority: .userInitiated) {
          if StandardImageDecoder.supportedExtensions.contains(selection.pathExtension.lowercased())
          {
            return try StandardImageDecoder.decode(selection)
          }
          return try RawImageDecoder.decode(selection).image
        }.value
        try Task.checkCancellation()
        guard self.selection == selection else {
          return
        }
        decodedImage = decoded
        let proxy = decoded.resizedToFit(maxDimension: 1080)
        previewSource = proxy
        previewRenderer = StillPreviewRenderer(image: proxy)
        scheduleRender(immediate: true)
      } catch is CancellationError {
        return
      } catch {
        guard self.selection == selection else {
          return
        }
        status = "Unable to decode \(selection.lastPathComponent): \(error.localizedDescription)"
      }
    }
  }

  func setFilmType(_ value: FilmType) {
    updateParameters { $0.filmType = value }
  }

  func setTemperature(_ value: Int) {
    updateParameters { $0.temperature = value }
  }

  func setTint(_ value: Int) {
    updateParameters { $0.tint = value }
  }

  func setGamma(_ value: Int) {
    updateParameters { $0.gamma = value }
  }

  func setShadows(_ value: Int) {
    updateParameters { $0.shadows = value }
  }

  func setHighlights(_ value: Int) {
    updateParameters { $0.highlights = value }
  }

  func setSaturation(_ value: Int) {
    updateParameters { $0.saturation = value }
  }

  func rotateCounterclockwise() {
    updateParameters { $0.rotation = ($0.rotation + 3) % 4 }
  }

  func rotateClockwise() {
    updateParameters { $0.rotation = ($0.rotation + 1) % 4 }
  }

  func toggleFlip() {
    updateParameters { $0.flip.toggle() }
  }

  func resetCorrections() {
    parameters = ProcessingParameters()
    saveParameters()
    if showOriginal {
      showOriginal = false
    } else {
      scheduleRender(immediate: true)
    }
  }

  func showImportPanel() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = []
    guard panel.runModal() == .OK else {
      return
    }
    importFiles(panel.urls)
  }

  private func updateParameters(_ update: (inout ProcessingParameters) -> Void) {
    update(&parameters)
    saveParameters()
    if showOriginal {
      showOriginal = false
    } else {
      scheduleRender()
    }
  }

  private func saveParameters() {
    guard let selection else {
      return
    }
    settingsByPath[settingsKey(selection)] = parameters
  }

  private func scheduleRender(immediate _: Bool = false) {
    guard let selection, let previewSource else {
      return
    }

    pendingRender = PreviewRenderRequest(
      selection: selection,
      source: previewSource,
      renderer: previewRenderer,
      parameters: parameters,
      showOriginal: showOriginal
    )
    isRendering = true
    status = "Rendering \(selection.lastPathComponent)..."
    guard renderTask == nil else {
      return
    }

    renderLoopGeneration += 1
    let generation = renderLoopGeneration
    renderTask = Task { [weak self] in
      await self?.processRenderQueue(generation: generation)
    }
  }

  private func processRenderQueue(generation: Int) async {
    while !Task.isCancelled, let request = pendingRender {
      pendingRender = nil
      let preview: CGImage? = await Task.detached(priority: .userInitiated) { () -> CGImage? in
        if let renderer = request.renderer,
          let rendered = renderer.render(
            parameters: request.parameters,
            showOriginal: request.showOriginal
          )
        {
          return rendered
        }
        let rendered =
          request.showOriginal
          ? request.source.rotated(
            quarterTurns: request.parameters.rotation,
            flipHorizontally: request.parameters.flip
          )
          : FilmProcessing.correctedPreview(
            image: request.source,
            parameters: request.parameters
          )
        return rendered.makePreviewCGImage()
      }.value

      guard !Task.isCancelled else {
        break
      }
      guard pendingRender == nil else {
        continue
      }
      guard selection == request.selection,
        parameters == request.parameters,
        showOriginal == request.showOriginal,
        let preview
      else {
        continue
      }
      previewImage = NSImage(cgImage: preview, size: .zero)
      status =
        "\(request.selection.lastPathComponent) • \(preview.width)×\(preview.height) GPU preview"
    }

    guard generation == renderLoopGeneration else {
      return
    }
    renderTask = nil
    isRendering = false
  }

  private func cancelRenderLoop() {
    renderLoopGeneration += 1
    renderTask?.cancel()
    renderTask = nil
    pendingRender = nil
    isRendering = false
  }

  private func settingsKey(_ url: URL) -> String {
    url.standardizedFileURL.path
  }
}

private struct PreviewRenderRequest: Sendable {
  let selection: URL
  let source: UInt16Image
  let renderer: StillPreviewRenderer?
  let parameters: ProcessingParameters
  let showOriginal: Bool
}
