import FilmScanEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var camera: CameraController
  @State private var dropTargeted = false
  @State private var showLivePreview = false
  @State private var inspectorPage: InspectorPage = .edit

  private enum InspectorPage: String, CaseIterable, Identifiable {
    case edit = "Edit"
    case grade = "Grade"
    case export = "Export"

    var id: Self { self }

    var systemImage: String {
      switch self {
      case .edit: "slider.horizontal.3"
      case .grade: "circle.lefthalf.filled"
      case .export: "square.and.arrow.up"
      }
    }
  }

  var body: some View {
    NavigationSplitView {
      List(model.files, id: \.self, selection: $model.selection) { url in
        HStack(spacing: 8) {
          Image(systemName: "photo")
            .foregroundStyle(.secondary)
          Text(url.lastPathComponent)
            .lineLimit(1)
          Spacer(minLength: 4)
          if model.hasCachedPreview(for: url) {
            Circle()
              .fill(Color.accentColor)
              .frame(width: 5, height: 5)
              .help("Ready to preview")
          }
        }
        .tag(url)
      }
      .navigationTitle("Scans")
      .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
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
              .frame(width: 390)
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
    HStack(spacing: 12) {
      Button(action: model.showImportPanel) {
        Label("Import", systemImage: "plus")
      }
      .keyboardShortcut("o")

      Divider()
        .frame(height: 18)

      Toggle("Live Camera", isOn: $showLivePreview)
        .toggleStyle(.button)
        .labelStyle(.titleAndIcon)
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

      if !showLivePreview, model.decodedImage != nil {
        Toggle(isOn: $model.showOriginal) {
          Label("Original", systemImage: "rectangle.on.rectangle")
        }
        .toggleStyle(.button)
        .help("Press and hold the comparison visually by toggling the original")

        Button(action: model.rotateCounterclockwise) {
          Image(systemName: "rotate.left")
        }
        .help("Rotate left")
        Button(action: model.rotateClockwise) {
          Image(systemName: "rotate.right")
        }
        .help("Rotate right")
        Button(action: model.toggleFlip) {
          Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
        }
        .help("Flip horizontally")
      }
    }
    .padding(10)
  }

  private var inspector: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(model.selection?.deletingPathExtension().lastPathComponent ?? "Adjustments")
              .font(.headline)
              .lineLimit(1)
            if let image = model.decodedImage {
              Text("\(image.width) × \(image.height)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
          if model.isRendering {
            ProgressView()
              .controlSize(.small)
              .help("Updating preview")
          }
        }

        Picker("Inspector", selection: $inspectorPage) {
          ForEach(InspectorPage.allCases) { page in
            Label(page.rawValue, systemImage: page.systemImage)
              .tag(page)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      .padding(14)

      Divider()

      ScrollView {
        VStack(spacing: 12) {
          switch inspectorPage {
          case .edit:
            editInspector
          case .grade:
            gradeInspector
          case .export:
            exportInspector
          }
        }
        .padding(12)
      }
    }
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var editInspector: some View {
    Group {
      InspectorSection("Film Setup", systemImage: "film.stack") {
        Picker(
          "Film Type",
          selection: Binding(
            get: { model.parameters.filmType },
            set: { model.setFilmType($0) }
          )
        ) {
          ForEach(FilmType.allCases, id: \.self) { type in
            Text(type.displayName).tag(type)
          }
        }
        Picker(
          "Negative Profile",
          selection: Binding(
            get: { filmNegativePreset(for: model.parameters) },
            set: { model.setFilmNegativePreset($0) }
          )
        ) {
          ForEach(FilmNegativePreset.allCases, id: \.self) { preset in
            Text(preset.displayName).tag(preset)
          }
        }
        .disabled(!supportsFilmNegative(filmType: model.parameters.filmType))

        if model.parameters.filmNegativeParams.enabled
          && supportsFilmNegative(filmType: model.parameters.filmType)
        {
          let fn = model.parameters.filmNegativeParams
          let rexp = -(fn.greenExp * fn.redRatio)
          let gexp = -fn.greenExp
          let bexp = -(fn.greenExp * fn.blueRatio)

          DisclosureGroup("Advanced profile tuning") {
            VStack(spacing: 10) {
              correctionDoubleSlider(
                "Red Ratio", value: { fn.redRatio }, range: 0.8...1.8,
                neutral: FilmNegativeParams.colourNegative.redRatio
              ) { model.setFilmNegativeRedRatio($0) }
              correctionDoubleSlider(
                "Green Exponent", value: { fn.greenExp }, range: 1.0...2.0,
                neutral: 1.5
              ) { model.setFilmNegativeGreenExp($0) }
              correctionDoubleSlider(
                "Blue Ratio", value: { fn.blueRatio }, range: 0.6...1.4,
                neutral: FilmNegativeParams.colourNegative.blueRatio
              ) { model.setFilmNegativeBlueRatio($0) }
            }
            .padding(.top, 8)
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
        }
      }

      InspectorSection("Light", systemImage: "sun.max") {
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
      .disabled(!model.parameters.filmType.supportsToneCorrections)

      InspectorSection("Color", systemImage: "thermometer.medium") {
        correctionSlider("Temperature", value: { model.parameters.temperature }, range: -100...100) {
          model.setTemperature($0)
        }
        correctionSlider("Tint", value: { model.parameters.tint }, range: -100...100) {
          model.setTint($0)
        }
        correctionSlider(
          "Saturation", value: { model.parameters.saturation - 100 }, range: -100...100
        ) {
          model.setSaturation($0 + 100)
        }
      }
      .disabled(!model.parameters.filmType.supportsColorCorrections)

      InspectorSection("Film Base", systemImage: "viewfinder") {
        Button(action: model.detectRebate) {
          if model.isRebateDetectionRunning {
            HStack {
              ProgressView()
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
              Text("Detecting...")
            }
          } else {
            Label("Detect Rebate", systemImage: "viewfinder")
          }
        }
        .disabled(
          model.decodedImage == nil || model.isRebateDetectionRunning
            || !supportsFilmNegative(filmType: model.parameters.filmType))

        if !model.rebateCandidates.isEmpty {
          VStack(alignment: .leading, spacing: 2) {
            Text("Candidates:")
              .font(.caption)
              .foregroundStyle(.secondary)
            ForEach(Array(model.rebateCandidates.enumerated()), id: \.offset) {
              _, candidate in
              Button {
                model.selectRebateCandidate(candidate)
              } label: {
                HStack {
                  Text(
                    "\(candidateDescription(candidate.region))  B\(String(format: "%.3f", candidate.measurement.baseDensity.blue))"
                  )
                  .font(.caption2)
                  Spacer()
                  Text("\(Int(candidate.confidence * 100))%")
                    .font(.caption2)
                    .foregroundStyle(
                      candidate.confidence > 0.7
                        ? .green : candidate.confidence > 0.45 ? .orange : .secondary)
                }
              }
              .buttonStyle(.plain)
              .padding(.horizontal, 4)
              .padding(.vertical, 2)
              .background(
                model.selectedRebateRegion == candidate.region
                  ? Color.accentColor.opacity(0.15) : Color.clear
              )
              .cornerRadius(4)
            }
          }
        }

        if let measurement = model.selectedRebateMeasurement {
          VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
              Text("Base Density")
                .font(.caption)
              Spacer()
              Button("Clear") {
                model.clearRebateMeasurement()
              }
              .font(.caption2)
            }
            densityRow("Blue", measurement.baseDensity.blue)
            densityRow("Green", measurement.baseDensity.green)
            densityRow("Red", measurement.baseDensity.red)
            Text(
              "Samples: \(measurement.sampleCount)  Rejected: \(Int(measurement.rejectedFraction * 100))%"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text("Confidence: \(Int(measurement.confidence * 100))%")
              .font(.caption2)
              .foregroundStyle(
                measurement.confidence > 0.7
                  ? .green : measurement.confidence > 0.45 ? .orange : .secondary)

            if let firstCandidate = model.rebateCandidates.first(where: {
              $0.measurement == measurement
            }) {
              Button {
                model.createRollProfile(from: firstCandidate)
              } label: {
                Label("Save Roll Profile", systemImage: "square.and.arrow.down")
              }
              .controlSize(.small)
            }
          }
        }

        if !model.rebateStatus.isEmpty
          && model.selectedRebateMeasurement == nil
          && !model.isRebateDetectionRunning
        {
          Text(model.rebateStatus)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .disabled(!supportsFilmNegative(filmType: model.parameters.filmType))
      Button(role: .destructive, action: model.resetCorrections) {
        Label("Reset All Adjustments", systemImage: "arrow.counterclockwise")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
    }
  }

  private var gradeInspector: some View {
    Group {
      InspectorSection("Tone Curve", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
        IntegratedCurvesView(model: model)
      }
      .disabled(!model.parameters.filmType.supportsColorCorrections)

      InspectorSection("Color Grading", systemImage: "circle.hexagongrid") {
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
      .disabled(!model.parameters.filmType.supportsColorCorrections)
    }
  }

  private var exportInspector: some View {
    Group {
      InspectorSection("File", systemImage: "doc") {
        Picker(
          "Format",
          selection: Binding(
            get: { model.exportParameters.format },
            set: { model.setExportFormat($0) }
          )
        ) {
          ForEach(ExportFormat.allCases, id: \.self) { format in
            Text(format.displayName).tag(format)
          }
        }
        .pickerStyle(.segmented)

        if model.exportParameters.format == .jpeg {
          correctionDoubleSlider(
            "JPEG Quality",
            value: { model.exportParameters.jpegQuality * 100 },
            range: 40...100,
            neutral: 95,
            valueFormat: "%.0f%%"
          ) { model.setJpegQuality($0 / 100) }
        }

        if model.exportParameters.format == .tiff {
          Picker(
            "Compression",
            selection: Binding(
              get: { model.exportParameters.tiffCompression },
              set: { model.setTiffCompression($0) }
            )
          ) {
            ForEach(TiffCompression.allCases, id: \.self) { compression in
              Text(compression.displayName).tag(compression)
            }
          }
        }
      }

      InspectorSection("Frame", systemImage: "aspectratio") {
        correctionSlider(
          "Border", value: { model.exportParameters.framePercent }, range: 0...20,
          neutral: 0, valueSuffix: "%"
        ) { model.setExportFramePercent($0) }

        Picker(
          "Aspect Ratio",
          selection: Binding(
            get: { exportAspectRatioID(model.exportParameters.aspectRatio) },
            set: { model.setExportAspectRatio(aspectRatio(for: $0)) }
          )
        ) {
          Text("Original").tag("original")
          Text("1:1").tag("1:1")
          Text("3:2").tag("3:2")
          Text("4:3").tag("4:3")
          Text("16:9").tag("16:9")
        }
      }

      InspectorSection("Destination", systemImage: "folder") {
        Button(action: model.showExportFolderPicker) {
          HStack {
            Image(systemName: "folder")
            Text(model.exportParameters.destinationDirectory?.lastPathComponent ?? "Choose Folder…")
              .lineLimit(1)
            Spacer()
          }
        }

        if model.isExporting {
          ProgressView(
            value: Double(model.exportProgressCurrent),
            total: Double(max(model.exportProgressTotal, 1))
          )
          Text("Exporting \(model.exportProgressCurrent) of \(model.exportProgressTotal)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack {
          Button("Export Selected", action: model.exportSelected)
            .buttonStyle(.borderedProminent)
          Button("Export All", action: model.exportAll)
            .buttonStyle(.bordered)
        }
        .disabled(model.exportParameters.destinationDirectory == nil || model.isExporting)

        ForEach(model.exportErrors, id: \.self) { error in
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
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
    neutral: Int = 0,
    valueSuffix: String = "",
    set: @escaping (Int) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title)
          .font(.callout)
        Spacer()
        Text("\(value() > 0 ? "+" : "")\(value().formatted())\(valueSuffix)")
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(minWidth: 42, alignment: .trailing)
        Button {
          set(neutral)
        } label: {
          Image(systemName: "arrow.counterclockwise")
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(value() == neutral ? .tertiary : .secondary)
        .disabled(value() == neutral)
        .help("Reset \(title)")
      }
      Slider(
        value: Binding(
          get: { Double(value()) },
          set: { set(Int($0.rounded())) }
        ),
        in: Double(range.lowerBound)...Double(range.upperBound),
        step: 1
      )
      .controlSize(.small)
      .onTapGesture(count: 2) { set(neutral) }
      .accessibilityValue(value().formatted() + valueSuffix)
    }
  }

  private func correctionDoubleSlider(
    _ title: String,
    value: @escaping () -> Double,
    range: ClosedRange<Double>,
    neutral: Double,
    valueFormat: String = "%.3f",
    set: @escaping (Double) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title)
          .font(.callout)
        Spacer()
        Text(String(format: valueFormat, value()))
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(minWidth: 46, alignment: .trailing)
        Button {
          set(neutral)
        } label: {
          Image(systemName: "arrow.counterclockwise")
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(abs(value() - neutral) < 0.000_001 ? .tertiary : .secondary)
        .disabled(abs(value() - neutral) < 0.000_001)
        .help("Reset \(title)")
      }
      Slider(
        value: Binding(
          get: { value() },
          set: { set($0) }
        ),
        in: range
      )
      .controlSize(.small)
      .onTapGesture(count: 2) { set(neutral) }
    }
  }

  private func exportAspectRatioID(_ ratio: AspectRatio?) -> String {
    guard let ratio else { return "original" }
    return "\(ratio.width):\(ratio.height)"
  }

  private func aspectRatio(for id: String) -> AspectRatio? {
    switch id {
    case "1:1": AspectRatio(width: 1, height: 1)
    case "3:2": AspectRatio(width: 3, height: 2)
    case "4:3": AspectRatio(width: 4, height: 3)
    case "16:9": AspectRatio(width: 16, height: 9)
    default: nil
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

  private func densityRow(_ label: String, _ value: Double) -> some View {
    HStack {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Spacer()
      Text(String(format: "%.3f", value))
        .font(.caption2)
        .monospacedDigit()
    }
  }

  private func candidateDescription(_ region: ImageRegion) -> String {
    if region.x == 0 && region.width > region.height {
      return region.y == 0 ? "Top" : "Bottom"
    }
    if region.y == 0 && region.height > region.width {
      return region.x == 0 ? "Left" : "Right"
    }
    return "x:\(region.x) y:\(region.y)"
  }
}

private struct InspectorSection<Content: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder let content: Content

  init(
    _ title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      Label(title, systemImage: systemImage)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
      content
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(nsColor: .windowBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
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
