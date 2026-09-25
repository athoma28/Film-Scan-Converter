import FilmScanEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @Bindable var model: AppModel
  @ObservedObject var camera: CameraController
  @State private var dropTargeted = false
  @State private var showLivePreview = false
  @State private var inspectorPage: InspectorPage = .develop
  @State private var activeOverlay: PreviewOverlay?
  @State private var rebateDragStart: CGPoint?
  @State private var rebateDragEnd: CGPoint?
  @State private var overlayPreviousShowOriginal: Bool?
  @State private var usesPerspectiveParallelAssist = true
  @State private var presetName = ""
  @State private var isSavingPreset = false
  @FocusState private var isPresetNameFocused: Bool
  @State private var profileName = ""
  @State private var previewZoomRequest = PreviewZoomRequest()
  @State private var previewZoomPercent = 100
  @State private var previewMagnification: CGFloat = 1
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
  private var isAligningStack: Bool {
    !showLivePreview && (model.isBuildingScanStack || model.isUpgradingScanStack)
  }
  private var statusBarMessage: String {
    if isAligningStack, !model.scanStackStatus.isEmpty {
      return model.scanStackStatus
    }
    return showLivePreview ? camera.status : model.status
  }
  private var previewNeedsDraftSoftening: Bool {
    switch model.previewSourceKind {
    case .rawDraft: true
    case .alignedStack:
      model.selectedImageDimensions?.provisional == true
        && max(model.previewImage?.size.width ?? 0, model.previewImage?.size.height ?? 0)
          <= CGFloat(AppModel.rawDraftPreviewMaxDimension + 16)
    default: false
    }
  }

  private enum InspectorPage: String, CaseIterable, Identifiable {
    case develop = "Develop"
    case geometry = "Geometry"
    case calibration = "Calibrate"
    case export = "Export"

    var id: Self { self }

    var systemImage: String {
      switch self {
      case .develop: "slider.horizontal.3"
      case .geometry: "crop.rotate"
      case .calibration: "viewfinder"
      case .export: "square.and.arrow.up"
      }
    }
  }

  var body: some View {
    NavigationSplitView {
      ViewUpdateScope {
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
                .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 4, trailing: 6))
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
      }
    } detail: {
      VStack(spacing: 0) {
        ViewUpdateScope { toolbar }
        Divider()
        HStack(spacing: 0) {
          ViewUpdateScope {
            preview
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          ViewUpdateScope {
            if !showLivePreview, model.hasPreviewImage {
              Divider()
              inspector
                .frame(width: 390)
                .frame(maxHeight: .infinity)
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        ViewUpdateScope {
          HStack(spacing: 8) {
            if isAligningStack {
              ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            }
            Text(statusBarMessage)
              .foregroundStyle(
                (showLivePreview ? camera.statusKind : model.statusKind) == .error
                  ? Color.red : Color.secondary
              )
              .lineLimit(1)
            if isAligningStack {
              ProgressView()
                .progressViewStyle(.linear)
                .frame(maxWidth: 168)
                .accessibilityHidden(true)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .font(.caption)
          .accessibilityElement(children: .combine)
          .accessibilityLabel(statusBarMessage)
        }
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
      showLivePreview || !model.hasPreviewImage
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
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "square.stack.3d.up.fill")
          .foregroundStyle(Color.accentColor)
        Text("\(stack.members.count)-capture stack")
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Text("\(Int((stack.confidence * 100).rounded()))%")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer(minLength: 4)
        Toggle(
          "Use aligned stack",
          isOn: Binding(
            get: { model.isScanStackEnabled(stack) },
            set: { model.setScanStackEnabled($0, for: stack) }
          )
        )
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .disabled(
          model.isExporting || model.isAnalyzingScanStacks || model.isLoading
            || model.flatFieldImage != nil)
      }

      if model.isScanStackEnabled(stack) {
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
        .controlSize(.mini)
        .disabled(model.isExporting || model.isAnalyzingScanStacks)
        .help(
          "Auto chooses HDR for bracketed exposures and noise reduction otherwise. Switching modes updates the aligned preview."
        )

        if let effective = model.scanStackEffectiveMode,
          !model.isBuildingScanStack, !model.isUpgradingScanStack
        {
          Text(
            effective == .hdr
              ? "Combining as HDR."
              : "Combining for noise reduction."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
      }

      if model.isAnalyzingScanStacks {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
          Text("Checking imports…")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      } else if model.scanStackStatusID == stack.id,
        model.isBuildingScanStack || model.isUpgradingScanStack,
        model.isScanStackEnabled(stack)
      {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
          Text(model.scanStackStatus)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      } else if model.scanStackStatusID == stack.id,
        model.isScanStackEnabled(stack), !model.scanStackStatus.isEmpty
      {
        Text(model.scanStackStatus)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else if model.flatFieldImage != nil {
        Text("Clear flat field before stacking.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .controlSize(.small)
    .padding(8)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .help(scanStackProposalDescription(stack))
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

      Button(action: { model.moveSelectedSidebarFile(by: -1) }) {
        Image(systemName: "arrow.up.to.line")
          .frame(width: 18)
      }
      .disabled(!model.canMoveSelectedSidebarFileUp)
      .help("Move selected scan up")
      .accessibilityLabel("Move selected scan up")

      Button(action: { model.moveSelectedSidebarFile(by: 1) }) {
        Image(systemName: "arrow.down.to.line")
          .frame(width: 18)
      }
      .disabled(!model.canMoveSelectedSidebarFileDown)
      .help("Move selected scan down")
      .accessibilityLabel("Move selected scan down")

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

      if !showLivePreview, model.hasPreviewImage {
        if model.canLoadRawDetailPreview {
          Button(action: model.loadRawDetailPreview) {
            Label("Load RAW Preview", systemImage: "sparkles.rectangle.stack")
          }
          .help("Continue loading the inspect and full-resolution RAW previews")
        }

        Toggle(isOn: $model.showOriginal) {
          Label("Original", systemImage: "rectangle.on.rectangle")
        }
        .toggleStyle(.button)
        .disabled(isPickingRebateRegion || isPerspectiveEditing)
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
    case .develop: developInspector
    case .geometry: geometryInspector
    case .calibration: calibrationInspector
    case .export: exportInspector
    }
  }

  private var developQuickActionsBar: some View {
    VStack(spacing: 6) {
      HStack(spacing: 6) {
        Button(action: model.copyCorrectionSettings) {
          Image(systemName: "doc.on.doc")
            .frame(width: 16)
        }
        .help("Copy corrections (⌘⌥C)")

        Button(action: model.pasteCorrectionSettings) {
          Image(systemName: "doc.on.clipboard")
            .frame(width: 16)
        }
        .disabled(!model.canPasteCorrectionSettings)
        .help("Paste corrections (⌘⌥V)")

        Spacer()

        Menu {
          Button(
            "Apply Look to Selected (\(model.selectedFileCount))",
            action: model.applyCurrentLookToSelectedFiles
          )
          .disabled(model.selectedFileCount < 2)
          Button(
            "Apply Settings to All Open Files", action: model.applyCurrentSettingsToAllOpenFiles)
          Divider()
          Button("Reset Adjustments", action: model.resetDevelopAdjustments)
            .disabled(!model.hasPreviewImage)
        } label: {
          Image(systemName: "ellipsis.circle")
            .frame(width: 16)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Batch and roll actions")
      }
      .controlSize(.small)
      .buttonStyle(.bordered)
      .padding(.horizontal, 2)

      if !model.settingsStatus.isEmpty {
        Text(model.settingsStatus)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func saveNamedPreset() {
    let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    guard model.saveCorrectionPreset(named: name) else { return }
    presetName = ""
    isSavingPreset = false
  }

  private var filmBaseSection: some View {
    let base = FilmBase.resolved(from: model.parameters)
    return InspectorSection("Film Base", systemImage: "film", isModified: base != .original) {
      VStack(alignment: .leading, spacing: 8) {
        Picker(
          "Film Base",
          selection: Binding(
            get: { base },
            set: { model.setFilmBase($0) }
          )
        ) {
          ForEach(FilmBase.allCases) { option in
            Text(option.title).tag(option)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .help(base.summary)
        Text(
          model.parameters.filmBaseChosenByUser ? "You chose this film base." : "Guessed from scan."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        Text(base.summary)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var presetBeingReplaced: NamedCorrectionPreset? {
    model.namedCorrectionPresets.first {
      NamedCorrectionPresetStore.namesMatch($0.name, presetName)
    }
  }

  private var presetsSection: some View {
    let base = FilmBase.resolved(from: model.parameters)
    let appliedName = model.appliedPresetName
    let recommended = LookRecipe.recommended(for: base)
    let others = LookRecipe.factory.filter { !$0.recommendedFilmBases.contains(base) }
    return InspectorSection(
      "Presets", systemImage: "square.stack", isModified: appliedName != nil
    ) {
      VStack(alignment: .leading, spacing: 8) {
        if base.supportsLooks {
          Menu {
            if !recommended.isEmpty {
              Section("Recommended") {
                ForEach(recommended) { recipe in
                  presetButton(recipe)
                }
              }
            }
            if !others.isEmpty {
              Section("Other Factory Looks") {
                ForEach(others) { recipe in
                  presetButton(recipe)
                }
              }
            }
            if !model.namedCorrectionPresets.isEmpty {
              Section("Saved Presets") {
                ForEach(model.namedCorrectionPresets) { preset in
                  Button {
                    model.applyCorrectionPreset(preset)
                  } label: {
                    presetLabel(
                      preset.name, matches: preset.settings.recipe.matches(model.parameters))
                  }
                }
              }
            }
          } label: {
            Text(appliedName ?? "Custom — Choose a Preset")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .menuStyle(.borderedButton)
          .accessibilityLabel("Choose a preset")
          .accessibilityValue(appliedName ?? "Custom")
          .help("Apply a look, then refine it with the tone and color controls below.")

          if isSavingPreset {
            VStack(alignment: .leading, spacing: 6) {
              TextField("Preset name", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .focused($isPresetNameFocused)
                .onSubmit { saveNamedPreset() }
                .onAppear { isPresetNameFocused = true }
                .onExitCommand { isSavingPreset = false }
              if let replacement = presetBeingReplaced {
                Text("This will replace “\(replacement.name)”.")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              HStack(spacing: 6) {
                Button(presetBeingReplaced == nil ? "Save" : "Replace") { saveNamedPreset() }
                  .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { isSavingPreset = false }
              }
            }
          } else {
            Button("Save current as preset…") {
              presetName = ""
              isSavingPreset = true
            }
          }
        } else {
          Text("Choose a negative or Slide film base to use tone, color, and presets.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if !model.namedCorrectionPresets.isEmpty {
          Menu("Manage Saved Presets") {
            ForEach(model.namedCorrectionPresets) { preset in
              Menu(preset.name) {
                Button("Delete Preset", role: .destructive) {
                  model.deleteCorrectionPreset(preset)
                }
              }
            }
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
        }
      }
      .controlSize(.small)
    }
  }

  @ViewBuilder
  private func presetLabel(_ title: String, matches: Bool) -> some View {
    if matches {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }

  private func presetButton(_ recipe: LookRecipe) -> some View {
    Button {
      model.applyLookRecipe(recipe)
    } label: {
      presetLabel(recipe.title, matches: recipe.matches(model.parameters))
    }
    .help(recipe.summary)
  }

  private var advancedColorScienceControls: some View {
    let mixing = model.parameters.filmDyeMixing
    return VStack(alignment: .leading, spacing: 8) {
      Text("Cross-talk matrix for dye contamination")
        .font(.caption2)
        .foregroundStyle(.secondary)

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
  }

  private var developInspector: some View {
    LazyVStack(spacing: 10) {
      developQuickActionsBar
      filmBaseSection
      presetsSection
      lightSection
        .disabled(!FilmBase.resolved(from: model.parameters).supportsLooks)
      colorSection
        .disabled(!FilmBase.resolved(from: model.parameters).supportsLooks)
      Button(action: model.resetDevelopAdjustments) {
        Label("Reset Adjustments", systemImage: "arrow.counterclockwise")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .disabled(!model.hasPreviewImage)
      .padding(.top, 4)
    }
  }

  private var lightSection: some View {
    InspectorSection(
      "Tone & Light",
      systemImage: "sun.max",
      isModified: model.parameters.photoAdjustments.hasToneAdjustment
        || model.parameters.curveEnabled
    ) {
      VStack(alignment: .leading, spacing: 8) {
        if !model.parameters.photoAdjustments.usesPhotographicTone {
          Text(
            "This saved edit uses the original tone controls. Updating changes its appearance and can be undone."
          )
          .font(.caption).foregroundStyle(.secondary)
          Button("Update Tone Controls") { model.upgradeToneControls() }
        }
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

        if model.parameters.photoAdjustments.usesPhotographicTone {
          AdjustmentSlider(
            "Whites",
            value: Binding(
              get: { model.parameters.photoAdjustments.whites },
              set: { model.setWhites($0) }),
            range: -1...1, neutral: 0, valueFormat: "%.3f", responseExponent: 1.6)
          AdjustmentSlider(
            "Blacks",
            value: Binding(
              get: { model.parameters.photoAdjustments.blacks },
              set: { model.setBlacks($0) }),
            range: -1...1, neutral: 0, valueFormat: "%.3f", responseExponent: 1.6)
        }
        Divider()
          .padding(.vertical, 2)

        DisclosureGroup("Tone Curve") {
          VStack(alignment: .leading, spacing: 8) {
            Toggle(
              "Enable Tone Curve",
              isOn: Binding(
                get: { model.parameters.curveEnabled },
                set: { model.setCurveEnabled($0) }
              )
            )
            .font(.caption)
            IntegratedCurvesView(model: model)
          }
          .padding(.top, 4)
        }
        .font(.caption.weight(.medium))

        let low = model.previewStatistics.lowClippingRatios
        let high = model.previewStatistics.highClippingRatios
        let maxShadowClip = max(low.blue, low.green, low.red) * 100
        let maxHighlightClip = max(high.blue, high.green, high.red) * 100
        if maxShadowClip > 0.05 || maxHighlightClip > 0.05 {
          HStack {
            Text("Clipping:")
              .font(.caption2)
              .foregroundStyle(.secondary)
            if maxShadowClip > 0.05 {
              Text("Shadows \(String(format: "%.1f", maxShadowClip))%")
                .font(.caption2)
                .foregroundStyle(maxShadowClip > 2.0 ? .orange : .secondary)
            }
            if maxHighlightClip > 0.05 {
              Text("Highlights \(String(format: "%.1f", maxHighlightClip))%")
                .font(.caption2)
                .foregroundStyle(maxHighlightClip > 2.0 ? .orange : .secondary)
            }
          }
        }
      }
    }
    .disabled(!model.parameters.filmType.supportsToneCorrections)
  }

  private var colorSection: some View {
    let hasWheels =
      !model.parameters.highlightWheel.isNeutral
      || !model.parameters.midtoneWheel.isNeutral
      || !model.parameters.shadowWheel.isNeutral
    let grading = model.parameters.photoAdjustments
    let hasPointAdjustment =
      grading.shadowFloor != 0 || grading.midtoneLevel != 0 || grading.highlightCeiling != 0
    let isModified = grading.hasColorAdjustment || hasWheels || hasPointAdjustment

    return InspectorSection(
      "Color & Balance",
      systemImage: "paintpalette",
      isModified: isModified
    ) {
      VStack(alignment: .leading, spacing: 8) {
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
        if model.parameters.filmType.supportsColorCorrections {
          AdjustmentSlider(
            "Foliage Recovery",
            value: Binding(
              get: { (model.parameters.photoAdjustments.warmHueRecovery ?? 0) * 100 },
              set: { model.setWarmHueRecovery($0 / 100) }
            ),
            range: 0...100, neutral: 0, valueFormat: "%.0f", unitSuffix: "%"
          )
          .help("Move copper foliage toward olive green. Lower it if wood or skin shifts too far.")
        }
        if FilmBase.resolved(from: model.parameters).usesDensityPrint {
          AdjustmentSlider(
            "Cast Cleanup",
            value: Binding(
              get: {
                let fn = model.parameters.filmNegativeParams
                let profile = DensityPrintProcessing.resolvedProfile(from: fn)
                return (fn.densityCastRemovalStrength ?? profile.castRemovalStrength) * 100
              },
              set: { model.setDensityCastRemovalStrength($0 / 100) }
            ),
            range: 0...100, neutral: 50, valueFormat: "%.0f", unitSuffix: "%"
          )
          .help("Reduce unwanted casts where neutral tones can be identified.")
          AdjustmentSlider(
            "Color Separation",
            value: Binding(
              get: {
                let fn = model.parameters.filmNegativeParams
                let profile = NegativeDensityProfileCatalog.profile(id: fn.densityProfileID)
                return
                  (fn.densityUnmixStrength >= 0 ? fn.densityUnmixStrength : profile.unmixStrength)
                  * 100
              },
              set: { model.setDensityUnmixStrength($0 / 100) }
            ),
            range: 0...100, neutral: 45, valueFormat: "%.0f", unitSuffix: "%"
          )
        }

        Divider()
          .padding(.vertical, 2)

        DisclosureGroup("Color Grading Wheels") {
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
              VStack(spacing: 8) {
                ColorWheelControl(
                  title: "Shadows",
                  hue: model.parameters.shadowWheel.hue,
                  strength: model.parameters.shadowWheel.strength,
                  setValue: model.setShadowWheel
                )
                .frame(height: 120)
                GradingPointSlider(
                  "Shadow Floor",
                  value: Binding(
                    get: { model.parameters.photoAdjustments.shadowFloor },
                    set: { model.setShadowFloor($0) }),
                  help:
                    "Raise the black point for softer shadows. Unlike Blacks, this lifts the darkest output values."
                )
                .disabled(!grading.usesPhotographicTone)
              }
              .frame(maxWidth: .infinity)
              VStack(spacing: 8) {
                ColorWheelControl(
                  title: "Midtones",
                  hue: model.parameters.midtoneWheel.hue,
                  strength: model.parameters.midtoneWheel.strength,
                  setValue: model.setMidtoneWheel
                )
                .frame(height: 120)
                GradingPointSlider(
                  "Midtone Level",
                  value: Binding(
                    get: { model.parameters.photoAdjustments.midtoneLevel },
                    set: { model.setMidtoneLevel($0) }),
                  help:
                    "Shift the middle tonal level while keeping the black and white endpoints anchored."
                )
                .disabled(!grading.usesPhotographicTone)
              }
              .frame(maxWidth: .infinity)
              VStack(spacing: 8) {
                ColorWheelControl(
                  title: "Highlights",
                  hue: model.parameters.highlightWheel.hue,
                  strength: model.parameters.highlightWheel.strength,
                  setValue: model.setHighlightWheel
                )
                .frame(height: 120)
                GradingPointSlider(
                  "Highlight Ceiling",
                  value: Binding(
                    get: { model.parameters.photoAdjustments.highlightCeiling },
                    set: { model.setHighlightCeiling($0) }),
                  help:
                    "Lower the white point to soften the brightest output values. This differs from Whites."
                )
                .disabled(!grading.usesPhotographicTone)
              }
              .frame(maxWidth: .infinity)
            }

            if !grading.usesPhotographicTone {
              Text(
                "Update Tone Controls above to use Floor, Level, and Ceiling on this saved edit."
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
            }
            Text("Drag from center to tint. Double-click a wheel or point slider to reset.")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          .padding(.top, 4)
        }
        .font(.caption.weight(.medium))
      }
    }
    .disabled(!model.parameters.filmType.supportsColorCorrections)
  }

  private var geometryInspector: some View {
    VStack(spacing: 10) {
      InspectorSection("Orientation", systemImage: "arrow.triangle.2.circlepath") {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            Button(action: model.rotateCounterclockwise) {
              Label("Rotate Left", systemImage: "rotate.left")
                .frame(maxWidth: .infinity)
            }
            .help("Rotate 90° counterclockwise")

            Button(action: model.rotateClockwise) {
              Label("Rotate Right", systemImage: "rotate.right")
                .frame(maxWidth: .infinity)
            }
            .help("Rotate 90° clockwise")

            Button(action: model.toggleFlip) {
              Label(
                "Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .help("Flip horizontally")
          }
          .controlSize(.small)

          HStack(spacing: 8) {
            Button(action: toggleStraightening) {
              Label(
                isStraightening ? "Cancel Straighten" : "Straighten Edge…",
                systemImage: isStraightening ? "xmark" : "line.diagonal"
              )
              .frame(maxWidth: .infinity)
            }
            .controlSize(.small)

            if abs(model.straightenAngle) > 0.000_001 {
              HStack(spacing: 4) {
                Text("\(String(format: "%+.1f", model.straightenAngle))°")
                  .font(.caption2.monospacedDigit())
                Button("Clear", action: model.clearStraightening)
                  .controlSize(.mini)
              }
            }
          }

          if isStraightening {
            Text("Click two points along an edge that should be vertical or horizontal.")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }

      InspectorSection("Crop & Framing", systemImage: "crop") {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            Button(action: model.detectCrop) {
              if model.isCropDetectionRunning {
                ProgressView()
                  .controlSize(.small)
              } else {
                Label("Auto Frame", systemImage: "sparkles")
              }
            }
            .disabled(
              model.decodedImage == nil || model.isCropDetectionRunning || isPerspectiveEditing)

            Button(action: toggleCropping) {
              Label(
                isCropping ? "Done" : "Manual Crop",
                systemImage: isCropping ? "checkmark" : "crop"
              )
            }
            .disabled(model.decodedImage == nil || isPerspectiveEditing)

            Button(action: togglePerspectiveEditing) {
              Label(
                isPerspectiveEditing ? "Done" : "Perspective",
                systemImage: isPerspectiveEditing ? "checkmark" : "square.on.square.dashed"
              )
            }
            .disabled(model.decodedImage == nil)
          }
          .controlSize(.small)

          if isCropping {
            Picker(
              "Crop Ratio",
              selection: Binding(
                get: { model.parameters.manualCropAspectRatio },
                set: { model.setManualCropAspectRatio($0) })
            ) {
              ForEach(CropAspectRatio.allCases, id: \.self) { ratio in
                Text(ratio.rawValue).tag(ratio)
              }
            }
            .controlSize(.small)
            .help("Fit the current crop to a ratio and keep it fixed while adjusting the handles.")
            Text(
              "Drag a rectangle to crop, then adjust the handles. Drag inside the box to move it, or outside to replace it."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
          }

          if isPerspectiveEditing {
            VStack(alignment: .leading, spacing: 6) {
              Picker(
                "Frame Ratio",
                selection: Binding(
                  get: { model.perspectiveOutputAspectRatio },
                  set: { model.setPerspectiveOutputAspectRatio($0) }
                )
              ) {
                ForEach(CropAspectRatio.allCases, id: \.self) { ratio in
                  Text(ratio == .free ? "Automatic" : ratio.rawValue).tag(ratio)
                }
              }
              .controlSize(.small)
              .help(
                "Choose the film frame’s known proportions to correct foreshortening. Automatic estimates from its edges."
              )
              Text(
                "Drag corners to film edges. Arrow keys move the selected corner one pixel; Shift moves ten. Option disables assist."
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
              Toggle("Parallel-edge assist", isOn: $usesPerspectiveParallelAssist)
                .controlSize(.small)
              Button("Reset Corners") {
                model.resetPerspectiveCorners()
              }
              .controlSize(.small)
            }
          }

          if model.perspectiveCrop != nil {
            Divider()
            HStack {
              Text("Perspective Crop Applied")
                .font(.caption2.weight(.medium))
              Spacer()
              Button("Clear") {
                endPerspectiveEditing()
                model.clearPerspectiveCrop()
              }
              .controlSize(.small)
            }
          } else if let cropRect = model.cropRect {
            Divider()
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text("Detected Frame (\(String(format: "%.1f", cropRect.angle))°)")
                  .font(.caption2.weight(.medium))
                if let dimensions = model.selectedDetectedFrameDimensions {
                  Text("\(dimensions.width) × \(dimensions.height) px")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              Button("Clear", action: model.clearCrop)
                .controlSize(.small)
            }
          }
          if model.manualCrop != nil {
            Divider()
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text("Manual Crop")
                  .font(.caption2.weight(.medium))
                if let dimensions = model.selectedCanvasDimensions {
                  Text("\(dimensions.width) × \(dimensions.height) px")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              Button("Clear", action: model.clearManualCrop)
                .controlSize(.small)
            }
          }

          if let output = model.selectedCanvasDimensions {
            HStack {
              Text("Canvas")
                .font(.caption2)
                .foregroundStyle(.secondary)
              Spacer()
              Text("\(output.width) × \(output.height) px")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }

          if !model.cropStatus.isEmpty, !model.isCropDetectionRunning {
            Text(model.cropStatus)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          DisclosureGroup("Detection Thresholds") {
            VStack(alignment: .leading, spacing: 6) {
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
            }
            .padding(.top, 4)
          }
          .font(.caption)
        }
      }

      InspectorSection("Dust Mask", systemImage: "sparkles") {
        VStack(alignment: .leading, spacing: 6) {
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
              ? "Non-destructive overlay for dust particle removal."
              : model.dustStatus
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var calibrationInspector: some View {
    VStack(spacing: 10) {
      InspectorSection("Film Base (Rebate)", systemImage: "viewfinder") {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            Button(action: model.detectRebate) {
              if model.isRebateDetectionRunning {
                ProgressView()
                  .controlSize(.small)
              } else {
                Label("Auto Detect Edge", systemImage: "viewfinder")
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
                isPickingRebateRegion ? "Cancel" : "Sample Area",
                systemImage: isPickingRebateRegion ? "xmark" : "rectangle.dashed"
              )
            }
            .disabled(model.decodedImage == nil)
          }
          .controlSize(.small)

          HStack {
            Button(action: model.loadFlatField) {
              Label("Flat Field", systemImage: "rectangle.split.1x2")
            }
            .controlSize(.small)

            if let ffURL = model.flatFieldURL {
              Text(ffURL.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

              Button(action: model.clearFlatField) {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .controlSize(.small)
            }
          }

          if !model.rebateCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
              Text("Candidates:")
                .font(.caption2)
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
                Text("Base Density (RGB)")
                  .font(.caption.weight(.medium))
                Spacer()
                Button("Clear", action: model.clearRebateMeasurement)
                  .font(.caption2)
              }
              HStack(spacing: 8) {
                Text("R: \(String(format: "%.3f", measurement.baseDensity.red))")
                Text("G: \(String(format: "%.3f", measurement.baseDensity.green))")
                Text("B: \(String(format: "%.3f", measurement.baseDensity.blue))")
              }
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)

              if let firstCandidate = model.rebateCandidates.first(where: {
                $0.measurement == measurement
              }) {
                Button {
                  model.createRollProfile(from: firstCandidate)
                } label: {
                  Label("Save Roll Profile", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
                .padding(.top, 2)
              }
            }
          }
          if !model.rebateStatus.isEmpty, !model.isRebateDetectionRunning {
            Text(model.rebateStatus)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .disabled(!supportsFilmNegative(filmType: model.parameters.filmType))

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
            .font(.caption.weight(.medium))

            if model.parameters.densityPipelineEnabled,
              let baseDensity = model.parameters.densityBaseDensity
            {
              Text(
                "Base: R\(String(format: "%.3f", baseDensity.red)) G\(String(format: "%.3f", baseDensity.green)) B\(String(format: "%.3f", baseDensity.blue))"
              )
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
              Text(
                "C-41: slopes R\(String(format: "%.2f", model.parameters.densityC41Profile.densitySlope.red)) G\(String(format: "%.2f", model.parameters.densityC41Profile.densitySlope.green)) B\(String(format: "%.2f", model.parameters.densityC41Profile.densitySlope.blue))"
              )
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
              Text(
                model.parameters.densityCorrection == .identity
                  ? "Capture matrix: Identity"
                  : "Capture matrix: Custom fitted correction"
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
            }
          }
        }
      }

      InspectorSection("Workflow Profiles", systemImage: "square.stack.3d.up") {
        VStack(alignment: .leading, spacing: 8) {
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
            .controlSize(.small)

          DisclosureGroup("Save current as profile") {
            HStack {
              TextField("Profile name", text: $profileName)
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
            .padding(.top, 4)
          }
          .font(.caption)

          if !model.profileStatus.isEmpty {
            Text(model.profileStatus)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }

      InspectorSection("Advanced Color Science", systemImage: "slider.horizontal.below.rectangle") {
        advancedColorScienceControls
      }
      .disabled(model.parameters.filmType != .colourNegative)
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
            if !model.isExportingContactSheet {
              Button(
                model.selectedExportItemCount > 1
                  ? "Add Selected (\(model.selectedExportItemCount))"
                  : "Add Selected",
                action: model.addSelectedToExportQueue
              )
              .buttonStyle(.borderedProminent)
              .frame(maxWidth: .infinity)
            }
            Button("Cancel", role: .cancel, action: model.cancelExport)
              .buttonStyle(.bordered)
              .frame(maxWidth: .infinity)
          }
          Text(
            model.isExportingContactSheet
              ? "\(model.exportQueueCount) scans waiting"
              : model.exportQueueCount == 1
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

      InspectorSection("Contact Sheet", systemImage: "square.grid.3x3") {
        Text(
          "A Letter-size PDF with 12 scans per page, filenames, and current crops and corrections."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("Save Selected PDF") { model.exportContactSheet() }
            .disabled(model.selectedExportItemCount == 0)
          Button("Save All PDF") { model.exportContactSheet(allFiles: true) }
            .disabled(model.files.isEmpty)
        }
        .disabled(
          model.exportParameters.destinationDirectory == nil || model.isExporting || model.isLoading
            || model.isBuildingScanStack)
        if let url = model.lastContactSheetURL {
          Button("Open Contact Sheet") { NSWorkspace.shared.open(url) }
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
            onZoomChanged: { percent, isFit, magnification in
              previewZoomPercent = percent
              previewMagnification = magnification
              previewIsFit = isFit
            },
            onRenderDemandChanged: model.setPreviewRenderDemand,
            interactionTrace: model.previewInteractionTrace,
            renderRevision: model.publishedRenderRevision
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
    let magnification = previewMagnification
    return ZStack {
      RasterImage(image: image, interpolation: .high)
        .frame(width: image.size.width, height: image.size.height)
        .blur(radius: previewNeedsDraftSoftening ? 1.6 : 0)

      if let detail = model.previewDetail {
        RasterImage(image: detail.image, interpolation: .high)
          .frame(width: detail.rect.width, height: detail.rect.height)
          .position(x: detail.rect.midX, y: detail.rect.midY)
          .allowsHitTesting(false)
      }

      if let dustMask = model.dustMaskImage {
        RasterImage(image: dustMask, interpolation: .none)
          .frame(width: image.size.width, height: image.size.height)
          .blendMode(.screen)
          .opacity(0.85)
          .allowsHitTesting(false)
      }

      if isPickingRebateRegion {
        RebateRegionSelectionOverlay(
          isActive: true,
          imageSize: image.size,
          magnification: magnification,
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

      if isPerspectiveEditing {
        PerspectiveCropOverlay(
          isActive: true,
          crop: model.perspectiveCrop,
          image: image,
          imageSize: image.size,
          sourceDimensions: model.sourcePixelDimensions,
          borderPercent: model.parameters.borderCrop,
          rotation: model.parameters.rotation,
          flipHorizontally: model.parameters.flip,
          usesParallelAssist: usesPerspectiveParallelAssist,
          magnification: magnification,
          onCropChanged: model.setPerspectiveCrop
        )
      }

      if isStraightening {
        StraightenLineOverlay(
          isActive: true,
          imageSize: image.size,
          magnification: magnification,
          onGuideCompleted: { deviation in
            endStraightening()
            model.straighten(usingGuideDeviation: deviation)
          }
        )
      }

      if isCropping {
        ManualCropOverlay(
          isActive: true,
          crop: model.manualCrop,
          imageSize: image.size,
          magnification: magnification,
          aspectRatio: model.normalizedManualCropAspectRatio,
          onCropChanged: model.setManualCrop
        )
      }

      if model.previewInteractionTrace != nil {
        // Keep the diagnostic marker in the same hosted content update as the
        // raster. The diagnostic centers the image at both Fit and 100%.
        PreviewRevisionMarker(revision: model.publishedRenderRevision)
          .scaleEffect(1 / max(magnification, 0.02))
      }
    }
    .frame(width: image.size.width, height: image.size.height)
  }

  @ViewBuilder
  private var previewCanvasChrome: some View {
    let stacking = isAligningStack
    let provisionalStack =
      model.previewSourceKind == .alignedStack
      && model.selectedImageDimensions?.provisional == true
    let showDraftBar = model.previewSourceKind == .rawDraft || stacking || provisionalStack
    let showBadge =
      model.previewSourceKind == .embeddedRAW
      || model.previewSourceKind == .alignedStack
      || stacking
    if showDraftBar || showBadge {
      VStack(spacing: 0) {
        HStack {
          if showBadge {
            previewSourceBadge
          }
          Spacer()
        }
        .padding(10)
        Spacer()
        if stacking {
          alignmentCanvasStatusBar
        } else if showDraftBar {
          RawPreviewUpgradeBar()
            .padding(.bottom, 14)
        }
      }
      .allowsHitTesting(false)
    }
  }

  private var alignmentCanvasStatusBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
          .tint(.white)
          .accessibilityHidden(true)
        Text(model.scanStackStatus)
          .font(.caption.weight(.medium))
          .foregroundStyle(.white)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      ProgressView()
        .progressViewStyle(.linear)
        .tint(.white)
        .accessibilityHidden(true)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.black.opacity(0.78))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(model.scanStackStatus)
  }

  @ViewBuilder
  private var previewSourceBadge: some View {
    if isAligningStack {
      Label(
        model.isUpgradingScanStack ? "Updating aligned stack" : "Aligning stack",
        systemImage: "square.stack.3d.up.fill"
      )
      .font(.caption2.weight(.medium))
      .foregroundStyle(.white)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(.black.opacity(0.72), in: Capsule())
      .help(model.scanStackStatus)
    } else {
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
        Label(alignedStackBadgeTitle, systemImage: "square.stack.3d.up.fill")
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
  }

  private var alignedStackBadgeTitle: String {
    switch model.scanStackEffectiveMode {
    case .hdr: "HDR stack"
    case .noiseReduction: "Noise-reduction stack"
    default: "Aligned stack"
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

  private func supportsFilmNegative(filmType: FilmType) -> Bool {
    filmType == .colourNegative || filmType == .blackAndWhiteNegative
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
    model.beginSourceGeometryEditing()
    model.showOriginal = true
  }

  private func togglePerspectiveEditing() {
    if isPerspectiveEditing {
      endPerspectiveEditing()
      return
    }
    endActiveOverlay()
    overlayPreviousShowOriginal = model.showOriginal
    model.beginSourceGeometryEditing()
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
    model.endSourceGeometryEditing()
    guard let previousValue = overlayPreviousShowOriginal else { return }
    overlayPreviousShowOriginal = nil
    model.showOriginal = previousValue
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
  var isModified: Bool
  @ViewBuilder let content: Content
  @State private var isExpanded: Bool

  init(
    _ title: String,
    systemImage: String,
    isModified: Bool = false,
    defaultExpanded: Bool = true,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.isModified = isModified
    self.content = content()
    self._isExpanded = State(initialValue: defaultExpanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(.easeInOut(duration: 0.18)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 7) {
          Image(systemName: systemImage)
            .foregroundStyle(.secondary)
            .frame(width: 16)
          Text(title)
            .foregroundStyle(.primary)

          if isModified {
            Circle()
              .fill(Color.accentColor)
              .frame(width: 6, height: 6)
          }

          Spacer()

          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        .font(.subheadline.weight(.semibold))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        content
          .padding(.top, 2)
      }
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

private struct GradingPointSlider: View {
  let title: String
  @Binding var value: Double
  let help: String
  @Environment(\.editingGestureAction) private var editingGestureAction

  init(_ title: String, value: Binding<Double>, help: String) {
    self.title = title
    self._value = value
    self.help = help
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 2) {
        Text(title)
          .font(.caption2.weight(.medium))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
        Spacer(minLength: 0)
        Button {
          value = 0
        } label: {
          Image(systemName: "arrow.counterclockwise")
            .font(.system(size: 9, weight: .medium))
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(abs(value) < 0.0005 ? .tertiary : .secondary)
        .disabled(abs(value) < 0.0005)
        .help("Reset \(title)")
      }
      Slider(
        value: Binding(
          get: {
            AdjustmentSliderResponse.position(
              for: value, range: PhotoAdjustmentParameters.gradingPointRange,
              neutral: 0, exponent: 1.6)
          },
          set: {
            value = AdjustmentSliderResponse.value(
              for: $0, range: PhotoAdjustmentParameters.gradingPointRange,
              neutral: 0, exponent: 1.6)
          }),
        in: PhotoAdjustmentParameters.gradingPointRange,
        onEditingChanged: { editingGestureAction(title, $0) }
      )
      .controlSize(.mini)
      .onTapGesture(count: 2) { value = 0 }
      .accessibilityLabel(title)
      .accessibilityValue(String(format: "%+.2f", value))
      Text(String(format: "%+.2f", value))
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(help)
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
