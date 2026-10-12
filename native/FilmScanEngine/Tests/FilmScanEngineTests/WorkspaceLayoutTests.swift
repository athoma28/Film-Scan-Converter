import AppKit
import FilmScanEngine
import SwiftUI
import Testing

@testable import FilmScanConverterMac

@Suite("Workspace panels", .serialized)
@MainActor
struct WorkspaceLayoutTests {
  @Test("Focus restores each prior sidebar and inspector combination")
  func focusRestoresPanelArrangement() {
    let sidebarStates: [NavigationSplitViewVisibility] = [.all, .detailOnly, .automatic]
    for sidebar in sidebarStates {
      for inspector in [false, true] {
        let workspace = WorkspaceLayout()
        workspace.sidebarVisibility = sidebar
        workspace.inspectorVisible = inspector

        workspace.toggleFocus()
        #expect(workspace.isFocused)
        #expect(workspace.sidebarVisibility == .detailOnly)
        #expect(!workspace.inspectorVisible)

        workspace.toggleFocus()
        #expect(!workspace.isFocused)
        #expect(workspace.sidebarVisibility == sidebar)
        #expect(workspace.inspectorVisible == inspector)
      }
    }
  }

  @Test("Opening the inspector leaves focus and restores the prior sidebar")
  func inspectorCommandLeavesFocus() {
    for sidebar in [NavigationSplitViewVisibility.all, .detailOnly] {
      for inspector in [false, true] {
        let workspace = WorkspaceLayout()
        workspace.sidebarVisibility = sidebar
        workspace.inspectorVisible = inspector
        workspace.toggleFocus()

        workspace.toggleInspector()
        #expect(!workspace.isFocused)
        #expect(workspace.sidebarVisibility == sidebar)
        #expect(workspace.inspectorVisible)

        workspace.toggleInspector()
        #expect(!workspace.inspectorVisible)
        #expect(workspace.sidebarVisibility == sidebar)

        workspace.toggleFocus()
        workspace.toggleFocus()
        #expect(!workspace.inspectorVisible)
        #expect(workspace.sidebarVisibility == sidebar)
      }
    }
  }

  @Test(
    "Native inspector resizes and collapses without replacing the preview at minimum window size")
  func hostedInspectorPreservesPreview() async throws {
    let identifier = "fsc-workspace-layout-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: identifier))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
    defer {
      preferences.removePersistentDomain(forName: identifier)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let input = directory.appendingPathComponent("layout.png")
    // Large enough to pan at 200%, with no private scan or optional RAW corpus.
    let pixels: [UInt16] = (0..<2_880_000).map { channelIndex in
      let index: Int = channelIndex / 3
      let x: Int = index % 1_200
      let y: Int = index / 1_200
      let horizontal: Int = x * 30
      let vertical: Int = y * 10
      let sample: Int = 10_000 + horizontal + vertical
      return UInt16(sample)
    }
    try UInt16Image(width: 1_200, height: 800, channels: 3, pixels: pixels)
      .write(to: input, format: .png, parameters: ExportParameters())
    let model = AppModel(
      profileStore: ProfileStore(baseDirectory: directory.appendingPathComponent("profiles")),
      settingsStore: PerFileSettingsStore(
        baseDirectory: directory.appendingPathComponent("settings")),
      preferences: preferences)
    let workspace = WorkspaceLayout()
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: CGRect(x: -10_000, y: -10_000, width: 980, height: 640),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let hosting = NSHostingView(
      rootView: AnyView(
        ContentView(model: model, camera: CameraController(), workspace: workspace)
          .frame(minWidth: 980, minHeight: 640)
          // Offscreen windows cannot drive AppKit presentation animations. Test
          // settled native geometry while keeping the production view intact.
          .transaction { $0.disablesAnimations = true }))
    window.contentView = hosting
    window.setContentSize(CGSize(width: 980, height: 640))
    window.makeKeyAndOrderFront(nil)
    defer {
      hosting.rootView = AnyView(EmptyView())
      window.contentView = nil
      window.close()
      model.selection = nil
      model.loadSelection()
    }
    model.importFiles([input])
    try await waitUntil("native preview and inspector") {
      hosting.layoutSubtreeIfNeeded()
      guard !model.isLoading, !model.isRendering,
        let preview = descendants(of: hosting, as: PreviewScrollView.self).first
      else { return false }
      return inspectorSplit(in: hosting, preview: preview) != nil
    }
    let preview = try #require(descendants(of: hosting, as: PreviewScrollView.self).first)
    let inspector = try #require(inspectorSplit(in: hosting, preview: preview))
    #expect(abs(hosting.bounds.width - 980) < 2)
    #expect(abs(hosting.bounds.height - 640) < 2)
    #expect(preview.frame.width >= 180)
    #expect(preview.frame.height >= 400)

    inspector.setPosition(
      inspector.bounds.width - inspector.dividerThickness - 345, ofDividerAt: 0)
    inspector.adjustSubviews()
    try await waitUntil(
      "resized inspector", diagnostic: { splitDescription(inspector) },
      ready: {
        hosting.layoutSubtreeIfNeeded()
        return abs(inspector.arrangedSubviews[1].frame.width - 345) < 2
      })
    let inspectorWidth = inspector.arrangedSubviews[1].frame.width
    let initialPreviewWidth = preview.frame.width

    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveMagnifyNotification, object: preview)
    preview.setMagnification(2, centeredAt: CGPoint(x: 600, y: 350))
    NotificationCenter.default.post(
      name: NSScrollView.didEndLiveMagnifyNotification, object: preview)
    let initialVisible = preview.documentVisibleRect
    #expect(initialVisible.minX > 0)

    workspace.toggleInspector()
    try await waitUntil("hidden inspector") {
      hosting.layoutSubtreeIfNeeded()
      return preview.frame.width > initialPreviewWidth + 300
    }
    #expect(descendants(of: hosting, as: PreviewScrollView.self).first === preview)
    #expect(preview.magnification == 2)

    workspace.toggleInspector()
    try await waitUntil("restored inspector width") {
      hosting.layoutSubtreeIfNeeded()
      guard let restored = inspectorSplit(in: hosting, preview: preview) else { return false }
      return abs(restored.arrangedSubviews[1].frame.width - inspectorWidth) < 2
        && abs(preview.frame.width - initialPreviewWidth) < 2
    }
    #expect(descendants(of: hosting, as: PreviewScrollView.self).first === preview)
    #expect(preview.magnification == 2)
    #expect(abs(preview.documentVisibleRect.minX - initialVisible.minX) < 2)
    #expect(abs(preview.documentVisibleRect.minY - initialVisible.minY) < 2)

    workspace.toggleFocus()
    try await waitUntil("hidden side panels") {
      hosting.layoutSubtreeIfNeeded()
      return preview.frame.width > 950
    }
    #expect(descendants(of: hosting, as: PreviewScrollView.self).first === preview)
    #expect(preview.magnification == 2)
    workspace.toggleFocus()
    try await waitUntil("restored side panels") {
      hosting.layoutSubtreeIfNeeded()
      return abs(preview.frame.width - initialPreviewWidth) < 2
    }
    #expect(descendants(of: hosting, as: PreviewScrollView.self).first === preview)
    #expect(preview.magnification == 2)
    #expect(abs(preview.documentVisibleRect.minX - initialVisible.minX) < 2)
    #expect(abs(preview.documentVisibleRect.minY - initialVisible.minY) < 2)

    if let path = ProcessInfo.processInfo.environment["FSC_WORKSPACE_LAYOUT_CAPTURE_PATH"] {
      let captureURL = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(
        at: captureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
      hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: captureURL)
    }
    try await model.flushSettings()
  }

  private func inspectorSplit(in root: NSView, preview: PreviewScrollView) -> NSSplitView? {
    descendants(of: root, as: NSSplitView.self).last { split in
      guard split.isVertical, split.arrangedSubviews.count == 2,
        preview.isDescendant(of: split.arrangedSubviews[0])
      else { return false }
      let width = split.arrangedSubviews[1].frame.width
      return width >= 338 && width <= 522
    }
  }

  private func descendants<View: NSView>(of root: NSView, as type: View.Type) -> [View] {
    ((root as? View).map { [$0] } ?? [])
      + root.subviews.flatMap { descendants(of: $0, as: type) }
  }

  private func splitDescription(_ split: NSSplitView) -> String {
    let panes = split.arrangedSubviews.enumerated().map { index, pane in
      "pane \(index) frame=\(pane.frame) constraints=\(pane.constraintsAffectingLayout(for: .horizontal))"
    }
    let items =
      (split.delegate as? NSSplitViewController)?.splitViewItems.map { item in
        "item min=\(item.minimumThickness) max=\(item.maximumThickness) holding=\(item.holdingPriority) collapsed=\(item.isCollapsed)"
      } ?? []
    return
      ([
        "split frame=\(split.frame) bounds=\(split.bounds) delegate=\(String(describing: split.delegate))",
        "divider range=\(split.minPossiblePositionOfDivider(at: 0))...\(split.maxPossiblePositionOfDivider(at: 0))",
      ] + panes + items).joined(separator: "\n")
  }

  private func waitUntil(
    _ description: String, diagnostic: () -> String = { "" }, ready: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !ready() {
      try #require(
        ContinuousClock.now < deadline,
        "Timed out waiting for \(description). \(diagnostic())")
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}
