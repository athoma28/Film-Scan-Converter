import AppKit
import SwiftUI

enum PreviewZoomAction: Sendable {
  case fit
  case actualSize
  case zoomIn
  case zoomOut
}

struct PreviewZoomRequest: Equatable, Sendable {
  var sequence = 0
  var action: PreviewZoomAction = .fit

  mutating func request(_ action: PreviewZoomAction) {
    sequence &+= 1
    self.action = action
  }
}

struct PreviewZoomCommands {
  let fit: () -> Void
  let actualSize: () -> Void
  let zoomIn: () -> Void
  let zoomOut: () -> Void
}

private struct PreviewZoomCommandsKey: FocusedValueKey {
  typealias Value = PreviewZoomCommands
}

extension FocusedValues {
  var previewZoomCommands: PreviewZoomCommands? {
    get { self[PreviewZoomCommandsKey.self] }
    set { self[PreviewZoomCommandsKey.self] = newValue }
  }
}

struct PreviewViewCommands: Commands {
  @FocusedValue(\.previewZoomCommands) private var zoomCommands

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Divider()

      Button("Fit Preview in Window") {
        zoomCommands?.fit()
      }
      .keyboardShortcut("0", modifiers: .command)
      .disabled(zoomCommands == nil)

      Button("Preview at 100%") {
        zoomCommands?.actualSize()
      }
      .keyboardShortcut("1", modifiers: .command)
      .disabled(zoomCommands == nil)

      Button("Zoom In") {
        zoomCommands?.zoomIn()
      }
      .keyboardShortcut("+", modifiers: .command)
      .disabled(zoomCommands == nil)

      Button("Zoom Out") {
        zoomCommands?.zoomOut()
      }
      .keyboardShortcut("-", modifiers: .command)
      .disabled(zoomCommands == nil)
    }
  }
}

enum PreviewViewportZoom {
  static let minimumMagnification: CGFloat = 0.02
  static let maximumMagnification: CGFloat = 8
  static let stepFactor: CGFloat = 1.25

  static func fitMagnification(imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
    guard imageSize.width > 0, imageSize.height > 0,
      viewportSize.width > 0, viewportSize.height > 0
    else { return 1 }

    return clamped(
      min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height))
  }

  static func steppedMagnification(from value: CGFloat, zoomingIn: Bool) -> CGFloat {
    clamped(value * (zoomingIn ? stepFactor : 1 / stepFactor))
  }

  static func percent(for magnification: CGFloat) -> Int {
    max(1, Int((magnification * 100).rounded()))
  }

  static func clamped(_ magnification: CGFloat) -> CGFloat {
    min(max(magnification, minimumMagnification), maximumMagnification)
  }
}

/// A native scroll view keeps Mac trackpad scrolling, momentum, rubber-banding,
/// and cursor-centered pinch magnification. The SwiftUI document view contains
/// the image and every editing overlay so they always share one transform.
struct PreviewViewport<Content: View>: NSViewRepresentable {
  let imageSize: CGSize
  let request: PreviewZoomRequest
  let content: Content
  let onZoomChanged: (Int, Bool) -> Void

  init(
    imageSize: CGSize,
    request: PreviewZoomRequest,
    onZoomChanged: @escaping (Int, Bool) -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.imageSize = imageSize
    self.request = request
    self.onZoomChanged = onZoomChanged
    self.content = content()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(rootView: content, onZoomChanged: onZoomChanged)
  }

  func makeNSView(context: Context) -> PreviewScrollView {
    let scrollView = PreviewScrollView()
    scrollView.contentView = CenteredPreviewClipView()
    scrollView.documentView = context.coordinator.hostingView
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.horizontalScrollElasticity = .automatic
    scrollView.verticalScrollElasticity = .automatic
    scrollView.allowsMagnification = true
    scrollView.minMagnification = PreviewViewportZoom.minimumMagnification
    scrollView.maxMagnification = PreviewViewportZoom.maximumMagnification

    context.coordinator.scrollView = scrollView
    context.coordinator.observeMagnification(in: scrollView)
    scrollView.onViewportLayout = { [weak coordinator = context.coordinator] in
      coordinator?.viewportDidLayout()
    }
    return scrollView
  }

  func updateNSView(_ scrollView: PreviewScrollView, context: Context) {
    context.coordinator.onZoomChanged = onZoomChanged
    context.coordinator.hostingView.rootView = content
    context.coordinator.updateDocumentSize(imageSize)
    context.coordinator.apply(request)
  }

  @MainActor
  final class Coordinator: NSObject {
    let hostingView: NSHostingView<Content>
    weak var scrollView: PreviewScrollView?
    var onZoomChanged: (Int, Bool) -> Void

    private var documentSize: CGSize = .zero
    private var lastRequestSequence = -1
    private var lastViewportSize: CGSize = .zero
    private var lastReportedPercent = -1
    private var lastReportedFit = false
    private var isFitMode = true

    init(rootView: Content, onZoomChanged: @escaping (Int, Bool) -> Void) {
      hostingView = NSHostingView(rootView: rootView)
      hostingView.sizingOptions = []
      self.onZoomChanged = onZoomChanged
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    func observeMagnification(in scrollView: NSScrollView) {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(willStartLiveMagnification),
        name: NSScrollView.willStartLiveMagnifyNotification,
        object: scrollView)
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(didEndLiveMagnification),
        name: NSScrollView.didEndLiveMagnifyNotification,
        object: scrollView)
    }

    func updateDocumentSize(_ size: CGSize) {
      let validSize = CGSize(width: max(1, size.width), height: max(1, size.height))
      guard validSize != documentSize else { return }
      documentSize = validSize
      hostingView.frame = CGRect(origin: .zero, size: validSize)
      if isFitMode {
        applyFit(force: true)
      } else if let scrollView {
        scrollView.reflectScrolledClipView(scrollView.contentView)
      }
    }

    func apply(_ request: PreviewZoomRequest) {
      guard request.sequence != lastRequestSequence else { return }
      lastRequestSequence = request.sequence
      guard let scrollView else { return }

      switch request.action {
      case .fit:
        isFitMode = true
        applyFit(force: true)
      case .actualSize:
        isFitMode = false
        setMagnification(1, centeredAtVisiblePointIn: scrollView)
      case .zoomIn:
        isFitMode = false
        setMagnification(
          PreviewViewportZoom.steppedMagnification(
            from: scrollView.magnification, zoomingIn: true),
          centeredAtVisiblePointIn: scrollView)
      case .zoomOut:
        isFitMode = false
        setMagnification(
          PreviewViewportZoom.steppedMagnification(
            from: scrollView.magnification, zoomingIn: false),
          centeredAtVisiblePointIn: scrollView)
      }
      reportZoom()
    }

    func viewportDidLayout() {
      guard let scrollView else { return }
      let viewportSize = scrollView.contentSize
      guard viewportSize.width > 0, viewportSize.height > 0,
        viewportSize != lastViewportSize
      else { return }
      lastViewportSize = viewportSize
      if isFitMode {
        applyFit(force: true)
      }
    }

    @objc private func willStartLiveMagnification(_ notification: Notification) {
      isFitMode = false
    }

    @objc private func didEndLiveMagnification(_ notification: Notification) {
      reportZoom()
    }

    private func applyFit(force: Bool) {
      guard let scrollView, documentSize.width > 0, documentSize.height > 0 else { return }
      let magnification = PreviewViewportZoom.fitMagnification(
        imageSize: documentSize,
        viewportSize: scrollView.contentSize)
      guard force || abs(scrollView.magnification - magnification) > 0.0001 else { return }
      scrollView.setMagnification(
        magnification,
        centeredAt: CGPoint(x: documentSize.width / 2, y: documentSize.height / 2))
      reportZoom()
    }

    private func setMagnification(
      _ value: CGFloat,
      centeredAtVisiblePointIn scrollView: NSScrollView
    ) {
      let visibleRect = scrollView.documentVisibleRect
      let center = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
      scrollView.setMagnification(PreviewViewportZoom.clamped(value), centeredAt: center)
    }

    private func reportZoom() {
      guard let scrollView else { return }
      let percent = PreviewViewportZoom.percent(for: scrollView.magnification)
      guard percent != lastReportedPercent || isFitMode != lastReportedFit else { return }
      lastReportedPercent = percent
      lastReportedFit = isFitMode
      let callback = onZoomChanged
      DispatchQueue.main.async {
        callback(percent, self.isFitMode)
      }
    }
  }
}

final class PreviewScrollView: NSScrollView {
  var onViewportLayout: (() -> Void)?

  override func layout() {
    super.layout()
    onViewportLayout?()
  }
}

/// NSScrollView normally pins a document smaller than its viewport to the
/// leading edge. Centering it makes Fit and zoomed-out states predictable.
final class CenteredPreviewClipView: NSClipView {
  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var constrained = super.constrainBoundsRect(proposedBounds)
    guard let documentView else { return constrained }

    if documentView.frame.width < constrained.width {
      constrained.origin.x = (documentView.frame.width - constrained.width) / 2
    }
    if documentView.frame.height < constrained.height {
      constrained.origin.y = (documentView.frame.height - constrained.height) / 2
    }
    return constrained
  }
}
