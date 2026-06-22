import FilmScanEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var camera: CameraController
  @State private var dropTargeted = false
  @State private var showLivePreview = false
  @State private var inspectorPage: InspectorPage = .edit
  @State private var isPickingRebateRegion = false
  @State private var rebateDragStart: CGPoint?
  @State private var rebateDragEnd: CGPoint?
  @State private var rebateSelectionPreviousShowOriginal = false
  @State private var presetName = ""

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
          if model.selection == url && (model.isLoading || model.isRendering) {
            ProgressView()
              .controlSize(.mini)
              .frame(width: 16, height: 16)
          }
          Spacer(minLength: 4)
          if !(model.selection == url && (model.isLoading || model.isRendering)),
            model.hasCachedPreview(for: url)
          {
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
        endRebateSelection()
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
        HStack(spacing: 6) {
          Text(showLivePreview ? camera.status : model.status)
            .foregroundStyle(model.status.contains("Unable") ? .red : model.status.contains("error") ? .red : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .font(.caption)
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
        .disabled(isPickingRebateRegion)
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
      .scrollBounceBehavior(.basedOnSize)
    }
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var editInspector: some View {
    Group {
      InspectorSection("Settings", systemImage: "slider.horizontal.2.square") {
        HStack {
          Button(action: model.copyCorrectionSettings) {
            Label("Copy", systemImage: "doc.on.doc")
          }
          Button(action: model.pasteCorrectionSettings) {
            Label("Paste", systemImage: "doc.on.clipboard")
          }
          .disabled(!model.canPasteCorrectionSettings)
        }
        .controlSize(.small)

        HStack {
          TextField("Preset name", text: $presetName)
            .textFieldStyle(.roundedBorder)
            .onSubmit(saveNamedPreset)
          Button("Save", action: saveNamedPreset)
            .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .controlSize(.small)

        if !model.namedCorrectionPresets.isEmpty {
          VStack(spacing: 4) {
            ForEach(model.namedCorrectionPresets) { preset in
              HStack {
                Button(preset.name) {
                  model.applyCorrectionPreset(preset)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Apply \(preset.name)")
                Button(role: .destructive) {
                  model.deleteCorrectionPreset(preset)
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Delete \(preset.name)")
              }
              .font(.caption)
            }
          }
        }

        if !model.settingsStatus.isEmpty {
          Text(model.settingsStatus)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

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
              AdjustmentSlider(
                "Red Ratio",
                value: Binding(
                  get: { fn.redRatio },
                  set: { model.setFilmNegativeRedRatio($0) }
                ),
                range: 0.8...1.8, neutral: FilmNegativeParams.colourNegative.redRatio,
                valueFormat: "%.3f"
              )
              AdjustmentSlider(
                "Green Exponent",
                value: Binding(
                  get: { fn.greenExp },
                  set: { model.setFilmNegativeGreenExp($0) }
                ),
                range: 1.0...2.0, neutral: 1.5, valueFormat: "%.3f"
              )
              AdjustmentSlider(
                "Blue Ratio",
                value: Binding(
                  get: { fn.blueRatio },
                  set: { model.setFilmNegativeBlueRatio($0) }
                ),
                range: 0.6...1.4, neutral: FilmNegativeParams.colourNegative.blueRatio,
                valueFormat: "%.3f"
              )
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
        AdjustmentSlider(
          "Exposure",
          value: Binding(
            get: { model.parameters.photoAdjustments.exposureEV },
            set: { model.setExposureEV($0) }
          ),
          range: -4...4, neutral: 0, valueFormat: "%.2f", unitSuffix: "EV"
        )
        AdjustmentSlider(
          "Brightness",
          value: Binding(
            get: { model.parameters.photoAdjustments.brightness },
            set: { model.setBrightness($0) }
          ),
          range: -1...1, neutral: 0, valueFormat: "%.3f"
        )
        AdjustmentSlider(
          "Contrast",
          value: Binding(
            get: { model.parameters.photoAdjustments.contrast },
            set: { model.setContrast($0) }
          ),
          range: -1...1, neutral: 0, valueFormat: "%.3f"
        )
        AdjustmentSlider(
          "Highlights",
          value: Binding(
            get: { model.parameters.photoAdjustments.highlights },
            set: { model.setSemanticHighlights($0) }
          ),
          range: -1...1, neutral: 0, valueFormat: "%.3f"
        )
        AdjustmentSlider(
          "Shadows",
          value: Binding(
            get: { model.parameters.photoAdjustments.shadows },
            set: { model.setSemanticShadows($0) }
          ),
          range: -1...1, neutral: 0, valueFormat: "%.3f"
        )
      }
      .disabled(!model.parameters.filmType.supportsToneCorrections)

      InspectorSection("Color", systemImage: "thermometer.medium") {
        AdjustmentSlider(
          "Temperature",
          value: Binding(
            get: { Double(model.parameters.temperature) },
            set: { model.setTemperature(Int($0.rounded())) }
          ),
          range: -100...100, neutral: 0, valueFormat: "%.0f", step: 1
        )
        AdjustmentSlider(
          "Tint",
          value: Binding(
            get: { Double(model.parameters.tint) },
            set: { model.setTint(Int($0.rounded())) }
          ),
          range: -100...100, neutral: 0, valueFormat: "%.0f", step: 1
        )
        AdjustmentSlider(
          "Saturation",
          value: Binding(
            get: { Double(model.parameters.saturation - 100) },
            set: { model.setSaturation(Int($0.rounded()) + 100) }
          ),
          range: -100...100, neutral: 0, valueFormat: "%.0f", step: 1
        )
        AdjustmentSlider(
          "Vibrance",
          value: Binding(
            get: { model.parameters.photoAdjustments.vibrance },
            set: { model.setVibrance($0) }
          ),
          range: -1...1, neutral: 0, valueFormat: "%.3f"
        )
      }
      .disabled(!model.parameters.filmType.supportsColorCorrections)

      InspectorSection("Film Base", systemImage: "viewfinder") {
        HStack {
          Button(action: model.loadFlatField) {
            Label("Flat Field", systemImage: "rectangle.split.1x2")
          }
          .controlSize(.small)
          if model.flatFieldURL != nil {
            Button(action: model.clearFlatField) {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .controlSize(.small)
          }
          Spacer()
          if let ffURL = model.flatFieldURL {
            Text(ffURL.lastPathComponent)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Text("Film base is the clear, unexposed film edge outside the photographed frame. Measuring it removes the orange mask from colour negatives.")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Button(action: model.detectRebate) {
          if model.isRebateDetectionRunning {
            HStack {
              ProgressView()
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
              Text("Detecting...")
            }
          } else {
            Label("Find Unexposed Film Edge", systemImage: "viewfinder")
          }
        }
        .disabled(
          model.decodedImage == nil || model.isRebateDetectionRunning
            || !supportsFilmNegative(filmType: model.parameters.filmType))

        Button {
          if isPickingRebateRegion {
            endRebateSelection()
          } else {
            rebateSelectionPreviousShowOriginal = model.showOriginal
            model.showOriginal = true
            isPickingRebateRegion = true
            rebateDragStart = nil
            rebateDragEnd = nil
          }
        } label: {
          Label(
            isPickingRebateRegion ? "Cancel Film Base Selection" : "Select Film Base Area",
            systemImage: isPickingRebateRegion ? "xmark" : "rectangle.dashed"
          )
        }
        .controlSize(.small)
        .disabled(model.decodedImage == nil)

        if isPickingRebateRegion {
          Text("Drag over a clear, unexposed strip of film—not the picture area.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        if !model.rebateCandidates.isEmpty {
          VStack(alignment: .leading, spacing: 2) {
            Text("Possible unexposed edges:")
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

      InspectorSection("Film Frame", systemImage: "crop") {
        AdjustmentSlider(
          "Dark",
          value: Binding(
            get: { Double(model.parameters.darkThreshold) },
            set: { model.setDarkThreshold(Int($0.rounded())) }
          ),
          range: 0...100, neutral: 25, valueFormat: "%.0f", unitSuffix: "%", step: 1
        )
        AdjustmentSlider(
          "Light",
          value: Binding(
            get: { Double(model.parameters.lightThreshold) },
            set: { model.setLightThreshold(Int($0.rounded())) }
          ),
          range: 0...100, neutral: 100, valueFormat: "%.0f", unitSuffix: "%", step: 1
        )

        Button(action: model.detectCrop) {
          if model.isCropDetectionRunning {
            HStack {
              ProgressView()
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
              Text("Detecting...")
            }
          } else {
            Label("Detect Frame", systemImage: "crop.rotate")
          }
        }
        .disabled(model.decodedImage == nil || model.isCropDetectionRunning)

        if let cropRect = model.cropRect {
          Divider()
          VStack(alignment: .leading, spacing: 2) {
            Text("Angle: \(String(format: "%.1f", cropRect.angle))°")
              .font(.caption2)
            Text("Size: \(String(format: "%.3f", cropRect.width)) × \(String(format: "%.3f", cropRect.height))")
              .font(.caption2)
            Text("Center: (\(String(format: "%.3f", cropRect.centerX)), \(String(format: "%.3f", cropRect.centerY)))")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          Button("Clear") { model.clearCrop() }
            .controlSize(.small)
            .font(.caption2)
        }

        if !model.cropStatus.isEmpty && model.cropRect == nil && !model.isCropDetectionRunning {
          Text(model.cropStatus)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      if model.selectedRebateMeasurement != nil
        || model.rollProfile?.measuredBaseDensity != nil
      {
        InspectorSection("Density Pipeline", systemImage: "arrow.triangle.branch") {
          VStack(alignment: .leading, spacing: 6) {
            Toggle(
              "Use Measured Film Base",
              isOn: Binding(
                get: { model.parameters.densityPipelineEnabled },
                set: { model.setDensityPipelineEnabled($0) }
              )
            )
            .font(.callout)

            if model.parameters.densityPipelineEnabled,
              let baseDensity = model.parameters.densityBaseDensity
            {
              Text("Base: B \(String(format: "%.3f", baseDensity.blue))  G \(String(format: "%.3f", baseDensity.green))  R \(String(format: "%.3f", baseDensity.red))")
                .font(.caption2)
                .foregroundStyle(.secondary)
              Text(
                "C-41: slopes B\(String(format: "%.2f", model.parameters.densityC41Profile.densitySlope.blue)) G\(String(format: "%.2f", model.parameters.densityC41Profile.densitySlope.green)) R\(String(format: "%.2f", model.parameters.densityC41Profile.densitySlope.red))"
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
            }

            if model.parameters.densityPipelineEnabled {
              Text("This uses the measured film edge for inversion. Turn it off to compare with the basic negative conversion.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }

      Button(role: .destructive, action: model.resetCorrections) {
        Label("Reset All Adjustments", systemImage: "arrow.counterclockwise")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .disabled(model.decodedImage == nil)
    }
  }

  private func saveNamedPreset() {
    let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    model.saveCorrectionPreset(named: name)
    presetName = ""
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
          AdjustmentSlider(
            "JPEG Quality",
            value: Binding(
              get: { model.exportParameters.jpegQuality * 100 },
              set: { model.setJpegQuality($0 / 100) }
            ),
            range: 40...100, neutral: 95, valueFormat: "%.0f", unitSuffix: "%"
          )
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
        AdjustmentSlider(
          "Border",
          value: Binding(
            get: { Double(model.exportParameters.framePercent) },
            set: { model.setExportFramePercent(Int($0.rounded())) }
          ),
          range: 0...20, neutral: 0, valueFormat: "%.0f", unitSuffix: "%", step: 1
        )

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
    } else if model.selection != nil {
      ZStack {
        Color.black

        if let image = model.previewImage {
          Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          VStack(spacing: 16) {
            Text(model.selection?.lastPathComponent ?? "")
              .font(.callout)
              .foregroundStyle(.secondary)
            Text("Decoding image…")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }

        RebateRegionSelectionOverlay(
          isActive: isPickingRebateRegion,
          imageSize: model.previewImage?.size ?? .zero,
          dragStart: $rebateDragStart,
          dragEnd: $rebateDragEnd
        ) { x, y, width, height in
          model.measureRebateRegion(
            normalizedX: x,
            normalizedY: y,
            normalizedWidth: width,
            normalizedHeight: height
          )
          endRebateSelection()
        }
      }
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

  private func endRebateSelection() {
    guard isPickingRebateRegion else { return }
    isPickingRebateRegion = false
    rebateDragStart = nil
    rebateDragEnd = nil
    model.showOriginal = rebateSelectionPreviousShowOriginal
  }
}

private struct RebateRegionSelectionOverlay: View {
  let isActive: Bool
  let imageSize: CGSize
  @Binding var dragStart: CGPoint?
  @Binding var dragEnd: CGPoint?
  let onSelection: (Double, Double, Double, Double) -> Void

  var body: some View {
    GeometryReader { geometry in
      let imageRect = aspectFitRect(imageSize: imageSize, containerSize: geometry.size)
      ZStack {
        Color.clear
          .contentShape(Rectangle())
        if isActive, let dragStart, let dragEnd {
          Rectangle()
            .fill(Color.accentColor.opacity(0.15))
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(
              width: abs(dragEnd.x - dragStart.x),
              height: abs(dragEnd.y - dragStart.y)
            )
            .position(
              x: (dragStart.x + dragEnd.x) / 2,
              y: (dragStart.y + dragEnd.y) / 2
            )
        }
      }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let point = clamped(value.location, to: imageRect)
            if dragStart == nil {
              dragStart = point
            }
            dragEnd = point
          }
          .onEnded { value in
            guard let start = dragStart else { return }
            let end = clamped(value.location, to: imageRect)
            dragEnd = end
            let selection = CGRect(
              x: min(start.x, end.x),
              y: min(start.y, end.y),
              width: abs(end.x - start.x),
              height: abs(end.y - start.y)
            )
            guard selection.width >= 2, selection.height >= 2,
              imageRect.width > 0, imageRect.height > 0
            else { return }
            onSelection(
              Double((selection.minX - imageRect.minX) / imageRect.width),
              Double((selection.minY - imageRect.minY) / imageRect.height),
              Double(selection.width / imageRect.width),
              Double(selection.height / imageRect.height)
            )
          }
      )
      .allowsHitTesting(isActive)
    }
  }

  private func aspectFitRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
    let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(
      x: (containerSize.width - size.width) / 2,
      y: (containerSize.height - size.height) / 2,
      width: size.width,
      height: size.height
    )
  }

  private func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
    CGPoint(
      x: min(max(point.x, rect.minX), rect.maxX),
      y: min(max(point.y, rect.minY), rect.maxY)
    )
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
