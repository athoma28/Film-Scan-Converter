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
  @State private var isPerspectiveEditing = false
  @State private var perspectiveEditingPreviousShowOriginal = false
  @State private var isStraightening = false
  @State private var isCropping = false
  @State private var presetName = ""
  @State private var profileName = ""

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
          if model.hasCachedPreview(for: url) {
            Image(systemName: "bolt.fill")
              .foregroundStyle(.secondary)
              .font(.caption2)
              .help("Ready to preview")
          }
          if model.hasEdits(for: url) {
            Image(systemName: "slider.horizontal.3")
              .foregroundStyle(Color.accentColor)
              .font(.caption2)
              .help("Edited")
          }
        }
        .tag(url)
      }
      .navigationTitle("Scans")
      .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
      .onChange(of: model.selection) {
        endRebateSelection()
        endPerspectiveEditing()
        endStraightening()
        endCropping()
        model.loadSelection()
      }
    } detail: {
      VStack(spacing: 0) {
        toolbar
        Divider()
        HStack(spacing: 0) {
          preview
          if !showLivePreview, model.previewImage != nil {
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
    HStack(spacing: 10) {
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
        .toggleStyle(.switch)

        ToolbarSlider(
          "Exposure",
          value: Binding(
            get: { Double(camera.exposure) },
            set: { camera.setExposure(Float($0)) }
          ),
          range: -3...3
        )
        ToolbarSlider(
          "Saturation",
          value: Binding(
            get: { Double(camera.saturation) },
            set: { camera.setSaturation(Float($0)) }
          ),
          range: 0...2
        )
      }
      Spacer()

      if !showLivePreview, model.previewImage != nil {
        Toggle(isOn: $model.showOriginal) {
          Label("Original", systemImage: "rectangle.on.rectangle")
        }
        .toggleStyle(.button)
        .disabled(isPickingRebateRegion)
        .help("Press and hold the comparison visually by toggling the original")

        HStack(spacing: 4) {
          Button(action: model.rotateCounterclockwise) {
            Image(systemName: "rotate.left")
              .frame(width: 18)
          }
          .help("Rotate left")
          Button(action: model.rotateClockwise) {
            Image(systemName: "rotate.right")
              .frame(width: 18)
          }
          .help("Rotate right")
          Button(action: model.toggleFlip) {
            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
              .frame(width: 18)
          }
          .help("Flip horizontally")
        }
      }
    }
    .controlSize(.small)
    .buttonStyle(.bordered)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
  }

  private var inspector: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(model.selection?.deletingPathExtension().lastPathComponent ?? "Adjustments")
              .font(.headline)
              .lineLimit(1)
            if let dimensions = model.selectedOutputDimensions {
              Text("Full output \(dimensions.width) × \(dimensions.height) px")
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

      ZStack {
        inspectorPageView(.edit, content: editInspector)
        inspectorPageView(.grade, content: gradeInspector)
        inspectorPageView(.export, content: exportInspector)
      }
    }
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private func inspectorPageView<Content: View>(
    _ page: InspectorPage, content: Content
  ) -> some View {
    ScrollView {
      VStack(spacing: 10) { content }
        .padding(12)
    }
    .scrollBounceBehavior(.basedOnSize)
    .opacity(inspectorPage == page ? 1 : 0)
    .allowsHitTesting(inspectorPage == page)
    .accessibilityHidden(inspectorPage != page)
  }

  private var editInspector: some View {
    Group {
      InspectorSection("Settings", systemImage: "slider.horizontal.2.square") {
        HStack(spacing: 8) {
          Button(action: model.copyCorrectionSettings) {
            Label("Copy", systemImage: "doc.on.doc")
          }
          Button(action: model.pasteCorrectionSettings) {
            Label("Paste", systemImage: "doc.on.clipboard")
          }
          .disabled(!model.canPasteCorrectionSettings)
        }

        Button("Apply Settings to All Open Files", action: model.applyCurrentSettingsToAllOpenFiles)

        Picker(
          "Files kept ready",
          selection: Binding(
            get: { model.previewCacheLimit },
            set: { model.setPreviewCacheLimit($0) }
          )
        ) {
          ForEach([2, 4, 8, 16, 32], id: \.self) { count in
            Text("\(count)").tag(count)
          }
        }
        .help("Higher values use substantially more memory but make file switching faster.")

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
                valueFormat: "%.3f", responseExponent: 1.5
              )
              AdjustmentSlider(
                "Green Exponent",
                value: Binding(
                  get: { fn.greenExp },
                  set: { model.setFilmNegativeGreenExp($0) }
                ),
                range: 1.0...2.0, neutral: 1.5, valueFormat: "%.3f",
                responseExponent: 1.5
              )
              AdjustmentSlider(
                "Blue Ratio",
                value: Binding(
                  get: { fn.blueRatio },
                  set: { model.setFilmNegativeBlueRatio($0) }
                ),
                range: 0.6...1.4, neutral: FilmNegativeParams.colourNegative.blueRatio,
                valueFormat: "%.3f", responseExponent: 1.5
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
          range: -1...1, neutral: 0, valueFormat: "%.3f", responseExponent: 1.6
        )
        AdjustmentSlider(
          "Contrast",
          value: Binding(
            get: { model.parameters.photoAdjustments.contrast },
            set: { model.setContrast($0) }
          ),
          range: -1...1, neutral: 0, valueFormat: "%.3f", responseExponent: 1.6
        )
        AdjustmentSlider(
          "Highlights",
          value: Binding(
            get: { model.parameters.photoAdjustments.highlights },
            set: { model.setSemanticHighlights($0) }
          ),
          range: -1...1, neutral: 0, valueFormat: "%.3f", responseExponent: 1.6
        )
        AdjustmentSlider(
          "Shadows",
          value: Binding(
            get: { model.parameters.photoAdjustments.shadows },
            set: { model.setSemanticShadows($0) }
          ),
          range: -1...1, neutral: 0, valueFormat: "%.3f", responseExponent: 1.6
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
          range: -1...1, neutral: 0, valueFormat: "%.3f", responseExponent: 1.6
        )
      }
      .disabled(!model.parameters.filmType.supportsColorCorrections)

      InspectorSection("Processing Profiles", systemImage: "square.stack.3d.up") {
        Picker("Capture", selection: $model.selectedCaptureProfileID) {
          ForEach(model.availableCaptureProfiles, id: \.id) { profile in
            Text(profile.id.rawValue).tag(profile.id)
          }
        }
        Picker("Film Stock", selection: $model.selectedFilmStockProfileID) {
          ForEach(model.availableFilmStockProfiles, id: \.id) { profile in
            Text(profile.displayName).tag(profile.id)
          }
        }
        Picker(
          "Roll",
          selection: Binding(
            get: { model.selectedRollProfileID ?? "" },
            set: { model.selectedRollProfileID = $0.isEmpty ? nil : $0 }
          )
        ) {
          Text("None").tag("")
          ForEach(model.availableRollProfiles, id: \.rollID) { profile in
            Text(profile.rollID).tag(profile.rollID)
          }
        }
        Button("Apply Selected Profiles", action: model.applySelectedPipelineProfiles)

        HStack {
          TextField("New profile name", text: $profileName)
            .textFieldStyle(.roundedBorder)
          Menu("Save") {
            Button("Capture Profile") {
              model.saveCurrentCaptureProfile(named: profileName)
              profileName = ""
            }
            Button("Film-Stock Profile") {
              model.saveCurrentFilmStockProfile(named: profileName)
              profileName = ""
            }
          }
          .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .controlSize(.small)

        if !model.profileStatus.isEmpty {
          Text(model.profileStatus)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

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
        .disabled(model.decodedImage == nil || model.isCropDetectionRunning || isPerspectiveEditing)

        HStack(spacing: 8) {
          Button(action: toggleStraightening) {
            Label(
              isStraightening ? "Cancel" : "Straighten",
              systemImage: isStraightening ? "xmark" : "line.diagonal"
            )
          }
          Button(action: toggleCropping) {
            Label(
              isCropping ? "Cancel" : "Crop",
              systemImage: isCropping ? "xmark" : "crop"
            )
          }
        }
        .disabled(model.decodedImage == nil || isPerspectiveEditing)

        if isStraightening {
          Text("Click one point, then a second point along an edge that should be horizontal or vertical.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else if isCropping {
          Text("Drag a box over the canvas to keep that area.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        if abs(model.straightenAngle) > 0.000_001 {
          HStack {
            Text("Straighten: \(String(format: "%.1f", model.straightenAngle))°")
              .font(.caption2)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Clear", action: model.clearStraightening)
              .controlSize(.small)
          }
        }

        Button(action: togglePerspectiveEditing) {
          Label(
            isPerspectiveEditing ? "Done Aligning" : "Adjust Perspective",
            systemImage: isPerspectiveEditing ? "checkmark" : "square.on.square.dashed"
          )
        }
        .disabled(model.decodedImage == nil)

        if isPerspectiveEditing {
          Text("Drag the four corners onto the film edges. The grid shows the rectangular canvas that will be straightened on preview and export.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button("Reset Perspective") {
            model.clearCrop()
            model.beginPerspectiveCrop()
          }
          .controlSize(.small)
        }

        if let perspectiveCrop = model.perspectiveCrop {
          Divider()
          Text("Four-corner perspective crop")
            .font(.caption2)
          Text("TL \(pointText(perspectiveCrop.topLeft))  TR \(pointText(perspectiveCrop.topRight))")
            .font(.caption2)
            .foregroundStyle(.secondary)
          Text("BL \(pointText(perspectiveCrop.bottomLeft))  BR \(pointText(perspectiveCrop.bottomRight))")
            .font(.caption2)
            .foregroundStyle(.secondary)
          Button("Clear") {
            endPerspectiveEditing()
            model.clearCrop()
          }
          .controlSize(.small)
          .font(.caption2)
        } else if let cropRect = model.cropRect {
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

        if let manualCrop = model.manualCrop {
          Divider()
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("Manual canvas crop")
                .font(.caption2)
              Text(String(
                format: "x %.3f  y %.3f  w %.3f  h %.3f",
                manualCrop.x, manualCrop.y, manualCrop.width, manualCrop.height))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear", action: model.clearManualCrop)
              .controlSize(.small)
          }
        }

        if let output = model.selectedCanvasDimensions {
          Divider()
          HStack {
            Text("Full-resolution canvas")
              .font(.caption2)
              .foregroundStyle(.secondary)
            Spacer()
            Text("\(output.width) × \(output.height) px")
              .font(.caption2)
              .monospacedDigit()
          }
        }

        if !model.cropStatus.isEmpty && model.cropRect == nil
          && model.perspectiveCrop == nil && model.manualCrop == nil
          && !model.isCropDetectionRunning
        {
          Text(model.cropStatus)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      InspectorSection("Dust Mask", systemImage: "sparkles") {
        HStack {
          Button(action: model.detectDustMask) {
            if model.isDustDetectionRunning {
              ProgressView()
                .controlSize(.small)
            } else {
              Label("Detect Dust", systemImage: "wand.and.stars")
            }
          }
          .disabled(model.decodedImage == nil || model.isDustDetectionRunning)
          if model.dustMaskImage != nil {
            Button("Clear", action: model.clearDustMask)
          }
        }
        .controlSize(.small)
        Text(
          model.dustStatus.isEmpty
            ? "Detection overlays candidate dust pixels; removal remains non-destructive and is not applied automatically."
            : model.dustStatus
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
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
      .disabled(model.previewImage == nil)
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
      InspectorSection("Clipping", systemImage: "waveform.path.ecg") {
        let low = model.previewStatistics.lowClippingRatios
        let high = model.previewStatistics.highClippingRatios
        densityRow("Shadows", max(low.blue, low.green, low.red) * 100)
        densityRow("Highlights", max(high.blue, high.green, high.red) * 100)
        Text("Percent of sampled display pixels clipped in the most affected channel.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      InspectorSection("Tone Curve", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
        Toggle(
          "Enable Overall Curve",
          isOn: Binding(
            get: { model.parameters.curveEnabled },
            set: { model.setCurveEnabled($0) }
          )
        )
        .font(.caption)
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
          if let filename = model.activeExportFilename {
            Text(filename)
              .font(.caption)
              .lineLimit(1)
          }
          Text(
            "Processing \(min(model.exportProgressCurrent + 1, model.exportProgressTotal)) of \(model.exportProgressTotal)"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
          Button("Export Selected", action: model.exportSelected)
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
          Button("Export All", action: model.exportAll)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
        }
        .disabled(model.exportParameters.destinationDirectory == nil || model.isExporting)

        if model.isExporting {
          HStack(spacing: 8) {
            Button("Add Selected", action: model.addSelectedToExportQueue)
              .buttonStyle(.borderedProminent)
              .frame(maxWidth: .infinity)
            Button("Cancel", role: .cancel, action: model.cancelExport)
              .buttonStyle(.bordered)
              .frame(maxWidth: .infinity)
          }
          Text(
            model.exportQueueCount == 1
              ? "1 file waiting" : "\(model.exportQueueCount) files waiting"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

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
          if let dustMask = model.dustMaskImage {
            Image(nsImage: dustMask)
              .resizable()
              .scaledToFit()
              .blendMode(.screen)
              .opacity(0.85)
              .allowsHitTesting(false)
          }
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

        PerspectiveCropOverlay(
          isActive: isPerspectiveEditing,
          crop: model.perspectiveCrop,
          imageSize: model.previewImage?.size ?? .zero,
          rotation: model.parameters.rotation,
          flipHorizontally: model.parameters.flip,
          onCropChanged: model.setPerspectiveCrop
        )

        StraightenLineOverlay(
          isActive: isStraightening,
          imageSize: model.previewImage?.size ?? .zero,
          onGuideCompleted: { deviation in
            model.straighten(usingGuideDeviation: deviation)
            endStraightening()
          }
        )

        ManualCropOverlay(
          isActive: isCropping,
          imageSize: model.previewImage?.size ?? .zero,
          onCropCompleted: { crop in
            model.cropCurrentCanvas(to: crop)
            endCropping()
          }
        )
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

  private func togglePerspectiveEditing() {
    if isPerspectiveEditing {
      endPerspectiveEditing()
      return
    }
    endStraightening()
    endCropping()
    perspectiveEditingPreviousShowOriginal = model.showOriginal
    model.beginPerspectiveCrop()
    isPerspectiveEditing = true
    model.showOriginal = true
  }

  private func endPerspectiveEditing() {
    guard isPerspectiveEditing else { return }
    isPerspectiveEditing = false
    model.showOriginal = perspectiveEditingPreviousShowOriginal
  }

  private func toggleStraightening() {
    if isStraightening {
      endStraightening()
      return
    }
    endPerspectiveEditing()
    endCropping()
    isStraightening = true
  }

  private func endStraightening() {
    guard isStraightening else { return }
    isStraightening = false
  }

  private func toggleCropping() {
    if isCropping {
      endCropping()
      return
    }
    endPerspectiveEditing()
    endStraightening()
    isCropping = true
  }

  private func endCropping() {
    isCropping = false
  }

  private func pointText(_ point: PerspectiveCrop.Point) -> String {
    String(format: "%.2f, %.2f", point.x, point.y)
  }
}

private struct StraightenLineOverlay: View {
  let isActive: Bool
  let imageSize: CGSize
  let onGuideCompleted: (Double) -> Void

  @State private var startPoint: CGPoint?
  @State private var hoverPoint: CGPoint?

  var body: some View {
    GeometryReader { geometry in
      let imageRect = aspectFitRect(imageSize: imageSize, containerSize: geometry.size)
      if isActive, imageRect.width > 0, imageRect.height > 0 {
        ZStack {
          Color.clear
          if let startPoint {
            Circle()
              .fill(Color.yellow)
              .overlay(Circle().stroke(.black.opacity(0.7), lineWidth: 2))
              .frame(width: 12, height: 12)
              .position(startPoint)
            if let endPoint = hoverPoint {
              Path { path in
                path.move(to: startPoint)
                path.addLine(to: endPoint)
              }
              .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
              Circle()
                .fill(Color.yellow)
                .overlay(Circle().stroke(.black.opacity(0.7), lineWidth: 2))
                .frame(width: 12, height: 12)
                .position(endPoint)
              if let guide = guideResult(from: startPoint, to: endPoint) {
                Text(guide.axis == .horizontal ? "Horizontal" : "Vertical")
                  .font(.caption2.weight(.semibold))
                  .padding(.horizontal, 6)
                  .padding(.vertical, 3)
                  .background(.black.opacity(0.7), in: Capsule())
                  .foregroundStyle(.yellow)
                  .position(
                    x: (startPoint.x + endPoint.x) / 2,
                    y: (startPoint.y + endPoint.y) / 2 - 18)
              }
            }
          }
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
          switch phase {
          case .active(let location):
            if startPoint != nil {
              hoverPoint = clamped(location, to: imageRect)
            }
          case .ended:
            hoverPoint = nil
          }
        }
        .gesture(
          DragGesture(minimumDistance: 0)
            .onEnded { value in
              guard imageRect.contains(value.location) else { return }
              let point = clamped(value.location, to: imageRect)
              guard let startPoint else {
                self.startPoint = point
                hoverPoint = point
                return
              }
              guard hypot(point.x - startPoint.x, point.y - startPoint.y) >= 8 else { return }
              guard let result = guideResult(from: startPoint, to: point) else { return }
              self.startPoint = nil
              hoverPoint = nil
              onGuideCompleted(result.deviation)
            }
        )
      }
    }
    .allowsHitTesting(isActive)
    .onChange(of: isActive) {
      if !isActive {
        startPoint = nil
        hoverPoint = nil
      }
    }
  }

  private func guideResult(
    from start: CGPoint,
    to end: CGPoint
  ) -> (deviation: Double, axis: ImageGeometry.StraightenAxis)? {
    ImageGeometry.straightenGuide(
      deltaX: end.x - start.x,
      deltaY: end.y - start.y)
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

private struct ManualCropOverlay: View {
  let isActive: Bool
  let imageSize: CGSize
  let onCropCompleted: (NormalizedCropRect) -> Void

  @State private var startPoint: CGPoint?
  @State private var endPoint: CGPoint?

  var body: some View {
    GeometryReader { geometry in
      let imageRect = aspectFitRect(imageSize: imageSize, containerSize: geometry.size)
      if isActive, imageRect.width > 0, imageRect.height > 0 {
        ZStack {
          Color.clear
          if let startPoint, let endPoint {
            let cropRect = CGRect(
              x: min(startPoint.x, endPoint.x),
              y: min(startPoint.y, endPoint.y),
              width: abs(endPoint.x - startPoint.x),
              height: abs(endPoint.y - startPoint.y))
            Path { path in
              path.addRect(imageRect)
              path.addRect(cropRect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            Rectangle()
              .stroke(Color.white, lineWidth: 2)
              .frame(width: cropRect.width, height: cropRect.height)
              .position(x: cropRect.midX, y: cropRect.midY)
          }
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              guard imageRect.contains(value.startLocation) else { return }
              if startPoint == nil {
                startPoint = clamped(value.startLocation, to: imageRect)
              }
              endPoint = clamped(value.location, to: imageRect)
            }
            .onEnded { value in
              defer {
                startPoint = nil
                endPoint = nil
              }
              guard let startPoint else { return }
              let endPoint = clamped(value.location, to: imageRect)
              let width = abs(endPoint.x - startPoint.x)
              let height = abs(endPoint.y - startPoint.y)
              guard width >= 4, height >= 4 else { return }
              onCropCompleted(NormalizedCropRect(
                x: (min(startPoint.x, endPoint.x) - imageRect.minX) / imageRect.width,
                y: (min(startPoint.y, endPoint.y) - imageRect.minY) / imageRect.height,
                width: width / imageRect.width,
                height: height / imageRect.height))
            }
        )
      }
    }
    .allowsHitTesting(isActive)
    .onChange(of: isActive) {
      if !isActive {
        startPoint = nil
        endPoint = nil
      }
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
      height: size.height)
  }

  private func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
    CGPoint(
      x: min(max(point.x, rect.minX), rect.maxX),
      y: min(max(point.y, rect.minY), rect.maxY))
  }
}

private struct PerspectiveCropOverlay: View {
  let isActive: Bool
  let crop: PerspectiveCrop?
  let imageSize: CGSize
  let rotation: Int
  let flipHorizontally: Bool
  let onCropChanged: (PerspectiveCrop) -> Void

  var body: some View {
    GeometryReader { geometry in
      let imageRect = aspectFitRect(imageSize: imageSize, containerSize: geometry.size)
      if isActive, let crop, imageRect.width > 0, imageRect.height > 0 {
        let displayedPoints = crop.points.map(displayedPoint)
        let points = displayedPoints.map { point in
          CGPoint(
            x: imageRect.minX + point.x * imageRect.width,
            y: imageRect.minY + point.y * imageRect.height
          )
        }
        ZStack {
          Path { path in
            path.move(to: points[0])
            path.addLine(to: points[1])
            path.addLine(to: points[2])
            path.addLine(to: points[3])
            path.closeSubpath()
          }
          .stroke(Color.accentColor, lineWidth: 2)

          Path { path in
            for fraction in [0.25, 0.5, 0.75] {
              let top = interpolate(points[0], points[1], fraction: fraction)
              let bottom = interpolate(points[3], points[2], fraction: fraction)
              path.move(to: top)
              path.addLine(to: bottom)
              let left = interpolate(points[0], points[3], fraction: fraction)
              let right = interpolate(points[1], points[2], fraction: fraction)
              path.move(to: left)
              path.addLine(to: right)
            }
          }
          .stroke(Color.accentColor.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

          ForEach(Array(points.enumerated()), id: \.offset) { index, point in
            Circle()
              .fill(Color.accentColor)
              .overlay(Circle().stroke(.white, lineWidth: 2))
              .frame(width: 16, height: 16)
              .contentShape(Circle().inset(by: -8))
              .position(point)
              .gesture(
                DragGesture(minimumDistance: 0)
                  .onChanged { value in
                    let clamped = clamped(value.location, to: imageRect)
                    let displayed = PerspectiveCrop.Point(
                      x: (clamped.x - imageRect.minX) / imageRect.width,
                      y: (clamped.y - imageRect.minY) / imageRect.height
                    )
                    onCropChanged(crop.replacing(index, with: sourcePoint(fromDisplayed: displayed)))
                  }
              )
              .help(["Top left", "Top right", "Bottom right", "Bottom left"][index])
          }
        }
      }
    }
    .allowsHitTesting(isActive)
  }

  private func displayedPoint(_ point: PerspectiveCrop.Point) -> CGPoint {
    let turns = ((rotation % 4) + 4) % 4
    var result: CGPoint
    switch turns {
    case 1: result = CGPoint(x: 1 - point.y, y: point.x)
    case 2: result = CGPoint(x: 1 - point.x, y: 1 - point.y)
    case 3: result = CGPoint(x: point.y, y: 1 - point.x)
    default: result = CGPoint(x: point.x, y: point.y)
    }
    if flipHorizontally { result.x = 1 - result.x }
    return result
  }

  private func sourcePoint(fromDisplayed point: PerspectiveCrop.Point) -> PerspectiveCrop.Point {
    let displayX = flipHorizontally ? 1 - point.x : point.x
    let turns = ((rotation % 4) + 4) % 4
    switch turns {
    case 1: return .init(x: point.y, y: 1 - displayX)
    case 2: return .init(x: 1 - displayX, y: 1 - point.y)
    case 3: return .init(x: 1 - point.y, y: displayX)
    default: return .init(x: displayX, y: point.y)
    }
  }

  private func interpolate(_ start: CGPoint, _ end: CGPoint, fraction: CGFloat) -> CGPoint {
    CGPoint(
      x: start.x + (end.x - start.x) * fraction,
      y: start.y + (end.y - start.y) * fraction
    )
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
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 7) {
        Image(systemName: systemImage)
          .foregroundStyle(.secondary)
          .frame(width: 16)
        Text(title)
          .foregroundStyle(.primary)
      }
      .font(.subheadline.weight(.semibold))
      content
    }
    .controlSize(.small)
    .buttonStyle(.bordered)
    .padding(11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(nsColor: .windowBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }
}

private struct ToolbarSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>

  init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) {
    self.title = title
    self._value = value
    self.range = range
  }

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.caption)
      Slider(value: $value, in: range)
        .frame(width: 104)
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
