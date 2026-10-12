import SwiftUI

/// Window-local layout. Focus mode restores the panel arrangement it replaced.
@Observable
final class WorkspaceLayout {
  var sidebarVisibility: NavigationSplitViewVisibility = .all
  var inspectorVisible = true
  private var previousPanels: (NavigationSplitViewVisibility, Bool)?

  var isFocused: Bool { previousPanels != nil }

  func toggleFocus() {
    if let previousPanels {
      sidebarVisibility = previousPanels.0
      inspectorVisible = previousPanels.1
      self.previousPanels = nil
    } else {
      previousPanels = (sidebarVisibility, inspectorVisible)
      sidebarVisibility = .detailOnly
      inspectorVisible = false
    }
  }

  func toggleInspector() {
    if isFocused {
      toggleFocus()
      inspectorVisible = true
    } else {
      inspectorVisible.toggle()
    }
  }
}

struct WorkspaceCommands {
  let isFocused: Bool
  let inspectorVisible: Bool
  let canInspect: Bool
  let toggleFocus: () -> Void
  let toggleInspector: () -> Void
}

private struct WorkspaceCommandsKey: FocusedValueKey {
  typealias Value = WorkspaceCommands
}

extension FocusedValues {
  var workspaceCommands: WorkspaceCommands? {
    get { self[WorkspaceCommandsKey.self] }
    set { self[WorkspaceCommandsKey.self] = newValue }
  }
}

struct WorkspaceViewCommands: Commands {
  @FocusedValue(\.workspaceCommands) private var workspace

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Button(workspace?.inspectorVisible == true ? "Hide Inspector" : "Show Inspector") {
        workspace?.toggleInspector()
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
      .disabled(workspace?.canInspect != true)

      Button(workspace?.isFocused == true ? "Restore Side Panels" : "Hide Side Panels") {
        workspace?.toggleFocus()
      }
      .keyboardShortcut("f", modifiers: [.command, .shift])
      .disabled(workspace == nil)
    }
  }
}
