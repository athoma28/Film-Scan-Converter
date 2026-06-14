@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import FilmScanEngine
import Metal

final class CameraController: NSObject, ObservableObject,
  AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable
{
  @Published private(set) var image: CGImage?
  @Published private(set) var status = "Live preview stopped."
  @Published private(set) var isRunning = false
  @Published private(set) var invertNegative = true
  @Published private(set) var exposure: Float = 0
  @Published private(set) var saturation: Float = 1

  private let session = AVCaptureSession()
  private let captureQueue = DispatchQueue(label: "FilmScanConverter.capture")
  private let processingQueue = DispatchQueue(
    label: "FilmScanConverter.preview", qos: .userInteractive)
  private let context: CIContext
  private let settingsLock = NSLock()
  private var settings = LiveSettings()
  private var throttle = LivePreviewThrottle(maximumFramesPerSecond: 20)

  override init() {
    if let device = MTLCreateSystemDefaultDevice() {
      context = CIContext(mtlDevice: device)
    } else {
      context = CIContext(options: [.useSoftwareRenderer: false])
    }
    super.init()
  }

  func toggle() {
    isRunning ? stop() : start()
  }

  func setInvertNegative(_ value: Bool) {
    invertNegative = value
    settingsLock.withLock {
      settings.invertNegative = value
    }
  }

  func setExposure(_ value: Float) {
    exposure = value
    settingsLock.withLock {
      settings.exposure = value
    }
  }

  func setSaturation(_ value: Float) {
    saturation = value
    settingsLock.withLock {
      settings.saturation = value
    }
  }

  func start() {
    status = "Requesting camera access..."
    AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
      guard let self else { return }
      guard granted else {
        DispatchQueue.main.async {
          self.status = "Camera access was denied."
        }
        return
      }
      self.captureQueue.async {
        self.configureAndStart()
      }
    }
  }

  func stop() {
    captureQueue.async { [weak self] in
      guard let self else { return }
      self.session.stopRunning()
      DispatchQueue.main.async {
        self.isRunning = false
        self.status = "Live preview stopped."
      }
    }
  }

  private func configureAndStart() {
    guard !session.isRunning else { return }
    session.beginConfiguration()
    var configurationCommitted = false
    defer {
      if !configurationCommitted {
        session.commitConfiguration()
      }
    }

    session.inputs.forEach(session.removeInput)
    session.outputs.forEach(session.removeOutput)
    session.sessionPreset = .high

    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.external, .builtInWideAngleCamera],
      mediaType: .video,
      position: .unspecified
    )
    guard
      let device = discovery.devices.first(where: { $0.deviceType == .external })
        ?? discovery.devices.first
    else {
      DispatchQueue.main.async {
        self.status =
          "No AVFoundation video device found. The DSLR may require vendor tethering software."
      }
      return
    }

    do {
      let input = try AVCaptureDeviceInput(device: device)
      guard session.canAddInput(input) else {
        throw CameraError.cannotAddInput
      }
      session.addInput(input)

      let output = AVCaptureVideoDataOutput()
      output.alwaysDiscardsLateVideoFrames = true
      output.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
      output.setSampleBufferDelegate(self, queue: processingQueue)
      guard session.canAddOutput(output) else {
        throw CameraError.cannotAddOutput
      }
      session.addOutput(output)
      session.commitConfiguration()
      configurationCommitted = true
      session.startRunning()

      DispatchQueue.main.async {
        self.isRunning = true
        self.status = "Live preview: \(device.localizedName)"
      }
    } catch {
      DispatchQueue.main.async {
        self.status = "Unable to start live preview: \(error.localizedDescription)"
      }
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    guard throttle.shouldProcess(timestamp: timestamp),
      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    else {
      return
    }

    let currentSettings = settingsLock.withLock { settings }
    var frame = CIImage(cvPixelBuffer: pixelBuffer)
    if currentSettings.invertNegative {
      frame = frame.applyingFilter("CIColorInvert")
    }
    frame = frame.applyingFilter(
      "CIColorControls",
      parameters: [
        kCIInputSaturationKey: currentSettings.saturation,
        kCIInputBrightnessKey: 0,
        kCIInputContrastKey: 1,
      ]
    )
    frame = frame.applyingFilter(
      "CIExposureAdjust",
      parameters: [kCIInputEVKey: currentSettings.exposure]
    )

    guard let rendered = context.createCGImage(frame, from: frame.extent) else {
      return
    }
    DispatchQueue.main.async {
      self.image = rendered
    }
  }
}

private struct LiveSettings {
  var invertNegative = true
  var exposure: Float = 0
  var saturation: Float = 1
}

enum CameraError: LocalizedError {
  case cannotAddInput
  case cannotAddOutput

  var errorDescription: String? {
    switch self {
    case .cannotAddInput: "The selected camera cannot be added to the capture session."
    case .cannotAddOutput: "The camera cannot supply video frames."
    }
  }
}
