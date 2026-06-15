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
              .frame(width: 410)
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

      Section("Film Negative") {
        Picker(
          "Preset",
          selection: Binding(
            get: { filmNegativePreset(for: model.parameters) },
            set: { model.setFilmNegativePreset($0) }
          )
        ) {
          ForEach(FilmNegativePreset.allCases, id: \.self) { preset in
            Text(preset.displayName).tag(preset)
          }
        }

        if model.parameters.filmNegativeParams.enabled
          && supportsFilmNegative(filmType: model.parameters.filmType)
        {
          let fn = model.parameters.filmNegativeParams
          let rexp = -(fn.greenExp * fn.redRatio)
          let gexp = -fn.greenExp
          let bexp = -(fn.greenExp * fn.blueRatio)

          correctionDoubleSlider("Red Ratio", value: { fn.redRatio }, range: 0.5...2.5) {
            model.setFilmNegativeRedRatio($0)
          }
          correctionDoubleSlider("Green Exponent", value: { fn.greenExp }, range: 0.5...3.0) {
            model.setFilmNegativeGreenExp($0)
          }
          correctionDoubleSlider("Blue Ratio", value: { fn.blueRatio }, range: 0.5...2.5) {
            model.setFilmNegativeBlueRatio($0)
          }

          VStack(alignment: .leading, spacing: 2) {
            Text(
              "Exponents: R \(String(format: "%.2f", rexp))  G \(String(format: "%.2f", gexp))  B \(String(format: "%.2f", bexp))"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            if let medians = fn.measuredMedians {
              Text(
                "Medians: R \(Int(medians.red))  G \(Int(medians.green))  B \(Int(medians.blue))"
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
            }
          }
        } else if model.parameters.filmNegativeParams.enabled {
          Text("Film negative is only supported for Color Negative and B&W Negative film types.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .disabled(!supportsFilmNegative(filmType: model.parameters.filmType))

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

      Section("Curves") {
        IntegratedCurvesView(model: model)
      }

      Section("Color Wheels") {
        HStack(alignment: .top, spacing: 12) {
          ColorWheelControl(
            title: "Shadows",
            hue: model.parameters.shadowWheel.hue,
            strength: model.parameters.shadowWheel.strength,
            setHue: model.setShadowWheelHue,
            setStrength: model.setShadowWheelStrength
          )
          ColorWheelControl(
            title: "Midtones",
            hue: model.parameters.midtoneWheel.hue,
            strength: model.parameters.midtoneWheel.strength,
            setHue: model.setMidtoneWheelHue,
            setStrength: model.setMidtoneWheelStrength
          )
          ColorWheelControl(
            title: "Highlights",
            hue: model.parameters.highlightWheel.hue,
            strength: model.parameters.highlightWheel.strength,
            setHue: model.setHighlightWheelHue,
            setStrength: model.setHighlightWheelStrength
          )
        }
        Text("Drag from center to tint. Double-click a wheel to reset.")
          .font(.caption2)
          .foregroundStyle(.secondary)
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

  private func correctionDoubleSlider(
    _ title: String,
    value: @escaping () -> Double,
    range: ClosedRange<Double>,
    set: @escaping (Double) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(String(format: "%.3f", value()))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Slider(
        value: Binding(
          get: { value() },
          set: { set($0) }
        ),
        in: range
      )
    }
  }

  private func filmNegativePreset(for params: ProcessingParameters) -> FilmNegativePreset {
    guard params.filmNegativeParams.enabled else { return .off }
    let fn = params.filmNegativeParams
    if fn.redRatio == FilmNegativeParams.colourNegative.redRatio
      && fn.greenExp == FilmNegativeParams.colourNegative.greenExp
      && fn.blueRatio == FilmNegativeParams.colourNegative.blueRatio
    {
      return .colourNegative
    }
    if fn.redRatio == FilmNegativeParams.blackAndWhite.redRatio
      && fn.greenExp == FilmNegativeParams.blackAndWhite.greenExp
      && fn.blueRatio == FilmNegativeParams.blackAndWhite.blueRatio
    {
      return .blackAndWhite
    }
    return .off
  }

  private func supportsFilmNegative(filmType: FilmType) -> Bool {
    filmType == .colourNegative || filmType == .blackAndWhiteNegative
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
