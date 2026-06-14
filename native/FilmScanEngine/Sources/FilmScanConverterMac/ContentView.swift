import FilmScanEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var camera: CameraController
  @State private var dropTargeted = false
  @State private var showLivePreview = false

  var body: some View {
    NavigationSplitView {
      List(model.files, id: \.self, selection: $model.selection) { url in
        Text(url.lastPathComponent)
          .tag(url)
      }
      .navigationTitle("Scans")
      .onChange(of: model.selection) {
        model.loadSelection()
      }
    } detail: {
      VStack(spacing: 0) {
        toolbar
        Divider()
        preview
        Divider()
        Text(showLivePreview ? camera.status : model.status)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .foregroundStyle(.secondary)
      }
      .background(dropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
      .dropDestination(for: URL.self) { urls, _ in
        model.importFiles(urls)
        return !FileDropPolicy.supportedFiles(from: urls).isEmpty
      } isTargeted: { targeted in
        dropTargeted = targeted
      }
    }
  }

  private var toolbar: some View {
    HStack {
      Button("Import Files", action: model.showImportPanel)
      Toggle("Live Camera", isOn: $showLivePreview)
        .toggleStyle(.switch)
        .onChange(of: showLivePreview) {
          camera.toggle()
        }

      if showLivePreview {
        Toggle(
          "Invert Negative",
          isOn: Binding(
            get: { camera.invertNegative },
            set: camera.setInvertNegative
          )
        )
        Text("Exposure")
        Slider(
          value: Binding(
            get: { camera.exposure },
            set: camera.setExposure
          ),
          in: -3...3
        )
        .frame(width: 120)
        Text("Saturation")
        Slider(
          value: Binding(
            get: { camera.saturation },
            set: camera.setSaturation
          ),
          in: 0...2
        )
        .frame(width: 120)
      }
      Spacer()
    }
    .padding(10)
  }

  @ViewBuilder
  private var preview: some View {
    if showLivePreview, let image = camera.image {
      Image(decorative: image, scale: 1)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    } else if let image = model.previewImage {
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    } else {
      ContentUnavailableView {
        Label("Drop Film Scans Here", systemImage: "photo.on.rectangle.angled")
      } description: {
        Text("Supported RAW and image files start processing when dropped into this window.")
      } actions: {
        Button("Choose Files", action: model.showImportPanel)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
