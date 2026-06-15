import FilmScanEngine
import SwiftUI

@main
struct FilmScanConverterMacApp: App {
  @StateObject private var model = AppModel()
  @StateObject private var camera = CameraController()

  init() {
    FilmScanLog.configureLogDirectory()
  }

  var body: some Scene {
    WindowGroup {
      ContentView(model: model, camera: camera)
        .frame(minWidth: 980, minHeight: 640)
    }
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("Import Files...") {
          model.showImportPanel()
        }
        .keyboardShortcut("o")
      }
    }
  }
}
