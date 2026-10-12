import AppKit
import FilmScanEngine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    Task {
      do {
        try await model.flushSettings()
        sender.reply(toApplicationShouldTerminate: true)
      } catch {
        // Keep the changed settings in memory and let the user fix/retry saving.
        // The persistence failure is also reported in the app's status area.
        sender.reply(toApplicationShouldTerminate: false)
      }
    }
    return .terminateLater
  }
}

@main
struct FilmScanConverterMacApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model: AppModel
  @StateObject private var camera = CameraController()

  init() {
    FilmScanLog.configureLogDirectory()
    _model = State(
      initialValue: AppModel(
        settingsStore: PerFileSettingsStore(applicationName: "FilmScanConverter"),
        openRollStore: OpenRollStore(applicationName: "FilmScanConverter"),
        presetStore: NamedCorrectionPresetStore(applicationName: "FilmScanConverter")
      )
    )
  }

  var body: some Scene {
    WindowGroup {
      ContentView(model: model, camera: camera)
        .frame(minWidth: 980, minHeight: 640)
        .onAppear { appDelegate.model = model }
        .onOpenURL { url in
          model.importFiles([url])
        }
    }
    .defaultSize(width: 1320, height: 860)
    .commands {
      PreviewViewCommands()
      WorkspaceViewCommands()

      CommandGroup(after: .sidebar) {
        Button("Previous Scan") {
          model.selectAdjacentScan(offset: -1)
        }
        .keyboardShortcut(.upArrow, modifiers: [.option, .command])
        .disabled(!model.canSelectPreviousScan)
        .help("Move to the previous imported scan")

        Button("Next Scan") {
          model.selectAdjacentScan(offset: 1)
        }
        .keyboardShortcut(.downArrow, modifiers: [.option, .command])
        .disabled(!model.canSelectNextScan)
        .help("Move to the next imported scan")
      }

      CommandGroup(replacing: .undoRedo) {
        Button(model.undoMenuTitle) {
          model.undo()
        }
        .keyboardShortcut("z")
        .disabled(!model.canUndo)

        Button(model.redoMenuTitle) {
          model.redo()
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(!model.canRedo)
      }

      CommandGroup(after: .appInfo) {
        Button("Open Source Licenses…") {
          guard
            let noticesURL = Bundle.main.url(
              forResource: "THIRD_PARTY_NOTICES",
              withExtension: "md"
            )
          else { return }
          NSWorkspace.shared.open(noticesURL)
        }
        .disabled(
          Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") == nil
        )
      }

      CommandGroup(replacing: .newItem) {
        Button("Import Files...") {
          model.showImportPanel()
        }
        .keyboardShortcut("o")

        Button("Close All Scans") {
          model.closeAllScans()
        }
        .disabled(model.files.isEmpty || model.isExporting)

        Divider()

        Button("Choose Export Folder...") {
          model.showExportFolderPicker()
        }

        Button("Use Original Folders") {
          model.setExportDestinationDirectory(nil)
        }
        .disabled(model.exportParameters.destinationDirectory == nil)

        Button("Export Selected") {
          model.exportSelected()
        }
        .keyboardShortcut("e", modifiers: [.command])
        .disabled(
          model.selectedExportItemCount == 0 || model.isExporting || model.isLoading
            || model.isBuildingScanStack)

        Button("Export All") {
          model.exportAll()
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(
          model.files.isEmpty || model.isExporting || model.isLoading || model.isBuildingScanStack)

        Divider()

        Button("Export Selected Contact Sheet") { model.exportContactSheet() }
          .disabled(
            model.selectedExportItemCount == 0 || model.isExporting || model.isLoading
              || model.isBuildingScanStack)
        Button("Export All Contact Sheet") { model.exportContactSheet(allFiles: true) }
          .disabled(
            model.files.isEmpty || model.isExporting || model.isLoading || model.isBuildingScanStack
          )
      }

      CommandMenu("Corrections") {
        Button("Copy Correction Settings") {
          model.copyCorrectionSettings()
        }
        .keyboardShortcut("c", modifiers: [.command, .option])
        .disabled(model.selection == nil)

        Button("Paste Correction Settings") {
          model.pasteCorrectionSettings()
        }
        .keyboardShortcut("v", modifiers: [.command, .option])
        .disabled(model.selection == nil || !model.canPasteCorrectionSettings)

        Menu("Selective Sync & Paste") {
          ForEach(CorrectionAdjustmentGroup.allCases) { group in
            Toggle(
              group.title,
              isOn: Binding(
                get: { model.adjustmentTransferGroups.contains(group) },
                set: { isIncluded in
                  if isIncluded {
                    model.adjustmentTransferGroups.insert(group)
                  } else {
                    model.adjustmentTransferGroups.remove(group)
                  }
                }))
          }
          Button("Select All Groups") {
            model.adjustmentTransferGroups = CorrectionAdjustmentGroup.all
          }
          Button("Select No Groups") { model.adjustmentTransferGroups = [] }
          Divider()
          Button("Sync Selected Scans", action: model.syncSelectedAdjustmentsToSelectedFiles)
            .disabled(
              model.selection == nil || model.selectedFileCount < 2
                || model.adjustmentTransferGroups.isEmpty)
          Button("Sync All Open Scans", action: model.syncSelectedAdjustmentsToAllOpenFiles)
            .disabled(
              model.selection == nil || model.files.isEmpty
                || model.adjustmentTransferGroups.isEmpty)
          Divider()
          Button("Paste Selected Groups", action: model.pasteSelectedCorrectionSettings)
            .disabled(
              model.selection == nil || !model.canPasteCorrectionSettings
                || model.adjustmentTransferGroups.isEmpty)
          Button(
            "Paste Groups to Selected Scans",
            action: model.pasteSelectedCorrectionSettingsToSelectedFiles
          )
          .disabled(
            model.selectedFileCount == 0 || !model.canPasteCorrectionSettings
              || model.adjustmentTransferGroups.isEmpty)
          Button(
            "Paste Groups to All Open Scans",
            action: model.pasteSelectedCorrectionSettingsToAllOpenFiles
          )
          .disabled(
            model.files.isEmpty || !model.canPasteCorrectionSettings
              || model.adjustmentTransferGroups.isEmpty)
        }

        Divider()

        Button("Reset Adjustments") {
          model.resetDevelopAdjustments()
        }
        .disabled(model.selection == nil)

        Button("Reset Image and Framing") {
          model.resetCorrections()
        }
        .disabled(model.selection == nil)
      }
    }
  }
}
