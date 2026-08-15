import AppKit
import FilmScanEngine
import SwiftUI

struct StraightenLineOverlay: View {
  let isActive: Bool
  let imageSize: CGSize
  let onGuideCompleted: (Double) -> Void

  @State private var startPoint: CGPoint?
  @State private var hoverPoint: CGPoint?

  var body: some View {
    GeometryReader { geometry in
      let imageRect = PreviewOverlayGeometry.aspectFitRect(
        imageSize: imageSize,
        containerSize: geometry.size
      )
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
                    y: (startPoint.y + endPoint.y) / 2 - 18
                  )
              }
            }
          }
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
          switch phase {
          case .active(let location):
            if startPoint != nil {
              hoverPoint = PreviewOverlayGeometry.clampedPoint(location, to: imageRect)
            }
          case .ended:
            hoverPoint = nil
          }
        }
        .gesture(
          DragGesture(minimumDistance: 0)
            .onEnded { value in
              guard imageRect.contains(value.location) else { return }
              let point = PreviewOverlayGeometry.clampedPoint(value.location, to: imageRect)
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
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Straighten image")
    .accessibilityHint(
      "Choose two points along an edge that should be horizontal or vertical."
    )
    .accessibilityAction(named: Text("Rotate clockwise by a quarter degree")) {
      onGuideCompleted(0.25)
    }
    .accessibilityAction(named: Text("Rotate counterclockwise by a quarter degree")) {
      onGuideCompleted(-0.25)
    }
    .accessibilityHidden(!isActive)
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
      deltaY: end.y - start.y
    )
  }
}

struct ManualCropOverlay: View {
  let isActive: Bool
  let imageSize: CGSize
  let onCropCompleted: (NormalizedCropRect) -> Void

  @State private var startPoint: CGPoint?
  @State private var endPoint: CGPoint?

  var body: some View {
    GeometryReader { geometry in
      let imageRect = PreviewOverlayGeometry.aspectFitRect(
        imageSize: imageSize,
        containerSize: geometry.size
      )
      if isActive, imageRect.width > 0, imageRect.height > 0 {
        ZStack {
          Color.clear
          if let startPoint, let endPoint {
            let cropRect = CGRect(
              x: min(startPoint.x, endPoint.x),
              y: min(startPoint.y, endPoint.y),
              width: abs(endPoint.x - startPoint.x),
              height: abs(endPoint.y - startPoint.y)
            )
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
                startPoint = PreviewOverlayGeometry.clampedPoint(
                  value.startLocation,
                  to: imageRect
                )
              }
              endPoint = PreviewOverlayGeometry.clampedPoint(value.location, to: imageRect)
            }
            .onEnded { value in
              defer {
                startPoint = nil
                endPoint = nil
              }
              guard let startPoint else { return }
              let endPoint = PreviewOverlayGeometry.clampedPoint(value.location, to: imageRect)
              let width = abs(endPoint.x - startPoint.x)
              let height = abs(endPoint.y - startPoint.y)
              guard width >= 4, height >= 4 else { return }
              onCropCompleted(
                NormalizedCropRect(
                  x: (min(startPoint.x, endPoint.x) - imageRect.minX) / imageRect.width,
                  y: (min(startPoint.y, endPoint.y) - imageRect.minY) / imageRect.height,
                  width: width / imageRect.width,
                  height: height / imageRect.height
                )
              )
            }
        )
      }
    }
    .allowsHitTesting(isActive)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Crop image")
    .accessibilityHint("Drag over the part of the image to keep.")
    .accessibilityAction(named: Text("Crop five percent from each edge")) {
      onCropCompleted(.init(x: 0.05, y: 0.05, width: 0.9, height: 0.9))
    }
    .accessibilityAction(named: Text("Crop ten percent from each edge")) {
      onCropCompleted(.init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
    }
    .accessibilityHidden(!isActive)
    .onChange(of: isActive) {
      if !isActive {
        startPoint = nil
        endPoint = nil
      }
    }
  }
}

struct PerspectiveCropOverlay: View {
  let isActive: Bool
  let crop: PerspectiveCrop?
  let image: NSImage?
  let imageSize: CGSize
  let rotation: Int
  let flipHorizontally: Bool
  let usesParallelAssist: Bool
  let onCropChanged: (PerspectiveCrop) -> Void

  @State private var draggedCorner: Int?
  @Environment(\.editingGestureAction) private var editingGestureAction

  var body: some View {
    GeometryReader { geometry in
      let imageRect = PreviewOverlayGeometry.aspectFitRect(
        imageSize: imageSize,
        containerSize: geometry.size
      )
      if isActive, let crop, imageRect.width > 0, imageRect.height > 0 {
        let displayedPoints = crop.points.map {
          PreviewOverlayGeometry.displayedPoint(
            $0,
            rotation: rotation,
            flipHorizontally: flipHorizontally
          )
        }
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
          .stroke(
            Color.accentColor.opacity(0.85),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
          )

          ForEach(Array(points.enumerated()), id: \.offset) { index, point in
            cornerReticle
              .contentShape(Circle().inset(by: -10))
              .position(point)
              .gesture(
                DragGesture(minimumDistance: 0)
                  .onChanged { value in
                    editingGestureAction("Perspective", true)
                    draggedCorner = index
                    let clamped = PreviewOverlayGeometry.clampedPoint(
                      value.location,
                      to: imageRect
                    )
                    let displayed = PerspectiveCrop.Point(
                      x: (clamped.x - imageRect.minX) / imageRect.width,
                      y: (clamped.y - imageRect.minY) / imageRect.height
                    )
                    let source = PreviewOverlayGeometry.sourcePoint(
                      fromDisplayed: displayed,
                      rotation: rotation,
                      flipHorizontally: flipHorizontally
                    )
                    let assistEnabled =
                      usesParallelAssist
                      && !NSEvent.modifierFlags.contains(.option)
                    let threshold = 18 / max(1, min(imageRect.width, imageRect.height))
                    onCropChanged(
                      assistEnabled
                        ? crop.replacing(
                          index,
                          with: source,
                          parallelismAssistThreshold: threshold
                        )
                        : crop.replacing(index, with: source)
                    )
                  }
                  .onEnded { _ in
                    draggedCorner = nil
                    editingGestureAction("Perspective", false)
                  }
              )
              .help(["Top left", "Top right", "Bottom right", "Bottom left"][index])
              .accessibilityElement()
              .accessibilityLabel(
                [
                  "Top left perspective corner",
                  "Top right perspective corner",
                  "Bottom right perspective corner",
                  "Bottom left perspective corner",
                ][index]
              )
              .accessibilityValue(
                String(
                  format: "%.0f percent horizontal, %.0f percent vertical",
                  displayedPoints[index].x * 100,
                  displayedPoints[index].y * 100
                )
              )
              .accessibilityHint("Drag the corner, or use the move actions.")
              .accessibilityAction(named: Text("Move left")) {
                nudgeCorner(index, in: crop, displayedX: -0.01, displayedY: 0)
              }
              .accessibilityAction(named: Text("Move right")) {
                nudgeCorner(index, in: crop, displayedX: 0.01, displayedY: 0)
              }
              .accessibilityAction(named: Text("Move up")) {
                nudgeCorner(index, in: crop, displayedX: 0, displayedY: -0.01)
              }
              .accessibilityAction(named: Text("Move down")) {
                nudgeCorner(index, in: crop, displayedX: 0, displayedY: 0.01)
              }
          }

          if let draggedCorner, let image {
            CornerLoupe(
              image: image,
              normalizedPoint: displayedPoints[draggedCorner],
              samplePixelSize: 100
            )
            .frame(width: 144, height: 144)
            .position(points[draggedCorner])
            .allowsHitTesting(false)
          }
        }
      }
    }
    .allowsHitTesting(isActive)
    .accessibilityHidden(!isActive)
  }

  private var cornerReticle: some View {
    ZStack {
      Circle()
        .fill(.black.opacity(0.22))
        .stroke(.white, lineWidth: 1.5)
      Circle()
        .stroke(Color.accentColor, lineWidth: 2)
        .padding(4)
      Rectangle().fill(.white).frame(width: 1, height: 24)
      Rectangle().fill(.white).frame(width: 24, height: 1)
      Circle().fill(Color.accentColor).frame(width: 3, height: 3)
    }
    .frame(width: 28, height: 28)
    .shadow(color: .black.opacity(0.65), radius: 2)
  }

  private func nudgeCorner(
    _ index: Int,
    in crop: PerspectiveCrop,
    displayedX: Double,
    displayedY: Double
  ) {
    let current = PreviewOverlayGeometry.displayedPoint(
      crop.points[index],
      rotation: rotation,
      flipHorizontally: flipHorizontally
    )
    let displayed = PerspectiveCrop.Point(
      x: min(max(Double(current.x) + displayedX, 0), 1),
      y: min(max(Double(current.y) + displayedY, 0), 1)
    )
    let source = PreviewOverlayGeometry.sourcePoint(
      fromDisplayed: displayed,
      rotation: rotation,
      flipHorizontally: flipHorizontally
    )
    onCropChanged(crop.replacing(index, with: source))
  }

  private func interpolate(_ start: CGPoint, _ end: CGPoint, fraction: CGFloat) -> CGPoint {
    CGPoint(
      x: start.x + (end.x - start.x) * fraction,
      y: start.y + (end.y - start.y) * fraction
    )
  }
}

private struct CornerLoupe: View {
  let image: NSImage
  let normalizedPoint: CGPoint
  let samplePixelSize: CGFloat

  var body: some View {
    GeometryReader { geometry in
      let scale = geometry.size.width / max(1, samplePixelSize)
      let scaledSize = CGSize(
        width: image.size.width * scale,
        height: image.size.height * scale
      )
      ZStack {
        Color.black
        Image(nsImage: image)
          .resizable()
          .interpolation(.none)
          .frame(width: scaledSize.width, height: scaledSize.height)
          .offset(
            x: (0.5 - normalizedPoint.x) * scaledSize.width,
            y: (0.5 - normalizedPoint.y) * scaledSize.height
          )
        Rectangle().fill(.black.opacity(0.8)).frame(width: 1, height: 34)
        Rectangle().fill(.black.opacity(0.8)).frame(width: 34, height: 1)
        Rectangle().fill(.white).frame(width: 1, height: 18)
        Rectangle().fill(.white).frame(width: 18, height: 1)
        Circle().stroke(Color.accentColor, lineWidth: 2).frame(width: 10, height: 10)
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color.accentColor, lineWidth: 2)
          .padding(-3)
      )
      .shadow(color: .black.opacity(0.8), radius: 5)
    }
    .accessibilityHidden(true)
  }
}

struct RebateRegionSelectionOverlay: View {
  let isActive: Bool
  let imageSize: CGSize
  @Binding var dragStart: CGPoint?
  @Binding var dragEnd: CGPoint?
  let onSelection: (Double, Double, Double, Double) -> Void

  var body: some View {
    GeometryReader { geometry in
      let imageRect = PreviewOverlayGeometry.aspectFitRect(
        imageSize: imageSize,
        containerSize: geometry.size
      )
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
            let point = PreviewOverlayGeometry.clampedPoint(value.location, to: imageRect)
            if dragStart == nil {
              dragStart = point
            }
            dragEnd = point
          }
          .onEnded { value in
            guard let start = dragStart else { return }
            let end = PreviewOverlayGeometry.clampedPoint(value.location, to: imageRect)
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
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Select unexposed film base")
      .accessibilityHint("Drag over a clear film edge, or choose one of the edge actions.")
      .accessibilityAction(named: Text("Select top edge")) {
        onSelection(0, 0, 1, 0.1)
      }
      .accessibilityAction(named: Text("Select bottom edge")) {
        onSelection(0, 0.9, 1, 0.1)
      }
      .accessibilityAction(named: Text("Select left edge")) {
        onSelection(0, 0, 0.1, 1)
      }
      .accessibilityAction(named: Text("Select right edge")) {
        onSelection(0.9, 0, 0.1, 1)
      }
      .accessibilityHidden(!isActive)
    }
  }
}
