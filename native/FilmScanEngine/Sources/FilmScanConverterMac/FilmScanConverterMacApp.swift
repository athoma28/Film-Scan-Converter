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
        .disabled(model.selection == nil || model.exportParameters.destinationDirectory == nil || model.isExporting)

        Button("Export All") {
          model.exportAll()
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(model.files.isEmpty || model.exportParameters.destinationDirectory == nil || model.isExporting)
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
