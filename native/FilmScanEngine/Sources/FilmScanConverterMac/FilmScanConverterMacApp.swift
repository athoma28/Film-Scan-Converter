import FilmScanEngine
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}

@main
struct FilmScanConverterMacApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model: AppModel
  @StateObject private var camera = CameraController()

  init() {
    FilmScanLog.configureLogDirectory()
    _model = StateObject(
      wrappedValue: AppModel(
        settingsStore: PerFileSettingsStore(applicationName: "FilmScanConverter"),
        presetStore: NamedCorrectionPresetStore(applicationName: "FilmScanConverter")
      )
    )
  }

  var body: some Scene {
    WindowGroup {
      ContentView(model: model, camera: camera)
        .frame(minWidth: 980, minHeight: 640)
        .onOpenURL { url in
          model.importFiles([url])
        }
    }
    .commands {
      PreviewViewCommands()

      CommandGroup(after: .appInfo) {
        Button("Open Source Licenses…") {
          guard let noticesURL = Bundle.main.url(
            forResource: "THIRD_PARTY_NOTICES",
            withExtension: "md"
          ) else { return }
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

        Divider()

        Button("Choose Export Folder...") {
          model.showExportFolderPicker()
        }

        Button("Export Selected") {
          model.exportSelected()
        }
        .keyboardShortcut("e", modifiers: [.command])
        .disabled(
          model.selection == nil || model.exportParameters.destinationDirectory == nil
            || model.isExporting || model.isLoading)

        Button("Export All") {
          model.exportAll()
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(
          model.files.isEmpty || model.exportParameters.destinationDirectory == nil
            || model.isExporting || model.isLoading)
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

        Divider()

        Button("Reset Corrections") {
          model.resetCorrections()
        }
        .disabled(model.selection == nil)
      }
    }
  }
}
