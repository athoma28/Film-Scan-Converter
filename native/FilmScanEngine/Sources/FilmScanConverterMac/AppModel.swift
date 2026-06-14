import AppKit
import FilmScanEngine

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var files: [URL] = []
  @Published var selection: URL?
  @Published private(set) var previewImage: NSImage?
  @Published private(set) var decodedImage: UInt16Image?
  @Published private(set) var status = "Drop film scans into the window to begin."
  private var loadTask: Task<Void, Never>?

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

    guard let selection else {
      previewImage = nil
      decodedImage = nil
      status = "Drop film scans into the window to begin."
      return
    }

    status = "Starting processing for \(selection.lastPathComponent)..."
    previewImage = nil
    decodedImage = nil

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
        guard self.selection == selection,
          let preview = decoded.makePreviewCGImage()
        else {
          throw AppModelError.cannotCreatePreview
        }
        decodedImage = decoded
        previewImage = NSImage(cgImage: preview, size: .zero)
        status =
          "\(selection.lastPathComponent) decoded into a \(decoded.width)×\(decoded.height) 16-bit engine buffer."
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
}

private enum AppModelError: LocalizedError {
  case cannotCreatePreview

  var errorDescription: String? {
    "The decoded engine buffer could not be converted into a preview."
  }
}
