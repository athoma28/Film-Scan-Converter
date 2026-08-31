import FilmScanEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var camera: CameraController
  @State private var dropTargeted = false
  @State private var showLivePreview = false
  @State private var inspectorPage: InspectorPage = .edit
  @State private var activeOverlay: PreviewOverlay?
  @State private var rebateDragStart: CGPoint?
  @State private var rebateDragEnd: CGPoint?
  @State private var overlayPreviousShowOriginal: Bool?
  @State private var usesPerspectiveParallelAssist = true
  @State private var presetName = ""
  @State private var profileName = ""
  @State private var previewZoomRequest = PreviewZoomRequest()
  @State private var previewZoomPercent = 100
  @State private var previewIsFit = true

  private enum PreviewOverlay {
    case rebate
    case perspective
    case straighten
    case crop
  }

  private var isPickingRebateRegion: Bool { activeOverlay == .rebate }
  private var isPerspectiveEditing: Bool { activeOverlay == .perspective }
  private var isStraightening: Bool { activeOverlay == .straighten }
  private var isCropping: Bool { activeOverlay == .crop }

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

  private enum NegativeConversionMode: String, CaseIterable, Identifiable {
    case natural
    case darkroom
    case classic
    case bypass

    var id: Self { self }

    var title: String {
      switch self {
      case .natural: "Natural"
      case .darkroom: "Darkroom"
      case .classic: "Classic"
      case .bypass: "Bypass"
      }
    }

    var subtitle: String {
      switch self {
      case .natural: "Reference-based starting point"
      case .darkroom: "Film and paper character"
      case .classic: "Original converter response"
      case .bypass: "Leave the scan uninverted"
      }
    }

    var systemImage: String {
      switch self {
      case .natural: "camera.filters"
      case .darkroom: "photo.artframe"
      case .classic: "clock.arrow.circlepath"
      case .bypass: "forward.end"
      }
    }

    static func available(for filmType: FilmType) -> [Self] {
      switch filmType {
      case .colourNegative: [.natural, .darkroom, .classic, .bypass]
      case .blackAndWhiteNegative: [.natural, .classic, .bypass]
      case .slide, .cropOnly: []
      }
    }
  }

  var body: some View {
    NavigationSplitView {
      List(selection: $model.selectedFiles) {
        ForEach(model.files, id: \.self) { url in
          ScanSidebarRow(
            url: url,
            thumbnail: model.thumbnail(for: url),
            isThumbnailLoading: model.isThumbnailLoading(for: url),
            isCurrentLoadingOrRendering: model.selection == url
              && (model.isLoading || model.isRendering),
            isActiveExport: model.isActiveExport(for: url),
            isPendingExport: model.isPendingExport(for: url),
            hasCachedPreview: model.hasCachedPreview(for: url),
            hasEdits: model.hasEdits(for: url),
            stackBadge: scanStackBadge(for: url)
          )
          .tag(url)
          .task(id: model.thumbnail(for: url) == nil) {
            model.requestThumbnail(for: url)
          }

          // Keep this inside the scrollable list. A sibling below List makes
          // NavigationSplitView adopt the inspector's full fitting height.
          if model.selection == url, let stack = model.selectedDetectedScanStack {
            scanStackProposal(stack)
              .listRowInsets(EdgeInsets())
              .listRowSeparator(.hidden)
          }
        }

        if model.selectedDetectedScanStack == nil,
          model.isAnalyzingScanStacks,
          model.files.count > 1
        {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
              .accessibilityHidden(true)
            Text("Checking for repeated captures...")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .background(Color(nsColor: .controlBackgroundColor))
        }
      }
      .listStyle(.sidebar)
      .navigationTitle("Scans")
      .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 340)
      .onChange(of: model.selectedFiles) {
        guard model.sidebarSelectionDidChange() else { return }
        endActiveOverlay()
        requestPreviewZoom(.fit)
        model.loadSelection()
      }
      .onChange(of: model.selection) {
        endActiveOverlay()
        requestPreviewZoom(.fit)
      }
    } detail: {
      VStack(spacing: 0) {
        toolbar
        Divider()
        HStack(spacing: 0) {
          preview
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          if !showLivePreview, model.previewImage != nil {
            Divider()
            inspector
              .frame(width: 390)
              .frame(maxHeight: .infinity)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        HStack(spacing: 6) {
          Text(showLivePreview ? camera.status : model.status)
            .foregroundStyle(
              (showLivePreview ? camera.statusKind : model.statusKind) == .error
                ? Color.red : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .font(.caption)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(dropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
      .dropDestination(for: URL.self) { urls, _ in
        model.importFiles(urls)
        return !FileDropPolicy.supportedFiles(from: urls).isEmpty
      } isTargeted: { targeted in
        dropTargeted = targeted
      }
    }
    .navigationSplitViewStyle(.balanced)
    .focusedSceneValue(
      \.previewZoomCommands,
      showLivePreview || model.previewImage == nil
        ? nil
        : PreviewZoomCommands(
          fit: { requestPreviewZoom(.fit) },
          actualSize: { requestPreviewZoom(.actualSize) },
          zoomIn: { requestPreviewZoom(.zoomIn) },
          zoomOut: { requestPreviewZoom(.zoomOut) })
    )
    .environment(\.editingGestureAction) { actionName, isEditing in
      model.editingGestureChanged(actionName, isEditing: isEditing)
    }
  }

  private func scanStackBadge(for url: URL) -> ScanSidebarRow.StackBadgeData? {
    guard let stack = model.detectedScanStack(containing: url) else { return nil }
    return ScanSidebarRow.StackBadgeData(
      memberCount: stack.members.count,
      isEnabled: model.isScanStackEnabled(stack))
  }

  private func scanStackProposal(_ stack: DetectedScanStack) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Image(systemName: "square.stack.3d.up.fill")
          .foregroundStyle(Color.accentColor)
        Text("\(stack.members.count)-capture stack")
          .font(.headline)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
        Spacer(minLength: 6)
        Text("\(Int((stack.confidence * 100).rounded()))%")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .help("Match confidence")
      }

      Text(scanStackProposalDescription(stack))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)

      if model.isAnalyzingScanStacks {
        HStack(spacing: 7) {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
          Text("Checking the remaining imports before this group can be enabled...")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Combine for")
          .font(.caption)
          .foregroundStyle(.secondary)
        Picker(
          "Combine for",
          selection: Binding(
            get: { model.scanStackMode(for: stack) },
            set: { model.setScanStackMode($0, for: stack) }
          )
        ) {
          Text("Auto").tag(ScanStackMode.automatic)
          Text("Noise").tag(ScanStackMode.noiseReduction)
          Text("HDR").tag(ScanStackMode.hdr)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .disabled(model.isExporting || model.isAnalyzingScanStacks || model.isLoading)
      }

      Toggle(
        "Use aligned stack",
        isOn: Binding(
          get: { model.isScanStackEnabled(stack) },
          set: { model.setScanStackEnabled($0, for: stack) }
        )
      )
      .toggleStyle(.switch)
      .controlSize(.small)
      .disabled(
        model.isExporting || model.isAnalyzingScanStacks || model.isLoading
          || model.flatFieldImage != nil)

      if model.flatFieldImage != nil {
        Text(
          "Clear the flat field before stacking so each capture keeps correct sensor coordinates."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }

      if model.isScanStackEnabled(stack) {
        Text("The stack exports once using the first capture's name and edits.")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      if model.scanStackStatusID == stack.id,
        model.isBuildingScanStack || model.isUpgradingScanStack,
        model.isScanStackEnabled(stack)
      {
        HStack(spacing: 7) {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
          Text(model.scanStackStatus)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      } else if model.scanStackStatusID == stack.id,
        model.isScanStackEnabled(stack),
        !model.scanStackStatus.isEmpty
      {
        Text(model.scanStackStatus)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .controlSize(.small)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private func scanStackProposalDescription(_ stack: DetectedScanStack) -> String {
    if stack.exposureSpreadEV >= 0.5 {
      let spread = String(format: "%.1f", stack.exposureSpreadEV)
      return
        "These adjacent scans appear to be one negative with about \(spread) EV of bracketing. Auto will verify the full-resolution exposures before HDR fusion."
    }
    return
      "These adjacent scans appear to be the same negative. Auto will verify the full-resolution exposures, then normally align and average them to reduce sensor noise."
  }

  private var exportSelectionButtonTitle: String {
    if let stack = model.selectedDetectedScanStack,
      model.isScanStackEnabled(stack),
      model.selectedExportItemCount == 1
    {
      return "Export Stack (\(stack.members.count) captures)"
    }
    if model.selectedExportItemCount > 1 {
      return "Export Selected (\(model.selectedExportItemCount) outputs)"
    }
    return "Export Selected"
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Button(action: model.showImportPanel) {
        Label("Import", systemImage: "plus")
      }
      .keyboardShortcut("o")
      .disabled(model.isExporting)

      Button {
        model.selectAdjacentScan(offset: -1)
      } label: {
        Image(systemName: "chevron.up")
          .frame(width: 18)
      }
      .disabled(!model.canSelectPreviousScan)
      .help("Previous scan (Option-Command-Up)")
      .accessibilityLabel("Previous scan")

      Button {
        model.selectAdjacentScan(offset: 1)
      } label: {
        Image(systemName: "chevron.down")
          .frame(width: 18)
      }
      .disabled(!model.canSelectNextScan)
      .help("Next scan (Option-Command-Down)")
      .accessibilityLabel("Next scan")

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
        if model.canLoadRawDetailPreview {
          Button(action: model.loadRawDetailPreview) {
            Label("Load RAW Preview", systemImage: "sparkles.rectangle.stack")
          }
          .help("Decode the full-resolution 1-pass RAW preview now")
        }

        Toggle(isOn: $model.showOriginal) {
          Label("Original", systemImage: "rectangle.on.rectangle")
        }
        .toggleStyle(.button)
        .disabled(isPickingRebateRegion)
        .help("Press and hold the comparison visually by toggling the original")

        HStack(spacing: 4) {
          Button {
            requestPreviewZoom(.zoomOut)
          } label: {
            Image(systemName: "minus.magnifyingglass")
              .frame(width: 18)
          }
          .help("Zoom out (Command-minus)")

          Menu {
            Button("Fit in Window") { requestPreviewZoom(.fit) }
            Button("100% Preview Pixels") { requestPreviewZoom(.actualSize) }
          } label: {
            Text(previewIsFit ? "Fit" : "\(previewZoomPercent)%")
              .monospacedDigit()
              .frame(minWidth: 38)
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .help("Choose Fit or inspect preview pixels at 100%")

          Button {
            requestPreviewZoom(.zoomIn)
          } label: {
            Image(systemName: "plus.magnifyingglass")
              .frame(width: 18)
          }
          .help("Zoom in (Command-plus)")
        }

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

      ScrollView {
        inspectorPageContent
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
    .background(Color(nsColor: .controlBackgroundColor))
  }

  @ViewBuilder
  private var inspectorPageContent: some View {
    switch inspectorPage {
    case .edit: editInspector
    case .grade: gradeInspector
    case .export: exportInspector
    }
  }

  private var filmConversionSection: some View {
    InspectorSection("Film & Conversion", systemImage: "film.stack") {
      VStack(alignment: .leading, spacing: 6) {
        Text("Scan type")
          .font(.caption.weight(.medium))
        Picker(
          "Scan type",
          selection: Binding(
            get: { model.parameters.filmType },
            set: { model.setFilmType($0) }
          )
        ) {
          ForEach(FilmType.allCases, id: \.self) { type in
            Text(type.compactDisplayName).tag(type)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Text(filmTypeDescription(model.parameters.filmType))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if supportsFilmNegative(filmType: model.parameters.filmType) {
        Divider()

        VStack(alignment: .leading, spacing: 8) {
          Text("Conversion")
            .font(.caption.weight(.medium))
          LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())],
            spacing: 8
          ) {
            ForEach(NegativeConversionMode.available(for: model.parameters.filmType)) { mode in
              InspectorChoiceCard(
                title: mode.title,
                subtitle: mode.subtitle,
                systemImage: mode.systemImage,
                isSelected: negativeConversionMode(for: model.parameters) == mode
              ) {
                setNegativeConversionMode(mode)
              }
            }
          }
        }

        conversionDetailControls

        if model.parameters.filmType == .colourNegative
          && negativeConversionMode(for: model.parameters) != .bypass
        {
          advancedColorScienceControls
        }
      }
    }
  }

  @ViewBuilder
  private var conversionDetailControls: some View {
    switch negativeConversionMode(for: model.parameters) {
    case .natural:
      naturalConversionControls
    case .darkroom:
      darkroomConversionControls
    case .classic:
      classicConversionControls
    case .bypass:
      Text(
        "The negative stays uninverted while the scan type remains available for comparison. Choose Original above for a normal positive-image workflow."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var naturalConversionControls: some View {
    let fn = model.parameters.filmNegativeParams
    let selectedPreset = filmNegativePreset(for: model.parameters)
    return VStack(alignment: .leading, spacing: 10) {
      Text("Starting look")
        .font(.caption.weight(.medium))

      VStack(spacing: 6) {
        ForEach(naturalPresets(for: model.parameters.filmType), id: \.self) { preset in
          InspectorChoiceRow(
            title: naturalPresetTitle(preset),
            subtitle: naturalPresetSubtitle(preset),
            isSelected: selectedPreset == preset
          ) {
            model.setFilmNegativePreset(preset)
          }
        }
      }

      AdjustmentSlider(
        "Negative Exposure",
        value: Binding(
          get: { fn.monochromeExposureEV },
          set: { model.setCalibratedNegativeExposure($0) }
        ),
        range: -4...4, neutral: 0, valueFormat: "%+.2f", unitSuffix: "EV",
        responseExponent: 1.5
      )
      HStack {
        Text("Lighter positive")
        Spacer()
        Text("Darker positive")
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
    }
  }

  private var darkroomConversionControls: some View {
    let fn = model.parameters.filmNegativeParams
    let profile = NegativeDensityProfileCatalog.profile(id: fn.densityProfileID)
    let defaultStrength = profile.unmixStrength * 100
    return VStack(alignment: .leading, spacing: 10) {
      Text(
        "Build the positive like a darkroom print: choose the negative stock, then choose the paper character."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      Text("Negative stock")
        .font(.caption.weight(.medium))
      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())],
        spacing: 6
      ) {
        ForEach(NegativeDensityProfileCatalog.bundled, id: \.id.rawValue) { option in
          InspectorChoiceChip(
            title: option.displayName,
            isSelected: fn.densityProfileID == option.id.rawValue
          ) {
            model.setDensityProfileID(option.id.rawValue)
          }
        }
      }

      Text("Paper character")
        .font(.caption.weight(.medium))
        .padding(.top, 2)
      VStack(spacing: 6) {
        ForEach(DensityPaperProfileCatalog.bundled, id: \.id.rawValue) { paper in
          InspectorChoiceRow(
            title: paper.displayName,
            subtitle: paperDescription(paper),
            isSelected: fn.densityPaperID == paper.id.rawValue
          ) {
            model.setDensityPaperID(paper.id.rawValue)
          }
        }
      }

      AdjustmentSlider(
        "Color Separation",
        value: Binding(
          get: {
            (fn.densityUnmixStrength >= 0 ? fn.densityUnmixStrength : profile.unmixStrength) * 100
          },
          set: { model.setDensityUnmixStrength($0 / 100) }
        ),
        range: 0...100, neutral: defaultStrength, valueFormat: "%.0f", unitSuffix: "%"
      )
      HStack {
        Text("Gentle")
        Spacer()
        Text("Stronger dye separation")
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
    }
  }

  private var classicConversionControls: some View {
    let fn = model.parameters.filmNegativeParams
    let neutral =
      model.parameters.filmType == .blackAndWhiteNegative
      ? FilmNegativeParams.legacyBlackAndWhite : FilmNegativeParams.legacyColourNegative
    let rexp = -(fn.greenExp * fn.redRatio)
    let gexp = -fn.greenExp
    let bexp = -(fn.greenExp * fn.blueRatio)
    return VStack(alignment: .leading, spacing: 8) {
      Text(
        "The original Film Scan Converter response is kept for older edits and for scans that already match it well."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      DisclosureGroup("Technical channel response") {
        VStack(alignment: .leading, spacing: 10) {
          AdjustmentSlider(
            "Red Ratio",
            value: Binding(
              get: { fn.redRatio },
              set: { model.setFilmNegativeRedRatio($0) }
            ),
            range: 0.8...1.8, neutral: neutral.redRatio,
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
            range: 0.6...1.4, neutral: neutral.blueRatio,
            valueFormat: "%.3f", responseExponent: 1.5
          )
          Text(
            "Channel exponents: R \(String(format: "%.2f", rexp))  G \(String(format: "%.2f", gexp))  B \(String(format: "%.2f", bexp))"
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
      }
    }
  }

  private var advancedColorScienceControls: some View {
    let mixing = model.parameters.filmDyeMixing
    return DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "Use this only when one dye record is visibly contaminating another. It is applied before the everyday Color controls below."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        AdjustmentSlider(
          "Red from Green",
          value: Binding(
            get: { model.parameters.filmDyeMixing.redFromGreen * 100 },
            set: { model.setFilmDyeMixing(\.redFromGreen, to: $0 / 100) }
          ),
          range: -30...30, neutral: 0, valueFormat: "%.1f", unitSuffix: "%",
          responseExponent: 1.7
        )
        AdjustmentSlider(
          "Red from Blue",
          value: Binding(
            get: { model.parameters.filmDyeMixing.redFromBlue * 100 },
            set: { model.setFilmDyeMixing(\.redFromBlue, to: $0 / 100) }
          ),
          range: -30...30, neutral: 0, valueFormat: "%.1f", unitSuffix: "%",
          responseExponent: 1.7
        )
        AdjustmentSlider(
          "Green from Red",
          value: Binding(
            get: { model.parameters.filmDyeMixing.greenFromRed * 100 },
            set: { model.setFilmDyeMixing(\.greenFromRed, to: $0 / 100) }
          ),
          range: -30...30, neutral: 0, valueFormat: "%.1f", unitSuffix: "%",
          responseExponent: 1.7
        )
        AdjustmentSlider(
          "Green from Blue",
          value: Binding(
            get: { model.parameters.filmDyeMixing.greenFromBlue * 100 },
            set: { model.setFilmDyeMixing(\.greenFromBlue, to: $0 / 100) }
          ),
          range: -30...30, neutral: 0, valueFormat: "%.1f", unitSuffix: "%",
          responseExponent: 1.7
        )
        AdjustmentSlider(
          "Blue from Red",
          value: Binding(
            get: { model.parameters.filmDyeMixing.blueFromRed * 100 },
            set: { model.setFilmDyeMixing(\.blueFromRed, to: $0 / 100) }
          ),
          range: -30...30, neutral: 0, valueFormat: "%.1f", unitSuffix: "%",
          responseExponent: 1.7
        )
        AdjustmentSlider(
          "Blue from Green",
          value: Binding(
            get: { model.parameters.filmDyeMixing.blueFromGreen * 100 },
            set: { model.setFilmDyeMixing(\.blueFromGreen, to: $0 / 100) }
          ),
          range: -30...30, neutral: 0, valueFormat: "%.1f", unitSuffix: "%",
          responseExponent: 1.7
        )

        Button("Reset Dye Crossover", action: model.resetFilmDyeMixing)
          .controlSize(.small)
          .disabled(mixing.isNeutral)
      }
      .padding(.top, 8)
    } label: {
      HStack {
        Label("Advanced color science", systemImage: "waveform.path")
        Spacer()
        if !mixing.isNeutral {
          Text("Adjusted")
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.accentColor)
        }
      }
    }
  }

  private var editInspector: some View {
    // VStack, not Group: a Group of sections overlays its children when passed
    // as a single view, stacking every inspector card on top of the others.
    VStack(spacing: 10) {
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

        Button(
          model.selectedFileCount > 1
            ? "Apply Look to Selected (\(model.selectedFileCount))"
            : "Apply Look to Selected",
          action: model.applyCurrentLookToSelectedFiles
        )
        .disabled(model.selectedFileCount < 2)
        .help(
          "Apply the active frame's look to the selected files while preserving each frame's geometry and measured film base."
        )

        Button("Apply Settings to All Open Files", action: model.applyCurrentSettingsToAllOpenFiles)
          .help(
            "Apply the active frame's look to every open file while preserving each frame's geometry and measured film base."
          )

        Button(action: model.applyKodachromeLikeLook) {
          Label("Kodachrome-like Auto", systemImage: "wand.and.stars")
        }
        .help(
          "Apply the color-negative profile, then adapt tone and color to the successful reference look."
        )

        Menu {
          ForEach(AdaptiveDisplayLook.prototypes) { look in
            Button(look.name) {
              model.applyAdaptiveDisplayLook(look)
            }
            .help(look.summary)
          }
        } label: {
          Label("Prototype Looks", systemImage: "paintpalette")
        }
        .help(
          "Experimental display looks sampled from photos you like. They keep the standard color-negative inversion, then apply a scene-adaptive curve and a light split-tone."
        )

        if let appliedPresetName = model.appliedPresetName {
          Button(action: model.removeAppliedPreset) {
            Label("Remove \(appliedPresetName)", systemImage: "arrow.uturn.backward")
          }
          .help(
            "Restore the adjustments from immediately before this preset was applied. Crop and orientation stay unchanged."
          )
        }

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
        .help(
          "Keeps recently viewed ~4000px RAW previews and prefetches the next few unseen files at ~3200px. The selected RAW upgrades from a 640px draft to a ~4000px preview, then a 1-pass full-resolution decode. Switching away discards full-res and keeps the ~4000px preview. Default is 8 files, with bounded previews still capped at 256 MB. Export keeps the selected file's last three-pass decode so a settings-only re-export skips unpack and demosaic."
        )

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

      filmConversionSection

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
            get: { model.parameters.photoAdjustments.temperatureShiftMired },
            set: { model.setSemanticTemperature($0) }
          ),
          range: PhotoAdjustmentParameters.temperatureShiftRangeMired,
          neutral: 0, valueFormat: "%.0f", responseExponent: 1.6
        )
        AdjustmentSlider(
          "Tint",
          value: Binding(
            get: { model.parameters.photoAdjustments.tint },
            set: { model.setSemanticTint($0) }
          ),
          range: PhotoAdjustmentParameters.tintRange,
          neutral: 0, valueFormat: "%.3f", responseExponent: 1.6
        )
        AdjustmentSlider(
          "Saturation",
          value: Binding(
            get: { model.parameters.photoAdjustments.saturation },
            set: { model.setSemanticSaturation($0) }
          ),
          range: PhotoAdjustmentParameters.saturationRange,
          neutral: 0, valueFormat: "%.3f", responseExponent: 1.6
        )
        AdjustmentSlider(
          "Vibrance",
          value: Binding(
            get: { model.parameters.photoAdjustments.vibrance },
            set: { model.setVibrance($0) }
          ),
          range: PhotoAdjustmentParameters.vibranceRange,
          neutral: 0, valueFormat: "%.3f", responseExponent: 1.6
        )
      }
      .disabled(!model.parameters.filmType.supportsColorCorrections)

      InspectorSection("Workflow Profiles", systemImage: "square.stack.3d.up") {
        Text(
          "Reusable scanner, film-response, and roll measurements for calibrated batches. Applying one can replace the entire conversion; use Darkroom above for one-off stock and paper choices."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        DisclosureGroup("Scanner & roll profiles") {
          VStack(alignment: .leading, spacing: 10) {
            Picker("Scanner / capture", selection: $model.selectedCaptureProfileID) {
              ForEach(model.availableCaptureProfiles, id: \.id) { profile in
                Text(profile.id.rawValue).tag(profile.id)
              }
            }
            Picker("Film response", selection: $model.selectedFilmStockProfileID) {
              ForEach(model.availableFilmStockProfiles, id: \.id) { profile in
                Text(profile.displayName).tag(profile.id)
              }
            }
            Picker(
              "Measured roll",
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
            Button("Apply Workflow Profiles", action: model.applySelectedPipelineProfiles)

            HStack {
              TextField("New profile name", text: $profileName)
                .textFieldStyle(.roundedBorder)
              Menu("Save") {
                Button("Capture Profile") {
                  model.saveCurrentCaptureProfile(named: profileName)
                  profileName = ""
                }
                Button("Film-Response Profile") {
                  model.saveCurrentFilmStockProfile(named: profileName)
                  profileName = ""
                }
              }
              .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
          }
          .padding(.top, 8)
        }

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

        Text(
          "Film base is the clear, unexposed film edge outside the photographed frame. Measuring it removes the orange mask from colour negatives."
        )
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
            beginRebateSelection()
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
          Text(
            "Click one point, then a second point along an edge that should be horizontal or vertical."
          )
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
          Text(
            "Drag each targeting reticle onto the film edge. A 100 × 100 px loupe appears while dragging. Parallel-edge assist softly snaps likely trapezoids; hold Option for a free corner."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Toggle("Parallel-edge assist", isOn: $usesPerspectiveParallelAssist)
            .controlSize(.small)
          Button("Reset Perspective") {
            model.clearPerspectiveCrop()
            model.beginPerspectiveCrop()
          }
          .controlSize(.small)
        }

        if let perspectiveCrop = model.perspectiveCrop {
          Divider()
          Text("Four-corner perspective crop")
            .font(.caption2)
          Text(
            "TL \(pointText(perspectiveCrop.topLeft))  TR \(pointText(perspectiveCrop.topRight))"
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          Text(
            "BL \(pointText(perspectiveCrop.bottomLeft))  BR \(pointText(perspectiveCrop.bottomRight))"
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          Button("Clear") {
            endPerspectiveEditing()
            model.clearPerspectiveCrop()
          }
          .controlSize(.small)
          .font(.caption2)
        } else if let cropRect = model.cropRect {
          Divider()
          VStack(alignment: .leading, spacing: 2) {
            Text("Angle: \(String(format: "%.1f", cropRect.angle))°")
              .font(.caption2)
            Text(
              "Size: \(String(format: "%.3f", cropRect.width)) × \(String(format: "%.3f", cropRect.height))"
            )
            .font(.caption2)
            Text(
              "Center: (\(String(format: "%.3f", cropRect.centerX)), \(String(format: "%.3f", cropRect.centerY)))"
            )
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
              Text(
                String(
                  format: "x %.3f  y %.3f  w %.3f  h %.3f",
                  manualCrop.x, manualCrop.y, manualCrop.width, manualCrop.height)
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset Crop", action: model.clearManualCrop)
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
              Text(
                "Base: B \(String(format: "%.3f", baseDensity.blue))  G \(String(format: "%.3f", baseDensity.green))  R \(String(format: "%.3f", baseDensity.red))"
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
              Text(
                "C-41: slopes B\(String(format: "%.2f", model.parameters.densityC41Profile.densitySlope.blue)) G\(String(format: "%.2f", model.parameters.densityC41Profile.densitySlope.green)) R\(String(format: "%.2f", model.parameters.densityC41Profile.densitySlope.red))"
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
              Text(
                model.parameters.densityCorrection == .identity
                  ? "Capture matrix: Identity"
                  : "Capture matrix: Custom fitted correction"
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
            }

            if model.parameters.densityPipelineEnabled {
              Text(
                "This uses the measured film edge for inversion. Turn it off to compare with the basic negative conversion."
              )
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
    VStack(spacing: 10) {
      InspectorSection("Clipping", systemImage: "waveform.path.ecg") {
        let low = model.previewStatistics.lowClippingRatios
        let high = model.previewStatistics.highClippingRatios
        densityRow("Shadows", max(low.blue, low.green, low.red) * 100)
        densityRow("Highlights", max(high.blue, high.green, high.red) * 100)
        Text("Percent of sampled display pixels clipped in the most affected channel.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      InspectorSection(
        "Tone Curve", systemImage: "point.topleft.down.to.point.bottomright.curvepath"
      ) {
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
    VStack(spacing: 10) {
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
          Button(exportSelectionButtonTitle, action: model.exportSelected)
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
          Button("Export All", action: model.exportAll)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
        }
        .disabled(
          model.exportParameters.destinationDirectory == nil || model.isExporting || model.isLoading
            || model.isBuildingScanStack
        )

        if model.isExporting {
          HStack(spacing: 8) {
            Button(
              model.selectedExportItemCount > 1
                ? "Add Selected (\(model.selectedExportItemCount))"
                : "Add Selected",
              action: model.addSelectedToExportQueue
            )
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            Button("Cancel", role: .cancel, action: model.cancelExport)
              .buttonStyle(.bordered)
              .frame(maxWidth: .infinity)
          }
          Text(
            model.exportQueueCount == 1
              ? "1 output waiting" : "\(model.exportQueueCount) outputs waiting"
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
          PreviewViewport(
            imageSize: image.size,
            request: previewZoomRequest,
            onZoomChanged: { percent, isFit in
              previewZoomPercent = percent
              previewIsFit = isFit
            }
          ) {
            previewDocument(image: image)
          }
          .accessibilityLabel("Still image preview")

          previewCanvasChrome
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

      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
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

  private func previewDocument(image: NSImage) -> some View {
    ZStack {
      RasterImage(image: image, interpolation: .high)
        .frame(width: image.size.width, height: image.size.height)
        .blur(radius: model.previewSourceKind == .rawDraft ? 1.6 : 0)

      if let dustMask = model.dustMaskImage {
        RasterImage(image: dustMask, interpolation: .none)
          .frame(width: image.size.width, height: image.size.height)
          .blendMode(.screen)
          .opacity(0.85)
          .allowsHitTesting(false)
      }

      RebateRegionSelectionOverlay(
        isActive: isPickingRebateRegion,
        imageSize: image.size,
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
        image: image,
        imageSize: image.size,
        rotation: model.parameters.rotation,
        flipHorizontally: model.parameters.flip,
        usesParallelAssist: usesPerspectiveParallelAssist,
        onCropChanged: model.setPerspectiveCrop
      )

      StraightenLineOverlay(
        isActive: isStraightening,
        imageSize: image.size,
        onGuideCompleted: { deviation in
          endStraightening()
          model.straighten(usingGuideDeviation: deviation)
        }
      )

      ManualCropOverlay(
        isActive: isCropping,
        imageSize: image.size,
        onCropCompleted: { crop in
          endCropping()
          model.setManualCrop(crop)
        }
      )
    }
    .frame(width: image.size.width, height: image.size.height)
  }

  @ViewBuilder
  private var previewCanvasChrome: some View {
    let showDraftBar = model.previewSourceKind == .rawDraft
    let showBadge =
      model.previewSourceKind == .embeddedRAW || model.previewSourceKind == .alignedStack
    if showDraftBar || showBadge {
      VStack {
        HStack {
          if showBadge {
            previewSourceBadge
          }
          Spacer()
        }
        Spacer()
        if showDraftBar {
          RawPreviewUpgradeBar()
            .padding(.bottom, 14)
        }
      }
      .padding(10)
      .allowsHitTesting(false)
    }
  }

  @ViewBuilder
  private var previewSourceBadge: some View {
    switch model.previewSourceKind {
    case .embeddedRAW:
      Label("Embedded RAW preview", systemImage: "exclamationmark.triangle.fill")
        .font(.caption2.weight(.medium))
        .foregroundStyle(.yellow)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.72), in: Capsule())
        .help("A fast embedded camera preview, not RAW colour.")
    case .alignedStack:
      Label("Aligned stack preview", systemImage: "square.stack.3d.up.fill")
        .font(.caption2.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.72), in: Capsule())
        .help(
          "An aligned multi-capture preview. The canvas upgrades from a bounded draft to full resolution while you inspect; export still rebuilds from the sources."
        )
    default:
      EmptyView()
    }
  }

  private func requestPreviewZoom(_ action: PreviewZoomAction) {
    previewZoomRequest.request(action)
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

  private func filmTypeDescription(_ filmType: FilmType) -> String {
    switch filmType {
    case .colourNegative:
      "A color negative that needs inversion and orange-mask correction."
    case .blackAndWhiteNegative:
      "A monochrome negative that needs inversion."
    case .slide:
      "A positive transparency; no negative conversion is applied."
    case .cropOnly:
      "An already-positive image; only framing and export are applied."
    }
  }

  private func negativeConversionMode(for params: ProcessingParameters) -> NegativeConversionMode {
    let fn = params.filmNegativeParams
    guard fn.enabled else { return .bypass }
    switch fn.rendering {
    case .calibratedColor, .calibratedMonochrome: return .natural
    case .densityPrint: return .darkroom
    case .powerLaw: return .classic
    }
  }

  private func setNegativeConversionMode(_ mode: NegativeConversionMode) {
    guard mode != negativeConversionMode(for: model.parameters) else { return }
    switch mode {
    case .natural:
      model.setFilmNegativePreset(
        model.parameters.filmType == .blackAndWhiteNegative ? .blackAndWhite : .colourNegative)
    case .darkroom:
      let preset: FilmNegativePreset
      switch model.parameters.filmNegativeParams.calibratedColorProfile {
      case .harmanPhoenixII:
        preset = .densityPrintHarmanPhoenixII
      case .fuji400Fresh:
        preset = .densityPrintFuji400
      case .generic, .fuji200Expired, .cinestill800T:
        preset = .densityPrintGenericC41
      }
      model.setFilmNegativePreset(preset)
    case .classic:
      model.setFilmNegativePreset(
        model.parameters.filmType == .blackAndWhiteNegative
          ? .legacyBlackAndWhite : .legacyColourNegative)
    case .bypass:
      model.setFilmNegativePreset(.off)
    }
  }

  private func naturalPresets(for filmType: FilmType) -> [FilmNegativePreset] {
    switch filmType {
    case .colourNegative:
      [
        .colourNegative,
        .fuji400FreshAlternate,
        .fuji200ExpiredAlternate,
        .cinestill800TAlternate,
        .harmanPhoenixIIAlternate,
      ]
    case .blackAndWhiteNegative:
      [.blackAndWhite, .shanghaiGP3Alternate]
    case .slide, .cropOnly:
      []
    }
  }

  private func naturalPresetTitle(_ preset: FilmNegativePreset) -> String {
    switch preset {
    case .colourNegative, .blackAndWhite: "Balanced"
    case .fuji400FreshAlternate: "Fujicolor 400"
    case .fuji200ExpiredAlternate: "Fujicolor 200 · expired"
    case .cinestill800TAlternate: "CineStill 800T"
    case .harmanPhoenixIIAlternate: "Harman Phoenix II"
    case .shanghaiGP3Alternate: "Shanghai GP3"
    default: preset.displayName
    }
  }

  private func naturalPresetSubtitle(_ preset: FilmNegativePreset) -> String {
    switch preset {
    case .colourNegative:
      "Neutral, flexible color for most negatives"
    case .blackAndWhite:
      "Neutral monochrome starting point"
    case .fuji400FreshAlternate:
      "Fresh-base reference from eight scans"
    case .fuji200ExpiredAlternate:
      "Warmer response for an aged film base"
    case .cinestill800TAlternate:
      "Tungsten-balanced reference response"
    case .harmanPhoenixIIAlternate:
      "Stock-specific curve for Phoenix color"
    case .shanghaiGP3Alternate:
      "Stock-specific monochrome response"
    default:
      ""
    }
  }

  private func paperDescription(_ paper: DensityPaperProfile) -> String {
    switch paper.id.rawValue {
    case DensityPaperProfileCatalog.kodakEnduraPremier.id.rawValue:
      "Deeper blacks with slightly cooler shadows"
    case DensityPaperProfileCatalog.fujiCrystalArchive.id.rawValue:
      "Brilliant whites with a crisp, cool response"
    default:
      "Clean contrast without added paper color"
    }
  }

  private func filmNegativePreset(for params: ProcessingParameters) -> FilmNegativePreset {
    guard params.filmNegativeParams.enabled else { return .off }
    let fn = params.filmNegativeParams
    if fn.rendering == .calibratedColor {
      switch fn.calibratedColorProfile {
      case .generic: return .colourNegative
      case .fuji400Fresh: return .fuji400FreshAlternate
      case .fuji200Expired: return .fuji200ExpiredAlternate
      case .cinestill800T: return .cinestill800TAlternate
      case .harmanPhoenixII: return .harmanPhoenixIIAlternate
      }
    }
    if fn.rendering == .densityPrint {
      switch fn.densityProfileID {
      case NegativeDensityProfileCatalog.harmanPhoenixII.id.rawValue:
        return .densityPrintHarmanPhoenixII
      case NegativeDensityProfileCatalog.fujicolor400.id.rawValue:
        return .densityPrintFuji400
      default:
        return .densityPrintGenericC41
      }
    }
    if fn.rendering == FilmNegativeParams.legacyColourNegative.rendering
      && fn.redRatio == FilmNegativeParams.legacyColourNegative.redRatio
      && fn.greenExp == FilmNegativeParams.legacyColourNegative.greenExp
      && fn.blueRatio == FilmNegativeParams.legacyColourNegative.blueRatio
    {
      return .legacyColourNegative
    }
    if fn.rendering == FilmNegativeParams.blackAndWhite.rendering {
      switch fn.calibratedMonochromeProfile {
      case .generic: return .blackAndWhite
      case .shanghaiGP3: return .shanghaiGP3Alternate
      }
    }
    if fn.rendering == FilmNegativeParams.legacyBlackAndWhite.rendering
      && fn.redRatio == FilmNegativeParams.legacyBlackAndWhite.redRatio
      && fn.greenExp == FilmNegativeParams.legacyBlackAndWhite.greenExp
      && fn.blueRatio == FilmNegativeParams.legacyBlackAndWhite.blueRatio
    {
      return .legacyBlackAndWhite
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
    endActiveOverlay()
  }

  private func beginRebateSelection() {
    endActiveOverlay()
    rebateDragStart = nil
    rebateDragEnd = nil
    overlayPreviousShowOriginal = model.showOriginal
    activeOverlay = .rebate
    model.showOriginal = true
  }

  private func togglePerspectiveEditing() {
    if isPerspectiveEditing {
      endPerspectiveEditing()
      return
    }
    endActiveOverlay()
    overlayPreviousShowOriginal = model.showOriginal
    model.beginPerspectiveCrop()
    activeOverlay = .perspective
    model.showOriginal = true
  }

  private func endPerspectiveEditing() {
    guard isPerspectiveEditing else { return }
    endActiveOverlay()
  }

  private func toggleStraightening() {
    if isStraightening {
      endStraightening()
      return
    }
    endActiveOverlay()
    model.beginManualCropEditing()
    activeOverlay = .straighten
  }

  private func endStraightening() {
    guard isStraightening else { return }
    endActiveOverlay()
  }

  private func toggleCropping() {
    if isCropping {
      endCropping()
      return
    }
    endActiveOverlay()
    model.beginManualCropEditing()
    activeOverlay = .crop
  }

  private func endCropping() {
    guard isCropping else { return }
    endActiveOverlay()
  }

  private func endActiveOverlay() {
    guard let overlay = activeOverlay else { return }
    activeOverlay = nil

    switch overlay {
    case .rebate:
      rebateDragStart = nil
      rebateDragEnd = nil
      restoreShowOriginalAfterOverlay()
    case .perspective:
      restoreShowOriginalAfterOverlay()
    case .straighten, .crop:
      model.endManualCropEditing()
    }
  }

  private func restoreShowOriginalAfterOverlay() {
    guard let previousValue = overlayPreviousShowOriginal else { return }
    overlayPreviousShowOriginal = nil
    model.showOriginal = previousValue
  }

  private func pointText(_ point: PerspectiveCrop.Point) -> String {
    String(format: "%.2f, %.2f", point.x, point.y)
  }
}

private struct RawPreviewUpgradeBar: View {
  @State private var fill: CGFloat = 0

  var body: some View {
    ZStack(alignment: .leading) {
      Capsule()
        .fill(.white.opacity(0.22))
      Capsule()
        .fill(.white.opacity(0.92))
        .scaleEffect(x: fill, y: 1, anchor: .leading)
    }
    .frame(width: 96, height: 3)
    .accessibilityLabel("Loading a sharper preview")
    .onAppear {
      fill = 0
      withAnimation(.easeOut(duration: 1.0)) {
        fill = 0.92
      }
    }
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

private struct InspectorChoiceCard: View {
  let title: String
  let subtitle: String
  let systemImage: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Image(systemName: systemImage)
            .frame(width: 15)
          Text(title)
            .font(.caption.weight(.semibold))
          Spacer(minLength: 0)
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.caption)
          }
        }
        Text(subtitle)
          .font(.caption2)
          .foregroundStyle(isSelected ? Color.primary.opacity(0.8) : Color.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .foregroundStyle(isSelected ? Color.accentColor : .primary)
      .padding(9)
      .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(
            isSelected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.09),
            lineWidth: isSelected ? 1.5 : 1
          )
      )
      .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityValue(isSelected ? "Selected" : "")
  }
}

private struct InspectorChoiceRow: View {
  let title: String
  let subtitle: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
          .padding(.top, 1)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
          if !subtitle.isEmpty {
            Text(subtitle)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(isSelected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.025))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(
            isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.07),
            lineWidth: 1
          )
      )
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityValue(isSelected ? "Selected" : "")
  }
}

private struct InspectorChoiceChip: View {
  let title: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if isSelected {
          Image(systemName: "checkmark")
            .font(.caption2.weight(.bold))
        }
        Text(title)
          .font(.caption)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 0)
      }
      .foregroundStyle(isSelected ? Color.accentColor : .primary)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.025))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(
            isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.07),
            lineWidth: 1
          )
      )
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityValue(isSelected ? "Selected" : "")
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
  fileprivate var compactDisplayName: String {
    switch self {
    case .blackAndWhiteNegative: "B&W Neg."
    case .colourNegative: "Color Neg."
    case .slide: "Slide"
    case .cropOnly: "Original"
    }
  }
}
