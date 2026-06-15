import AppKit
import Metal
import QuartzCore

let metalDevice = MTLCreateSystemDefaultDevice()!
let maxEDR = NSScreen.main!.maximumExtendedDynamicRangeColorComponentValue

let metalSource = """
#include <metal_stdlib>
using namespace metal;

kernel void fillWhite(texture2d<half, access::write> tex [[texture(0)]],
                      constant float &multiplier [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    half val = half(multiplier);
    tex.write(half4(val, val, val, 1.0), gid);
}
"""

class HDRView: NSView {
    private var metalLayer: CAMetalLayer!
    private var commandQueue: MTLCommandQueue!
    private var pipeline: MTLComputePipelineState!
    private var renderTimer: Timer?
    var multiplier: CGFloat = 1.0

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        metalLayer = layer
        return layer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }

        metalLayer.device = metalDevice
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.framebufferOnly = false
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)

        let lib = try! metalDevice.makeLibrary(source: metalSource, options: nil)
        let fn = lib.makeFunction(name: "fillWhite")!
        pipeline = try! metalDevice.makeComputePipelineState(function: fn)
        commandQueue = metalDevice.makeCommandQueue()!

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
            return nil
        }

        renderTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.render()
        }
    }

    func handleKey(_ event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 1.0 : 0.25
        switch event.keyCode {
        case 126: multiplier = min(multiplier + step, maxEDR)
        case 125: multiplier = max(multiplier - step, 0.0)
        case 29:  multiplier = 0.0
        case 15:  multiplier = maxEDR
        case 3:   multiplier = 1.0
        default: break
        }
    }

    private func render() {
        autoreleasepool {
            guard let drawable = metalLayer.nextDrawable(),
                  let cmdBuf = commandQueue.makeCommandBuffer(),
                  let encoder = cmdBuf.makeComputeCommandEncoder()
            else { return }

            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(drawable.texture, index: 0)
            var m = Float(multiplier)
            encoder.setBytes(&m, length: MemoryLayout<Float>.size, index: 0)

            let w = pipeline.threadExecutionWidth
            let h = pipeline.maxTotalThreadsPerThreadgroup / w
            encoder.dispatchThreads(
                MTLSize(width: drawable.texture.width, height: drawable.texture.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
            encoder.endEncoding()

            cmdBuf.present(drawable)
            cmdBuf.commit()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var hdrView: HDRView!
    weak var label: NSTextField!

    func applicationDidFinishLaunching(_: Notification) {
        let screen = NSScreen.main!
        let sw = screen.frame.width
        let sh = screen.frame.height
        let w: CGFloat = 800, h: CGFloat = 600
        let rect = NSRect(x: (sw - w) / 2, y: (sh - h) / 2, width: w, height: h)

        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "HDR White — EDR max: \(String(format: "%.1f", maxEDR))x"
        window.level = .floating
        window.isMovableByWindowBackground = true

        hdrView = HDRView(frame: .zero)
        hdrView.wantsLayer = true
        hdrView.multiplier = maxEDR
        hdrView.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        label.isBezeled = false
        label.isEditable = false
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        self.label = label

        hdrView.addSubview(label)
        NSLayoutConstraint.activate([
            label.bottomAnchor.constraint(equalTo: hdrView.bottomAnchor, constant: -12),
            label.centerXAnchor.constraint(equalTo: hdrView.centerXAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        window.contentView = hdrView
        window.makeKeyAndOrderFront(nil)

        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let m = self.hdrView.multiplier
            let pct = Int((m / maxEDR) * 100)
            self.label.stringValue = "  \(String(format: "%.2f", m))x  (\(pct)%)  "
            self.window.title = "HDR White — EDR max: \(String(format: "%.1f", maxEDR))x"
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
