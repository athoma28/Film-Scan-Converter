import AppKit
import CoreGraphics
import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Film base and public look preview parity")
struct FilmBaseRecipePreviewTests {
  @Test("Every current film-base invert matches CPU within 2/255")
  func filmBaseInvertParity() throws {
    let image = chromaticSource()
    let renderer = try #require(
      StillPreviewRenderer(image: image), "Could not create still preview renderer")

    for base in FilmBase.allCases {
      try expectParity(
        renderer, image: image,
        parameters: base.applyingInvert(to: ProcessingParameters()),
        label: "\(base.rawValue)/invert")
    }
  }

  @Test("Every factory look matches CPU on every film base that supports looks")
  func factoryLookParity() throws {
    let image = chromaticSource()
    let renderer = try #require(
      StillPreviewRenderer(image: image), "Could not create still preview renderer")

    // Recommendations are browsing hints, not restrictions on applying a look.
    for base in FilmBase.allCases where base.supportsLooks {
      let inverted = base.applyingInvert(to: ProcessingParameters())
      for recipe in LookRecipe.factory {
        try expectParity(
          renderer, image: image, parameters: recipe.applying(to: inverted),
          label: "\(base.rawValue)/\(recipe.id)")
      }
    }
  }

  @Test("Public foliage, cast-cleanup and color-separation endpoints match CPU")
  func publicControlEndpointParity() throws {
    let image = chromaticSource()
    let renderer = try #require(
      StillPreviewRenderer(image: image), "Could not create still preview renderer")

    for base in [FilmBase.colorC41, .colorCyanMask] {
      let inverted = base.applyingInvert(to: ProcessingParameters())
      for endpoint in [0.0, 1.0] {
        var foliage = LookRecipe.cleanInvert
        foliage.photoAdjustments.warmHueRecovery = endpoint
        try expectParity(
          renderer, image: image, parameters: foliage.applying(to: inverted),
          label: "\(base.rawValue)/warmHueRecovery=\(endpoint)")

        var cast = LookRecipe.cleanInvert
        cast.castCleanup = endpoint
        try expectParity(
          renderer, image: image, parameters: cast.applying(to: inverted),
          label: "\(base.rawValue)/castCleanup=\(endpoint)")

        var separation = LookRecipe.cleanInvert
        separation.colorSeparation = endpoint
        try expectParity(
          renderer, image: image, parameters: separation.applying(to: inverted),
          label: "\(base.rawValue)/colorSeparation=\(endpoint)")
      }
      var recovered = LookRecipe.cleanInvert
      recovered.photoAdjustments.warmHueRecovery = 1
      #expect(
        FilmProcessing.correctedPreview(image: image, parameters: recovered.applying(to: inverted))
          != FilmProcessing.correctedPreview(
            image: image, parameters: LookRecipe.cleanInvert.applying(to: inverted)),
        "Chromatic source must activate foliage recovery on \(base.rawValue)")
    }

    // Slide currently bypasses selective recovery in both renderers. Keep its
    // endpoint parity without asserting a color effect that the app lacks.
    let slide = FilmBase.slide.applyingInvert(to: ProcessingParameters())
    var recovered = slide
    recovered.photoAdjustments.warmHueRecovery = 1
    try expectParity(
      renderer, image: image, parameters: slide, label: "slide/warmHueRecovery=0")
    try expectParity(
      renderer, image: image, parameters: recovered, label: "slide/warmHueRecovery=1")
  }

  @Test("Flat and nearly-flat density inputs explicitly require CPU rendering")
  func narrowDensityRangeRequiresCPU() throws {
    let width = 73
    let height = 47
    var samples: [(String, UInt16Image)] = [
      (
        "solid-mid",
        UInt16Image(
          width: width, height: height, channels: 3,
          pixels: [UInt16](repeating: 32_768, count: width * height * 3))
      ),
      (
        "solid-color",
        UInt16Image(
          width: width, height: height, channels: 3,
          pixels: (0..<(width * height)).flatMap { _ in [UInt16(14_000), 26_000, 45_000] })
      ),
      (
        "one-code-range",
        UInt16Image(
          width: width, height: height, channels: 3,
          pixels: (0..<(width * height)).flatMap { pixel in
            [UInt16](repeating: UInt16(32_768 + pixel % 2), count: 3)
          })
      ),
    ]
    // The 0.01% analysis clip excludes isolated center outliers at this size.
    // A fixed reference pixel would amplify cancellation again on these frames.
    for (name, outlier) in [
      ("center-bright-outlier", [UInt16(60_000), 60_000, 60_000]),
      ("center-color-outlier", [UInt16(8_000), 46_000, 60_000]),
    ] {
      let size = 256
      var pixels = [UInt16](repeating: 32_768, count: size * size * 3)
      let center = (size / 2 * size + size / 2) * 3
      pixels.replaceSubrange(center..<center + 3, with: outlier)
      samples.append((name, UInt16Image(width: size, height: size, channels: 3, pixels: pixels)))
    }
    for (name, image) in samples {
      let renderer = try #require(
        StillPreviewRenderer(image: image), "Could not create still preview renderer")
      for base in [FilmBase.colorC41, .colorCyanMask] {
        let inverted = base.applyingInvert(to: ProcessingParameters())
        var highlights = inverted
        highlights.photoAdjustments.highlights = 1
        for (variant, parameters) in [
          ("invert", inverted),
          ("cleanInvert", LookRecipe.cleanInvert.applying(to: inverted)),
          ("highlights=1", highlights),
        ] {
          let label = "\(name)/\(base.rawValue)/\(variant)"
          #expect(StillPreviewRenderer.supports(parameters: parameters, showOriginal: false))
          #expect(!renderer.supports(parameters: parameters, showOriginal: false), "\(label)")
          #expect(renderer.render(parameters: parameters, showOriginal: false) == nil, "\(label)")
          #expect(
            renderer.supports(parameters: parameters, showOriginal: true), "\(label) Original")
        }
      }
      try expectParity(
        renderer, image: image,
        parameters: FilmBase.original.applyingInvert(to: ProcessingParameters()),
        label: "\(name)/original")
      try expectParity(
        renderer, image: image,
        parameters: FilmBase.slide.applyingInvert(to: ProcessingParameters()),
        label: "\(name)/slide")
    }
  }

  @Test("The app publishes full CPU pixels for a flat density scan during edits and comparisons")
  @MainActor
  func appPublishesFlatScanCPUFallback() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-flat-density-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("flat-scan.png")
    let source = UInt16Image(
      width: 73, height: 47, channels: 3,
      pixels: [UInt16](repeating: 32_768, count: 73 * 47 * 3))
    try source.write(to: input, format: .png, parameters: .init(format: .png))
    var parameters = LookRecipe.cleanInvert.applying(
      to: FilmBase.colorC41.applyingInvert(to: ProcessingParameters()))
    parameters.photoAdjustments.highlights = 1
    parameters.rotation = 1
    parameters.flip = true
    let store = PerFileSettingsStore(baseDirectory: directory)
    try store.save(
      .init(settingsByPath: [input.standardizedFileURL.path: parameters], editedPaths: []))
    let model = AppModel(
      profileStore: ProfileStore(baseDirectory: directory.appendingPathComponent("profiles")),
      settingsStore: store)
    model.importFiles([input])
    try await waitForAppPreview(model, after: 0)
    try expectCPUPreview(model)

    // A GPU edit would obey this small overview demand. CPU fallback must still
    // publish the complete corrected source through the existing preparation path.
    let logicalSize = try #require(model.previewImage?.size)
    model.setPreviewRenderDemand(
      .init(
        documentSize: logicalSize, visibleRect: CGRect(origin: .zero, size: logicalSize),
        backingScale: 1, magnification: 0.25))
    var revision = model.publishedRenderRevision
    model.beginEditingGesture(named: "Exposure")
    model.setExposureEV(0.4)
    try await waitForAppPreview(model, after: revision)
    try expectCPUPreview(model)
    revision = model.publishedRenderRevision
    model.endEditingGesture()
    try await waitForAppPreview(model, after: revision)
    try expectCPUPreview(model)

    revision = model.publishedRenderRevision
    model.showOriginal = true
    try await waitForAppPreview(model, after: revision)
    #expect(model.status.contains(" • GPU"))
    revision = model.publishedRenderRevision
    model.showOriginal = false
    try await waitForAppPreview(model, after: revision)
    try expectCPUPreview(model)
    try await model.flushSettings()
  }

  @Test("Original bypasses active look controls while preserving orientation")
  func originalBypassesLook() throws {
    let image = chromaticSource()
    let renderer = try #require(
      StillPreviewRenderer(image: image), "Could not create still preview renderer")
    var edited = LookRecipe.foliage.applying(
      to: FilmBase.colorC41.applyingInvert(to: ProcessingParameters()))
    edited.photoAdjustments.exposureEV = 1.2
    edited.photoAdjustments.contrast = 0.5
    edited.curveEnabled = true
    edited.curveControlPoints = LookRecipe.punchyPrint.curveControlPoints
    edited.midtoneWheel = ColorWheel(hue: 210, strength: 0.3)
    edited.rotation = 1
    edited.flip = true
    let original = FilmBase.original.applyingInvert(to: edited)
    let ungraded = FilmBase.original.applyingInvert(
      to: ProcessingParameters(flip: true, rotation: 1))

    #expect(
      FilmProcessing.correctedPreview(image: image, parameters: original)
        == FilmProcessing.correctedPreview(image: image, parameters: ungraded))
    let editedPixels = try expectParity(
      renderer, image: image, parameters: original, label: "original/active-look-bypass")
    let ungradedPixels = try expectParity(
      renderer, image: image, parameters: ungraded, label: "original/orientation")
    #expect(editedPixels == ungradedPixels)
  }

  @discardableResult
  private func expectParity(
    _ renderer: StillPreviewRenderer,
    image: UInt16Image,
    parameters: ProcessingParameters,
    label: String
  ) throws -> [UInt8] {
    try #require(
      StillPreviewRenderer.supports(parameters: parameters, showOriginal: false),
      "Renderer does not support \(label)")
    try #require(
      renderer.supports(parameters: parameters, showOriginal: false),
      "Source requires CPU rendering for \(label)")
    let gpu = try #require(
      renderer.render(parameters: parameters, showOriginal: false), "GPU render failed: \(label)")
    let cpu = try #require(
      FilmProcessing.correctedPreview(image: image, parameters: parameters).makePreviewCGImage(),
      "CPU render failed: \(label)")
    let rotated = parameters.rotation % 2 != 0
    try #require(gpu.width == (rotated ? image.height : image.width), "GPU width: \(label)")
    try #require(gpu.height == (rotated ? image.width : image.height), "GPU height: \(label)")
    try #require(cpu.width == gpu.width && cpu.height == gpu.height, "CPU dimensions: \(label)")

    let gpuPixels = try rgbPixels(gpu)
    let cpuPixels = try rgbPixels(cpu)
    try #require(gpuPixels.count == cpuPixels.count)
    var maximumDifference = 0
    var worstIndex = 0
    for index in cpuPixels.indices {
      let difference = abs(Int(gpuPixels[index]) - Int(cpuPixels[index]))
      if difference > maximumDifference {
        maximumDifference = difference
        worstIndex = index
      }
    }
    #expect(
      maximumDifference <= 2,
      """
      \(label): max RGB error \(maximumDifference)/255 at pixel \(worstIndex / 3), \
      channel \(worstIndex % 3): GPU \(gpuPixels[worstIndex]), CPU \(cpuPixels[worstIndex])
      """)
    return gpuPixels
  }

  private func rgbPixels(_ image: CGImage) throws -> [UInt8] {
    try #require(image.bitsPerComponent == 8 && image.bitsPerPixel == 32)
    try #require(
      image.alphaInfo == .noneSkipLast || image.alphaInfo == .premultipliedLast
        || image.alphaInfo == .last)
    try #require(image.bitmapInfo.intersection(.byteOrderMask) != .byteOrder32Little)
    try #require(image.bytesPerRow >= image.width * 4)
    let data = try #require(image.dataProvider?.data)
    try #require(CFDataGetLength(data) >= image.bytesPerRow * (image.height - 1) + image.width * 4)
    let pointer = try #require(CFDataGetBytePtr(data))
    var pixels: [UInt8] = []
    pixels.reserveCapacity(image.width * image.height * 3)
    for y in 0..<image.height {
      for x in 0..<image.width {
        let pixel = pointer + y * image.bytesPerRow + x * 4
        pixels.append(contentsOf: UnsafeBufferPointer(start: pixel, count: 3))
      }
    }
    return pixels
  }

  @MainActor
  private func waitForAppPreview(_ model: AppModel, after revision: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while model.isLoading || model.isRendering || model.previewImage == nil
      || model.publishedRenderRevision <= revision
    {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for density fallback preview")
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @MainActor
  private func expectCPUPreview(_ model: AppModel) throws {
    let source = try #require(model.decodedImage)
    let expected = try #require(
      FilmProcessing.correctedPreview(image: source, parameters: model.parameters)
        .makePreviewCGImage())
    let displayed = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    #expect(model.status.contains(" • CPU"))
    #expect(model.previewDetail == nil)
    #expect(displayed.width == source.height && displayed.height == source.width)
    #expect(displayed.width == expected.width && displayed.height == expected.height)
    #expect(try rgbPixels(displayed) == rgbPixels(expected))
  }

  private func chromaticSource() -> UInt16Image {
    // Odd, non-square dimensions exercise aligned GPU rows and quarter turns.
    // Warm ramps activate foliage recovery; neutral and chromatic rows cover
    // both protected colors and the density bases' differing unmix matrices.
    let width = 73
    let height = 47
    var pixels: [UInt16] = []
    pixels.reserveCapacity(width * height * 3)
    for y in 0..<height {
      for x in 0..<width {
        if y % 5 == 0 {
          let value = UInt16(2_000 + x * 850)
          pixels.append(contentsOf: [value, value, value])
        } else if y % 5 == 1 {
          let red = 25_000 + (x * 431) % 32_000
          let green = red * (55 + x * 30 / (width - 1)) / 100
          pixels.append(contentsOf: [UInt16(red * 18 / 100), UInt16(green), UInt16(red)])
        } else {
          pixels.append(UInt16(3_500 + ((x + 3 * y) % 11) * 5_700))
          pixels.append(UInt16(4_000 + ((5 * x + y) % 13) * 4_500))
          pixels.append(UInt16(5_000 + ((3 * x + 7 * y) % 9) * 6_900))
        }
      }
    }
    return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
  }
}
