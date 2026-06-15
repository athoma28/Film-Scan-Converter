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
        HStack(spacing: 0) {
          preview
          if !showLivePreview, model.decodedImage != nil {
            Divider()
            inspector
              .frame(width: 290)
          }
        }
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

  private var inspector: some View {
    Form {
      Section("Film") {
        Picker(
          "Type",
          selection: Binding(
            get: { model.parameters.filmType },
            set: { model.setFilmType($0) }
          )
        ) {
          ForEach(FilmType.allCases, id: \.self) { type in
            Text(type.displayName).tag(type)
          }
        }
        Toggle("Show Original", isOn: $model.showOriginal)
      }

      Section("Orientation") {
        HStack {
          Button(action: model.rotateCounterclockwise) {
            Label("Left", systemImage: "rotate.left")
          }
          Button(action: model.rotateClockwise) {
            Label("Right", systemImage: "rotate.right")
          }
          Button(action: model.toggleFlip) {
            Label(
              "Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
          }
        }
        .labelStyle(.iconOnly)
      }

      Section("Color") {
        correctionSlider("Temperature", value: { model.parameters.temperature }, range: -100...100) {
          model.setTemperature($0)
        }
        correctionSlider("Tint", value: { model.parameters.tint }, range: -100...100) {
          model.setTint($0)
        }
        correctionSlider("Saturation", value: { model.parameters.saturation }, range: 0...200) {
          model.setSaturation($0)
        }
      }

      Section("Tone") {
        correctionSlider("Gamma", value: { model.parameters.gamma }, range: -100...100) {
          model.setGamma($0)
        }
        correctionSlider("Shadows", value: { model.parameters.shadows }, range: -100...100) {
          model.setShadows($0)
        }
        correctionSlider("Highlights", value: { model.parameters.highlights }, range: -100...100) {
          model.setHighlights($0)
        }
      }

      Button("Reset Corrections", role: .destructive, action: model.resetCorrections)
        .frame(maxWidth: .infinity)
    }
    .formStyle(.grouped)
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

  private func correctionSlider(
    _ title: String,
    value: @escaping () -> Int,
    range: ClosedRange<Int>,
    set: @escaping (Int) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(value().formatted())
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Slider(
        value: Binding(
          get: { Double(value()) },
          set: { set(Int($0.rounded())) }
        ),
        in: Double(range.lowerBound)...Double(range.upperBound)
      )
    }
  }
}

extension FilmType {
  fileprivate var displayName: String {
    switch self {
    case .blackAndWhiteNegative: "B&W Negative"
    case .colourNegative: "Color Negative"
    case .slide: "Slide"
    case .cropOnly: "Original"
    }
  }
}
