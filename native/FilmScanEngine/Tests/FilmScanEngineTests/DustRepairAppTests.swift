import AppKit
import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Dust repair app workflow", .serialized)
@MainActor
struct DustRepairAppTests {
  @Test("Mask editing changes candidates without changing the scan or its corrections")
  func editableMaskIsSeparateFromRepair() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    let before = model.parameters
    model.beginDustEditing()
    model.paintDustMask(points: [SIMD2(0.5, 0.5)], radius: 0.02, erasing: false)
    let marked = try #require(model.dustSourceMask)
    #expect(marked.pixels.contains { $0 != 0 })
    #expect(model.parameters == before)
    model.showDustMask = false
    #expect(model.dustMaskImage == nil)
    #expect(model.dustSourceMask == marked)
    model.showDustMask = true
    #expect(model.dustMaskImage != nil)
    model.paintDustMask(points: [SIMD2(0.5, 0.5)], radius: 0.025, erasing: true)
    #expect(model.dustSourceMask?.pixels.allSatisfy { $0 == 0 } == true)
    #expect(model.parameters == before)

    model.detectDustMask()
    try await waitUntil { !model.isDustDetectionRunning }
    #expect(model.dustSourceMask != nil)
    #expect(model.parameters == before)
    #expect(try Data(contentsOf: fixture.input) == fixture.inputBytes)
  }

  @Test("Healing is undoable, saved on relaunch, and kept local during look application")
  func healingPersistenceAndUndo() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = PerFileSettingsStore(baseDirectory: fixture.directory)
    let model = try await loadedModel(fixture, store: store)
    model.beginDustEditing()
    await model.addDustRepair(
      points: [SIMD2(0.5, 0.5)], radius: 0.025, sourcePoint: SIMD2(0.3, 0.5))?.value
    let repairs = model.parameters.dustRepairs
    #expect(repairs.count == 1)
    #expect(model.undoActionName == "Healing Brush")
    model.undo()
    #expect(model.parameters.dustRepairs.isEmpty)
    model.redo()
    #expect(model.parameters.dustRepairs == repairs)
    model.applyLookRecipe(.warm)
    #expect(model.parameters.dustRepairs == repairs)
    try await model.flushSettings()
    let document = try JSONDecoder().decode(
      PerFileSettingsStore.Document.self, from: Data(contentsOf: store.fileURL))
    #expect(document.schemaVersion == 3)
    let restored = try await loadedModel(fixture, store: store, chooseOriginal: false)
    #expect(restored.parameters.dustRepairs == repairs)
    #expect(!restored.isDustEditing)
    model.clearDustRepairs()
    #expect(model.parameters.dustRepairs.isEmpty)
    model.undo()
    #expect(model.parameters.dustRepairs == repairs)
  }

  @Test("Mask repair is explicit, keeps unprocessed suggestions, and is one reversible edit")
  func optInMaskRepair() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    model.beginDustEditing()
    model.paintDustMask(points: [SIMD2(0.5, 0.5)], radius: 0.015, erasing: false)
    model.paintDustMask(
      points: [SIMD2(0.1, 0.2), SIMD2(0.4, 0.2)], radius: 0.02, erasing: false)
    #expect(model.parameters.dustRepairs.isEmpty)
    await model.repairDustMask()?.value
    #expect(!model.parameters.dustRepairs.isEmpty)
    let remaining = try #require(model.dustSourceMask)
    #expect(remaining.pixels[19 * remaining.width + 32] != 0)
    #expect(remaining.pixels[48 * remaining.width + 64] == 0)
    #expect(model.undoActionName == "Repair Dust Mask")
    model.undo()
    #expect(model.parameters.dustRepairs.isEmpty)
  }

  @Test("Async mask repair remains a separate undo step inside an unchanged Exposure gesture")
  func repairCompletionKeepsGestureHistorySeparate() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = PerFileSettingsStore(baseDirectory: fixture.directory)
    let model = try await loadedModel(fixture, store: store)
    defer { model.closeAllScans() }
    model.beginDustEditing()
    model.paintDustMask(points: [SIMD2(0.5, 0.5)], radius: 0.015, erasing: false)
    let before = model.parameters
    let task = try #require(model.repairDustMask())
    // Do not yield before opening the gesture: the repair completion must see
    // this active transaction while its saved-parameters guard still matches.
    model.beginEditingGesture(named: "Exposure")
    await task.value
    let repaired = model.parameters
    try #require(!repaired.dustRepairs.isEmpty)
    #expect(repaired.photoAdjustments == before.photoAdjustments)
    #expect(model.undoActionName == "Repair Dust Mask")

    // The original slider remains held. Its later samples need a fresh
    // baseline containing the repair, while still coalescing into one step.
    model.setExposureEV(0.25)
    model.setExposureEV(0.5)
    model.endEditingGesture()
    let adjusted = model.parameters
    #expect(adjusted.dustRepairs == repaired.dustRepairs)
    #expect(model.undoActionName == "Exposure")
    model.undo()
    #expect(model.parameters == repaired)
    #expect(model.undoActionName == "Repair Dust Mask")
    model.undo()
    #expect(model.parameters == before)
    #expect(model.redoActionName == "Repair Dust Mask")
    model.redo()
    #expect(model.parameters == repaired)
    #expect(model.redoActionName == "Exposure")
    model.redo()
    #expect(model.parameters == adjusted)

    try await model.flushSettings()
    var persisted = adjusted
    persisted.filmNegativeParams.measuredMedians = nil
    #expect(
      try store.loadState().settingsByPath[fixture.input.standardizedFileURL.path] == persisted)
    let restored = try await loadedModel(fixture, store: store, chooseOriginal: false)
    defer { restored.closeAllScans() }
    #expect(restored.parameters.dustRepairs == adjusted.dustRepairs)
    #expect(restored.parameters.photoAdjustments == adjusted.photoAdjustments)
    #expect(restored.undoActionName == nil)
    #expect(try Data(contentsOf: fixture.input) == fixture.inputBytes)
  }

  @Test("Original comparison keeps edited masks and invalid donors do not consume them")
  func maskComparisonAndInvalidDonor() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    model.beginDustEditing()
    model.paintDustMask(points: [SIMD2(0.5, 0.5)], radius: 0.015, erasing: false)
    let mask = model.dustSourceMask
    model.showOriginal = true
    #expect(model.dustSourceMask == mask)
    model.showOriginal = false
    await model.addDustRepair(
      points: [SIMD2(0.5, 0.5)], radius: 0.025, sourcePoint: SIMD2(0, 0))?.value
    #expect(model.parameters.dustRepairs.isEmpty)
    #expect(model.dustSourceMask == mask)
    #expect(model.dustStatus.contains("away from the scan edge"))
    await model.addDustRepair(
      points: [SIMD2(0.5, 0.5)], radius: 0.025, sourcePoint: SIMD2(0.5, 0.5))?.value
    #expect(model.parameters.dustRepairs.isEmpty)
    #expect(model.dustSourceMask == mask)
  }

  @Test(
    "Direct Heal rejects unavailable stamps and partial paths without consuming masks or history",
    arguments: ["automaticStamp", "explicitStamp", "automaticPath", "explicitPath"])
  func directHealingRequiresEveryDonor(kind: String) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    defer { model.closeAllScans() }
    model.beginDustEditing()
    let points: [SIMD2<Double>] =
      kind.hasSuffix("Path") ? [SIMD2(0, 0), SIMD2(0.5, 0.5)] : [SIMD2(0, 0)]
    let donor: SIMD2<Double>? = kind.hasPrefix("explicit") ? SIMD2(0.25, 0.25) : nil
    let radius = kind.hasSuffix("Path") ? 0.005 : 0.025
    model.paintDustMask(points: points, radius: radius, erasing: false)
    let marked = try #require(model.dustSourceMask)
    let before = model.parameters
    let history = model.undoActionName
    let source = try #require(model.decodedImage)
    let stroke = DustRepairStroke(points: points, radius: radius, sourcePoint: donor)
    try #require(DustRepair.canApply(strokes: [stroke], imageWidth: 128, imageHeight: 96))
    #expect(DustRepair.applicableStrokeIndices(in: source, strokes: [stroke]).isEmpty)
    let partialOutput = DustRepair.apply(to: source, strokes: [stroke])
    if kind.hasSuffix("Path") {
      // The renderer retains valid later dabs, but the app must not erase
      // this whole marked path when its corner dab has no boundary support.
      #expect(partialOutput != source)
    } else {
      #expect(partialOutput == source)
    }

    let task = try #require(model.addDustRepair(points: points, radius: radius, sourcePoint: donor))
    #expect(model.isDustRepairRunning)
    #expect(!model.isDustCanvasReady)
    #expect(model.parameters == before && model.dustSourceMask == marked)
    await task.value
    #expect(!model.isDustRepairRunning)
    #expect(model.parameters == before && model.dustSourceMask == marked)
    #expect(model.undoActionName == history)
    #expect(model.dustStatus.hasPrefix("No usable texture source found."))
    #expect(try Data(contentsOf: fixture.input) == fixture.inputBytes)
  }

  @Test("Direct automatic Heal freezes a donor outside all marked components")
  func directHealingPreservesMaskExclusions() async throws {
    let fixture = try Fixture(excludedScratch: true)
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    defer { model.closeAllScans() }
    model.beginDustEditing()
    model.paintDustMask(
      points: [SIMD2(64.5 / 128, 48.5 / 96)], radius: 0.001, erasing: false)
    model.paintDustMask(
      points: [SIMD2(69.5 / 128, 48.5 / 96), SIMD2(104.5 / 128, 48.5 / 96)],
      radius: 0.001, erasing: false)
    let mask = try #require(model.dustSourceMask)
    let source = try #require(model.decodedImage)
    let stamp = try #require(DustRepair.automaticRepairCandidates(from: mask).first?.stroke)
    let expected = try #require(
      DustRepair.plannedSinglePointRepairs(in: source, strokes: [stamp], excludingMask: mask)
        .first?.stroke)
    try #require(expected.sourcePoint != nil)
    await model.addDustRepair(points: stamp.points, radius: stamp.radius)?.value
    #expect(model.parameters.dustRepairs == [expected])
    let repaired = DustRepair.apply(to: source, strokes: model.parameters.dustRepairs)
    #expect(repaired.pixels[(48 * 128 + 64) * 3] == 30_000)
    #expect(repaired.pixels[(48 * 128 + 80) * 3] == 0)
    #expect(model.dustSourceMask?.pixels[48 * 128 + 64] == 0)
    #expect(model.dustSourceMask?.pixels[48 * 128 + 80] != 0)
    #expect(model.undoActionName == "Healing Brush")
    model.undo()
    #expect(model.parameters.dustRepairs.isEmpty)
  }

  @Test("Direct Heal retains marked defects on its strict feather boundary")
  func directHealingKeepsBoundaryMarks() async throws {
    let fixture = try Fixture(excludedScratch: true)
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    defer { model.closeAllScans() }
    model.beginDustEditing()
    let point = SIMD2(64.5 / 128, 48.5 / 96)
    let radius = 1.0 / 128
    model.paintDustMask(points: [point], radius: radius, erasing: false)
    let mask = try #require(model.dustSourceMask)
    try #require(mask.pixels.filter { $0 != 0 }.count == 5)
    await model.addDustRepair(
      points: [point], radius: radius, sourcePoint: SIMD2(32.5 / 128, 48.5 / 96))?.value
    try #require(model.parameters.dustRepairs.count == 1)
    let source = try #require(model.decodedImage)
    let output = DustRepair.apply(to: source, strokes: model.parameters.dustRepairs)
    #expect(output.pixels[(48 * 128 + 64) * 3] != source.pixels[(48 * 128 + 64) * 3])
    #expect(model.dustSourceMask?.pixels[48 * 128 + 64] == 0)
    for (x, y) in [(63, 48), (65, 48), (64, 47), (64, 49)] {
      #expect(output.pixels[(y * 128 + x) * 3] == source.pixels[(y * 128 + x) * 3])
      #expect(model.dustSourceMask?.pixels[y * 128 + x] == .max)
    }
    #expect(model.dustSourceMask?.pixels.filter { $0 != 0 }.count == 4)
    let saved = model.parameters
    model.paintDustMask(points: [point], radius: radius, erasing: true)
    #expect(model.dustSourceMask?.pixels.allSatisfy { $0 == 0 } == true)
    #expect(model.parameters == saved)
    #expect(try Data(contentsOf: fixture.input) == fixture.inputBytes)
  }

  @Test(
    "Direct Heal cancellation and mask edits preserve the current mask and history",
    arguments: [false, true])
  func cancelledDirectHealingPreservesMask(editMask: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    defer { model.closeAllScans() }
    model.beginDustEditing()
    model.paintDustMask(points: [SIMD2(0.5, 0.5)], radius: 0.015, erasing: false)
    let before = model.parameters
    let history = model.undoActionName
    let task = try #require(
      model.addDustRepair(
        points: [SIMD2(0.5, 0.5)], radius: 0.025, sourcePoint: SIMD2(0.3, 0.5)))
    task.cancel()
    if editMask {
      model.paintDustMask(points: [SIMD2(0.2, 0.2)], radius: 0.015, erasing: false)
    }
    let expectedMask = model.dustSourceMask
    let expectedStatus = model.dustStatus
    // Do not yield until cancellation and the optional replacement mask edit.
    await task.value
    #expect(!model.isDustRepairRunning)
    #expect(model.parameters == before && model.dustSourceMask == expectedMask)
    #expect(model.undoActionName == history)
    #expect(
      model.dustStatus
        == (editMask ? expectedStatus : "Repair cancelled. Candidates remain marked."))
  }

  @Test("A superseded direct Heal cannot save or clear its replacement owner's status")
  func replacementDirectHealingOwnsCompletion() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    defer { model.closeAllScans() }
    model.beginDustEditing()
    let before = model.parameters
    let history = model.undoActionName
    let first = try #require(
      model.addDustRepair(
        points: [SIMD2(0.5, 0.5)], radius: 0.025, sourcePoint: SIMD2(0.3, 0.5)))
    let replacement = DustRepairStroke(
      points: [SIMD2(0.5, 0.5)], radius: 0.02, sourcePoint: SIMD2(0.25, 0.5))
    let second = try #require(
      model.addDustRepair(
        points: replacement.points, radius: replacement.radius, sourcePoint: replacement.sourcePoint
      ))
    await first.value
    await second.value
    #expect(!model.isDustRepairRunning)
    #expect(model.parameters.dustRepairs == [replacement])
    #expect(model.dustStatus.hasPrefix("Healing stroke saved."))
    #expect(model.undoActionName == "Healing Brush")
    model.undo()
    #expect(model.parameters == before && model.undoActionName == history)
    #expect(model.redoActionName == "Healing Brush")
  }

  @Test("Async direct Heal remains a separate undo step inside an active Exposure gesture")
  func directHealingCompletionKeepsGestureHistorySeparate() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    defer { model.closeAllScans() }
    model.beginDustEditing()
    let before = model.parameters
    let task = try #require(
      model.addDustRepair(
        points: [SIMD2(0.5, 0.5)], radius: 0.025, sourcePoint: SIMD2(0.3, 0.5)))
    model.beginEditingGesture(named: "Exposure")
    await task.value
    let healed = model.parameters
    try #require(healed.dustRepairs.count == 1)
    #expect(model.undoActionName == "Healing Brush")
    model.setExposureEV(0.25)
    model.setExposureEV(0.5)
    model.endEditingGesture()
    let adjusted = model.parameters
    model.undo()
    #expect(model.parameters == healed && model.undoActionName == "Healing Brush")
    model.undo()
    #expect(model.parameters == before)
    model.redo()
    #expect(model.parameters == healed)
    model.redo()
    #expect(model.parameters == adjusted)
  }

  @Test("Candidates without a texture donor stay marked instead of becoming saved repairs")
  func unavailableMaskDonorsRemainMarked() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    model.beginDustEditing()
    for y in stride(from: 21, through: 76, by: 5) {
      for x in stride(from: 21, through: 86, by: 5) {
        model.paintDustMask(
          points: [SIMD2((Double(x) + 0.5) / 128, (Double(y) + 0.5) / 96)],
          radius: 0.001, erasing: false)
      }
    }
    let mask = try #require(model.dustSourceMask)
    let candidates = DustRepair.automaticRepairCandidates(from: mask)
    let proposals = candidates.map(\.stroke)
    let source = try #require(model.decodedImage)
    let plans = DustRepair.plannedSinglePointRepairs(
      in: source, strokes: proposals, excludingMask: mask)
    let acceptedIndices = plans.map(\.strokeIndex)
    try #require(!acceptedIndices.isEmpty && acceptedIndices.count < proposals.count)
    let accepted = plans.map(\.stroke)
    await model.repairDustMask()?.value
    #expect(model.parameters.dustRepairs == accepted)
    #expect(
      model.dustSourceMask
        == DustMaskEditing.consumingComponents(
          mask, candidates: acceptedIndices.map { candidates[$0] }))
    #expect(model.dustSourceMask?.pixels[46 * 128 + 46] != 0)
    #expect(model.dustStatus.contains("Unprocessed candidates remain marked"))
    model.undo()
    #expect(model.parameters.dustRepairs.isEmpty)
  }

  @Test("Auto repair saves its checked donors without sampling rejected marked spots")
  func autoRepairPreservesCheckedDonorTexture() async throws {
    let fixture = try Fixture(denseDust: true)
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    model.beginDustEditing()
    for y in stride(from: 21, through: 76, by: 5) {
      for x in stride(from: 21, through: 86, by: 5) {
        model.paintDustMask(
          points: [SIMD2((Double(x) + 0.5) / 128, (Double(y) + 0.5) / 96)],
          radius: 0.001, erasing: false)
      }
    }
    let mask = try #require(model.dustSourceMask)
    let proposals = DustRepair.automaticRepairs(from: mask)
    let source = try #require(model.decodedImage)
    let acceptedIndices = DustRepair.applicableStrokeIndices(in: source, strokes: proposals)
    try #require(!acceptedIndices.isEmpty && acceptedIndices.count < proposals.count)
    let reference = DustRepair.apply(to: source, strokes: proposals)
    // This filtered set passes the old availability check but changes donors
    // after rejected components stop excluding their original dark texture.
    let filtered = DustRepair.apply(
      to: source, strokes: acceptedIndices.map { proposals[$0] })
    #expect(filtered != reference)
    let protectedPlans = DustRepair.plannedSinglePointRepairs(
      in: source, strokes: proposals, excludingMask: mask)
    try #require(!protectedPlans.isEmpty && protectedPlans.count < proposals.count)
    await model.repairDustMask()?.value
    #expect(model.parameters.dustRepairs == protectedPlans.map(\.stroke))
    #expect(model.parameters.dustRepairs.allSatisfy { $0.sourcePoint != nil })
    let repaired = DustRepair.apply(to: source, strokes: model.parameters.dustRepairs)
    for plan in protectedPlans {
      let point = plan.stroke.points[0]
      let x = Int((point.x * 128 - 0.5).rounded())
      let y = Int((point.y * 96 - 0.5).rounded())
      #expect(repaired.pixels[(y * 128 + x) * 3] == 30_000)
    }
    #expect(model.dustSourceMask?.pixels.contains { $0 != 0 } == true)
    #expect(try Data(contentsOf: fixture.input) == fixture.inputBytes)
  }

  @Test("Auto repair avoids a marked scratch excluded from component proposals")
  func autoRepairAvoidsUnproposedScratch() async throws {
    let fixture = try Fixture(excludedScratch: true)
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    model.beginDustEditing()
    model.paintDustMask(
      points: [SIMD2(64.5 / 128, 48.5 / 96)], radius: 0.001, erasing: false)
    model.paintDustMask(
      points: [SIMD2(69.5 / 128, 48.5 / 96), SIMD2(104.5 / 128, 48.5 / 96)],
      radius: 0.001, erasing: false)
    let mask = try #require(model.dustSourceMask)
    let source = try #require(model.decodedImage)
    let proposals = DustRepair.automaticRepairCandidates(from: mask)
    try #require(proposals.count == 1)
    let unprotected = DustRepair.plannedSinglePointRepairs(
      in: source, strokes: proposals.map(\.stroke))
    #expect(
      DustRepair.apply(to: source, strokes: unprotected.map(\.stroke)).pixels[(48 * 128 + 64) * 3]
        == 0)
    await model.repairDustMask()?.value
    try #require(model.parameters.dustRepairs.count == 1)
    let repaired = DustRepair.apply(to: source, strokes: model.parameters.dustRepairs)
    #expect(repaired.pixels[(48 * 128 + 64) * 3] == 30_000)
    #expect(repaired.pixels[(48 * 128 + 80) * 3] == 0)
    #expect(model.dustSourceMask?.pixels[48 * 128 + 64] == 0)
    #expect(model.dustSourceMask?.pixels[48 * 128 + 80] != 0)
  }

  @Test(
    "Clearing or editing the mask cancels a pending repair without saving obsolete spots",
    arguments: [false, true])
  func staleMaskRepairIsDiscarded(clear: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    model.beginDustEditing()
    model.paintDustMask(points: [SIMD2(0.5, 0.5)], radius: 0.015, erasing: false)
    let task = try #require(model.repairDustMask())
    #expect(model.isDustRepairRunning)
    #expect(model.repairDustMask() == nil)
    if clear {
      model.clearDustMask()
    } else {
      model.paintDustMask(points: [SIMD2(0.3, 0.3)], radius: 0.015, erasing: false)
    }
    let currentMask = model.dustSourceMask
    await task.value
    #expect(!model.isDustRepairRunning)
    #expect(model.parameters.dustRepairs.isEmpty)
    #expect(model.dustSourceMask == currentMask)
  }

  @Test("Cancelling a repair before it starts preserves candidates and allows another repair")
  func cancelledBeforeStartCanRetry() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    model.beginDustEditing()
    model.paintDustMask(points: [SIMD2(0.5, 0.5)], radius: 0.015, erasing: false)
    let mask = try #require(model.dustSourceMask)
    let before = model.parameters
    let task = try #require(model.repairDustMask())
    #expect(model.isDustRepairRunning)
    // This MainActor test does not yield until after cancellation, so the
    // repair task must take its before-start cancellation branch.
    task.cancel()
    await task.value
    #expect(!model.isDustRepairRunning)
    #expect(model.parameters == before)
    #expect(model.dustSourceMask == mask)
    #expect(model.dustStatus == "Repair cancelled. Candidates remain marked.")

    let retry = try #require(model.repairDustMask())
    await retry.value
    #expect(!model.isDustRepairRunning)
    #expect(model.parameters.dustRepairs.count == 1)
    #expect(model.dustSourceMask?.pixels.allSatisfy { $0 == 0 } == true)
  }

  @Test("Cancelling detection before it starts preserves the published mask and allows a retry")
  func cancelledDetectionBeforeStartCanRetry() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    model.beginDustEditing()
    model.paintDustMask(points: [SIMD2(0.5, 0.5)], radius: 0.015, erasing: false)
    let mask = try #require(model.dustSourceMask)
    let overlay = model.dustMaskImage
    let before = model.parameters
    let task = try #require(model.detectDustMask())
    #expect(model.isDustDetectionRunning)
    // No MainActor yield precedes cancellation, so detection must skip its worker.
    task.cancel()
    await task.value
    #expect(!model.isDustDetectionRunning)
    #expect(model.parameters == before)
    #expect(model.dustSourceMask == mask)
    #expect(model.dustMaskImage === overlay)
    #expect(model.dustStatus == "Dust detection cancelled.")

    let retry = try #require(model.detectDustMask())
    await retry.value
    #expect(!model.isDustDetectionRunning)
    #expect(model.dustSourceMask != nil)
    #expect(model.dustStatus != "Dust detection cancelled.")
    #expect(model.parameters == before)
  }

  @Test(
    "An obsolete cancelled detection preserves a newer mask edit or clear",
    arguments: [false, true])
  func cancelledDetectionPreservesReplacement(clear: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    model.beginDustEditing()
    model.paintDustMask(points: [SIMD2(0.5, 0.5)], radius: 0.015, erasing: false)
    let before = model.parameters
    let task = try #require(model.detectDustMask())
    task.cancel()
    // These operations advance the generation before the old task can start.
    if clear {
      model.clearDustMask()
    } else {
      model.paintDustMask(points: [SIMD2(0.3, 0.3)], radius: 0.015, erasing: false)
    }
    let currentMask = model.dustSourceMask
    let currentOverlay = model.dustMaskImage
    let currentStatus = model.dustStatus
    await task.value
    #expect(!model.isDustDetectionRunning)
    #expect(model.parameters == before)
    #expect(model.dustSourceMask == currentMask)
    #expect(model.dustMaskImage === currentOverlay)
    #expect(model.dustStatus == currentStatus)
  }

  @Test("A successful stamp's feather preserves an adjacent rejected mask component")
  func featherDoesNotConsumeRejectedComponent() throws {
    var pixels = [UInt16](repeating: 0, count: 128 * 96)
    for y in 20...22 {
      for x in 20...22 { pixels[y * 128 + x] = .max }
    }
    pixels[21 * 128 + 24] = .max
    let mask = UInt16Image(width: 128, height: 96, channels: 1, pixels: pixels)
    let candidates = DustRepair.automaticRepairCandidates(from: mask)
    try #require(candidates.count == 2)
    let source = UInt16Image(
      width: 128, height: 96, channels: 1,
      pixels: [UInt16](repeating: 40_000, count: 128 * 96))
    var existing: [DustRepairStroke] = []
    for y in stride(from: 12, through: 30, by: 3) {
      for x in stride(from: 15, through: 33, by: 3) {
        existing.append(
          .init(
            points: [SIMD2((Double(x) + 0.5) / 128, (Double(y) + 0.5) / 96)],
            radius: (sqrt(2) / 2 + 1) / 128))
      }
    }
    let accepted = DustRepair.applicableStrokeIndices(
      in: source, strokes: existing + candidates.map(\.stroke)
    )
    .filter { $0 >= existing.count }.map { candidates[$0 - existing.count] }
    try #require(accepted.count == 1)
    let consumed = DustMaskEditing.consumingComponents(mask, candidates: accepted)
    #expect(consumed.pixels[21 * 128 + 21] == 0)
    #expect(consumed.pixels[21 * 128 + 24] == .max)
    #expect(consumed.pixels.filter { $0 != 0 }.count == 1)
  }

  @Test("Repair visibility and Original comparison restore the exact displayed source pixels")
  func originalAndRepairVisibility() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    model.beginDustEditing()
    try await waitUntil { !model.isRendering }
    let original = try previewBytes(model)
    await model.addDustRepair(
      points: [SIMD2(0.5, 0.5)], radius: 0.025, sourcePoint: SIMD2(0.3, 0.5))?.value
    try await waitUntil { !model.isRendering }
    let repaired = try previewBytes(model)
    #expect(repaired != original)
    let saved = model.parameters

    model.showDustRepairs = false
    try await waitUntil { !model.isRendering }
    #expect(try previewBytes(model) == original)
    model.showDustRepairs = true
    try await waitUntil { !model.isRendering }
    #expect(try previewBytes(model) == repaired)

    model.showOriginal = true
    try await waitUntil { !model.isRendering }
    #expect(try previewBytes(model) == original)
    model.showOriginal = false
    try await waitUntil { !model.isRendering }
    #expect(try previewBytes(model) == repaired)
    #expect(model.parameters == saved)
  }

  @Test("Repair canvas preserves framing and reopened full-size exports match CPU pixels")
  func geometryAndExportAgreement() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    model.rotateClockwise()
    model.setManualCrop(.init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
    let before = model.parameters
    model.beginDustEditing()
    try await waitUntil { !model.isRendering }
    #expect(model.previewImage?.size == CGSize(width: 128, height: 96))
    await model.addDustRepair(
      points: [SIMD2(0.5, 0.5)], radius: 0.025, sourcePoint: SIMD2(0.3, 0.5))?.value
    #expect(model.parameters.rotation == before.rotation)
    #expect(model.parameters.manualCrop == before.manualCrop)
    let after = model.parameters
    model.showDustRepairs = false
    #expect(model.parameters == after)
    model.showDustRepairs = true
    model.endDustEditing()
    try await waitUntil { !model.isRendering }
    model.setExportFormat(.png)
    model.exportSelected()
    try await waitUntil { !model.isExporting && model.exportProgressCurrent == 1 }
    #expect(model.exportErrors.isEmpty)
    let output = fixture.directory.appendingPathComponent("scan-2.png")
    let source = try StandardImageDecoder.decode(fixture.input)
    let expected = FilmProcessing.correctedPreview(image: source, parameters: after)
    #expect(try StandardImageDecoder.decode(output) == expected)
    #expect(expected != FilmProcessing.correctedPreview(image: source, parameters: before))
    #expect(try Data(contentsOf: fixture.input) == fixture.inputBytes)
  }

  @Test("The brush waits for source geometry publication and remains ready during later edits")
  func sourceCanvasReadiness() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    model.rotateClockwise()
    model.setManualCrop(.init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
    try await waitUntil { !model.isRendering }
    let framed = model.previewImage?.size
    let gate = DustCompletionGate()
    model.previewRenderCompletionHook = { await gate.hold($0) }
    defer {
      model.previewRenderCompletionHook = nil
      gate.releaseAll()
    }

    model.beginDustEditing()
    try await waitUntil { gate.arrivals.count == 1 }
    #expect(model.previewImage?.size == framed)
    #expect(!model.isDustCanvasReady)
    #expect(gate.arrivals[0].rotation == 0)
    #expect(gate.arrivals[0].manualCrop == nil)
    gate.release(0)
    try await waitUntil { !model.isRendering }
    #expect(model.isDustCanvasReady)

    model.setSemanticTemperature(25)
    try await waitUntil { gate.arrivals.count == 2 }
    #expect(model.isRendering)
    #expect(model.isDustCanvasReady)
    gate.release(1)
    try await waitUntil { !model.isRendering }
  }

  @Test(
    "Repair changes reject a completed frame rendered against earlier source pixels",
    arguments: ["append", "clear", "hide", "hideAndReturn"])
  func repairContextRejectsCompletedFrame(change: String) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    model.beginDustEditing()
    try await waitUntil { !model.isRendering }
    if change != "append" {
      await model.addDustRepair(
        points: [SIMD2(0.5, 0.5)], radius: 0.025, sourcePoint: SIMD2(0.3, 0.5))?.value
      try await waitUntil { !model.isRendering }
    }
    let gate = DustCompletionGate()
    model.previewRenderCompletionHook = { await gate.hold($0) }
    defer {
      model.previewRenderCompletionHook = nil
      gate.releaseAll()
    }
    let displayedBefore = model.renderStats.displayedRenders
    let revisionBefore = model.publishedRenderRevision
    model.setSemanticTemperature(25)
    try await waitUntil { gate.arrivals.count == 1 }
    switch change {
    case "append":
      await model.addDustRepair(
        points: [SIMD2(0.5, 0.5)], radius: 0.025, sourcePoint: SIMD2(0.3, 0.5))?.value
    case "clear": model.clearDustRepairs()
    case "hide": model.showDustRepairs = false
    default:
      model.showDustRepairs = false
      model.showDustRepairs = true
    }
    gate.release(0)
    try await waitUntil { gate.arrivals.count == 2 && gate.exited.contains(0) }
    #expect(model.renderStats.displayedRenders == displayedBefore)
    #expect(model.publishedRenderRevision == revisionBefore)
    gate.release(1)
    try await waitUntil { !model.isRendering }
    #expect(model.renderStats.displayedRenders == displayedBefore + 1)
    let visibleRepairs = model.showDustRepairs ? model.parameters.dustRepairs : []
    #expect(model.publishedPreviewParameters?.dustRepairs == visibleRepairs)
  }

  @Test(
    "Repair footprint consumption preserves minimum-radius and strict-boundary marks",
    arguments: [0.001, 1.0 / 128])
  func repairFootprintPreservesBoundary(radius: Double) throws {
    let point = SIMD2(64.5 / 128, 48.5 / 96)
    var pixels = [UInt16](repeating: 0, count: 128 * 96)
    for (x, y) in [(64, 48), (63, 48), (65, 48), (64, 47), (64, 49)] {
      pixels[y * 128 + x] = .max
    }
    let mask = UInt16Image(width: 128, height: 96, channels: 1, pixels: pixels)
    let stroke = DustRepairStroke(points: [point], radius: radius)
    let consumed = DustMaskEditing.consumingRepairFootprints(
      mask, repairs: [stroke], sourceWidth: 128, sourceHeight: 96)
    #expect(consumed.pixels[48 * 128 + 64] == 0)
    #expect(consumed.pixels.filter { $0 != 0 }.count == 4)
    // Erase is an explicit mask edit and retains its inclusive one-pixel disk.
    #expect(DustMaskEditing.erasing(mask, repairs: [stroke]).pixels.allSatisfy { $0 == 0 })
  }

  @Test(
    "Coarse mask cells remain marked when any represented source pixel is uncovered",
    arguments: [false, true])
  func coarseRepairFootprintCoverage(nonIntegerScale: Bool) throws {
    let sourceWidth = nonIntegerScale ? 129 : 128
    let sourceHeight = nonIntegerScale ? 97 : 96
    let centerX = nonIntegerScale ? 65 : 64
    let centerY = nonIntegerScale ? 49 : 48
    let point = SIMD2(
      (Double(centerX) + 0.5) / Double(sourceWidth),
      (Double(centerY) + 0.5) / Double(sourceHeight))
    var pixels = [UInt16](repeating: 0, count: 64 * 48)
    pixels[24 * 64 + 32] = .max
    let mask = UInt16Image(width: 64, height: 48, channels: 1, pixels: pixels)
    let partial = DustRepairStroke(points: [point], radius: 1 / Double(sourceWidth))
    #expect(
      DustMaskEditing.consumingRepairFootprints(
        mask, repairs: [partial], sourceWidth: sourceWidth, sourceHeight: sourceHeight) == mask)
    let covering = DustRepairStroke(points: [point], radius: 1.5 / Double(sourceWidth))
    #expect(
      DustMaskEditing.consumingRepairFootprints(
        mask, repairs: [covering], sourceWidth: sourceWidth, sourceHeight: sourceHeight
      )
      .pixels.allSatisfy { $0 == 0 })
    if !nonIntegerScale {
      let boundary = DustRepairStroke(points: [point], radius: sqrt(2) / Double(sourceWidth))
      #expect(
        DustMaskEditing.consumingRepairFootprints(
          mask, repairs: [boundary], sourceWidth: sourceWidth, sourceHeight: sourceHeight) == mask)
    }
    let finer = UInt16Image(
      width: sourceWidth * 2, height: sourceHeight * 2, channels: 1,
      pixels: [UInt16](repeating: .max, count: sourceWidth * sourceHeight * 4))
    #expect(
      DustMaskEditing.consumingRepairFootprints(
        finer, repairs: [covering], sourceWidth: sourceWidth, sourceHeight: sourceHeight) == finer)
  }

  @Test("Mask consumption follows actual source dab spacing instead of mask brush spacing")
  func repairFootprintUsesSourceSpacing() throws {
    var pixels = [UInt16](repeating: 0, count: 128 * 96)
    for y in 47...49 {
      for x in 40...42 { pixels[y * 128 + x] = .max }
    }
    let mask = UInt16Image(width: 128, height: 96, channels: 1, pixels: pixels)
    let stroke = DustRepairStroke(
      points: [SIMD2(40.5 / 128, 48.5 / 96), SIMD2(42.5 / 128, 48.5 / 96)], radius: 0.001)
    let consumed = DustMaskEditing.consumingRepairFootprints(
      mask, repairs: [stroke], sourceWidth: 128, sourceHeight: 96)
    #expect((40...42).allSatisfy { consumed.pixels[48 * 128 + $0] == 0 })
    #expect((40...42).allSatisfy { consumed.pixels[47 * 128 + $0] == .max })
    #expect((40...42).allSatisfy { consumed.pixels[49 * 128 + $0] == .max })
  }

  @Test("Excessive footprint work preserves the original mask instead of partial consumption")
  func excessiveFootprintWorkIsAtomic() throws {
    let sourceWidth = 8_192
    let sourceHeight = 2_048
    var pixels = [UInt16](repeating: 0, count: 2_048 * 2_048)
    let marked = 1_024 * 2_048 + 1_024
    pixels[marked] = .max
    let mask = UInt16Image(width: 2_048, height: 2_048, channels: 1, pixels: pixels)
    let stroke = DustRepairStroke(points: [SIMD2(0.5, 0.5)], radius: 0.05)
    let repairs = Array(repeating: stroke, count: 100)
    try #require(
      DustRepair.canApply(strokes: repairs, imageWidth: sourceWidth, imageHeight: sourceHeight))
    // This needs only source dimensions, not an 8192x2048 source allocation.
    // One footprint consumes the mark; repeating its 206x820 mask rectangle
    // one hundred times exceeds the bounded eight-million-cell coverage work.
    #expect(
      DustMaskEditing.consumingRepairFootprints(
        mask, repairs: [stroke], sourceWidth: sourceWidth, sourceHeight: sourceHeight
      )
      .pixels[marked] == 0)
    #expect(
      DustMaskEditing.consumingRepairFootprints(
        mask, repairs: repairs, sourceWidth: sourceWidth, sourceHeight: sourceHeight) == mask)
  }

  @Test("Mask strokes interpolate continuously and reject invalid coordinates")
  func continuousMaskPainting() {
    let mask = UInt16Image(
      width: 128, height: 96, channels: 1, pixels: [UInt16](repeating: 0, count: 128 * 96))
    let painted = DustMaskEditing.painting(
      mask, points: [SIMD2(0.25, 0.5), SIMD2(0.75, 0.5)], radius: 0.02, erasing: false)
    #expect((32..<96).allSatisfy { painted.pixels[48 * 128 + $0] != 0 })
    #expect(painted.pixels[0] == 0)
    #expect(mask.pixels.allSatisfy { $0 == 0 })
    #expect(
      DustMaskEditing.painting(mask, points: [SIMD2(Double.nan, 0)], radius: 0.02, erasing: false)
        == mask)
  }

  private func loadedModel(
    _ fixture: Fixture, store: PerFileSettingsStore? = nil, chooseOriginal: Bool = true
  ) async throws -> AppModel {
    let model = AppModel(settingsStore: store)
    model.importFiles([fixture.input])
    try await waitUntil { model.hasPreviewImage && !model.isLoading && !model.isRendering }
    if chooseOriginal { model.setFilmBase(.original) }
    try await waitUntil { !model.isRendering }
    return model
  }

  private func previewBytes(_ model: AppModel) throws -> Data {
    let image = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    return try #require(image.dataProvider?.data as Data?)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for dust app workflow")
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private struct Fixture {
    let directory: URL
    let input: URL
    let inputBytes: Data

    init(denseDust: Bool = false, excludedScratch: Bool = false) throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fsc-dust-workflow-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      input = directory.appendingPathComponent("scan.png")
      var pixels = [UInt16]()
      for y in 0..<96 {
        for x in 0..<128 {
          let value: UInt16
          if denseDust {
            let marked =
              (21...86).contains(x) && (21...76).contains(y)
              && (x - 21) % 5 == 0 && (y - 21) % 5 == 0
            value = marked ? 0 : 30_000
          } else if excludedScratch {
            let marked =
              abs(x - 64) <= 1 && abs(y - 48) <= 1
              || (69...104).contains(x) && y == 48
            value = marked ? 0 : 30_000
          } else {
            value =
              abs(x - 64) <= 1 && abs(y - 48) <= 1
              ? 0 : UInt16(24_000 + x * 40 + y * 20 + (x % 3) * 100)
          }
          pixels += [value, value, value]
        }
      }
      try UInt16Image(width: 128, height: 96, channels: 3, pixels: pixels).write(
        to: input, format: .png, parameters: .init(format: .png))
      inputBytes = try Data(contentsOf: input)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
  }
}

@MainActor
private final class DustCompletionGate {
  var arrivals: [ProcessingParameters] = []
  var exited: Set<Int> = []
  private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

  func hold(_ parameters: ProcessingParameters) async {
    let index = arrivals.count
    arrivals.append(parameters)
    await withCheckedContinuation { continuations[index] = $0 }
    exited.insert(index)
  }

  func release(_ index: Int) {
    continuations.removeValue(forKey: index)?.resume()
  }

  func releaseAll() {
    let pending = Array(continuations.values)
    continuations.removeAll()
    for continuation in pending { continuation.resume() }
  }
}
