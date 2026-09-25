import AppKit
import FilmScanEngine
import SwiftUI

struct StraightenLineOverlay: View {
  let isActive: Bool
  let imageSize: CGSize
  var magnification: CGFloat = 1
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
            let dot = PreviewOverlayGeometry.documentLength(
              PreviewOverlayGeometry.straightenDotScreenLength, magnification: magnification)
            let stroke = PreviewOverlayGeometry.documentLength(
              PreviewOverlayGeometry.strokeScreenLength, magnification: magnification)
            Circle()
              .fill(Color.yellow)
              .overlay(Circle().stroke(.black.opacity(0.7), lineWidth: stroke))
              .frame(width: dot, height: dot)
              .position(startPoint)
            if let endPoint = hoverPoint {
              Path { path in
                path.move(to: startPoint)
                path.addLine(to: endPoint)
              }
              .stroke(Color.yellow, style: StrokeStyle(lineWidth: stroke, dash: [6, 4]))
              Circle()
                .fill(Color.yellow)
                .overlay(Circle().stroke(.black.opacity(0.7), lineWidth: stroke))
                .frame(width: dot, height: dot)
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
              hoverPoint = PreviewOverlayGeometry.clampedPoint(
                PreviewOverlayGeometry.documentGesturePoint(
                  location, magnification: magnification),
                to: imageRect)
            }
          case .ended:
            hoverPoint = nil
          }
        }
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              let start = PreviewOverlayGeometry.documentGesturePoint(
                value.startLocation, magnification: magnification)
              guard startPoint != nil || imageRect.contains(start) else { return }
              if startPoint == nil {
                startPoint = PreviewOverlayGeometry.clampedPoint(start, to: imageRect)
              }
              hoverPoint = PreviewOverlayGeometry.clampedPoint(
                PreviewOverlayGeometry.documentGesturePoint(
                  value.location, magnification: magnification),
                to: imageRect)
            }
            .onEnded { value in
              let point = PreviewOverlayGeometry.clampedPoint(
                PreviewOverlayGeometry.documentGesturePoint(
                  value.location, magnification: magnification),
                to: imageRect)
              guard let startPoint else { return }
              let minLength = PreviewOverlayGeometry.documentLength(
                PreviewOverlayGeometry.minStraightenScreenLength, magnification: magnification)
              guard hypot(point.x - startPoint.x, point.y - startPoint.y) >= minLength else {
                hoverPoint = point
                return
              }
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
      onGuideCompleted(-0.25)
    }
    .accessibilityAction(named: Text("Rotate counterclockwise by a quarter degree")) {
      onGuideCompleted(0.25)
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
  let crop: NormalizedCropRect?
  let imageSize: CGSize
  var magnification: CGFloat = 1
  var aspectRatio: Double?
  let onCropChanged: (NormalizedCropRect) -> Void

  @State private var drawStart: CGPoint?
  @State private var drawEnd: CGPoint?
  @State private var dragOperation: DragOperation?
  @State private var dragOrigin: NormalizedCropRect?
  @State private var dragStart: CGPoint?
  @Environment(\.editingGestureAction) private var editingGestureAction

  private enum DragOperation {
    case drawing
    case moving
    case handle(NormalizedCropRect.Handle)
  }

  var body: some View {
    GeometryReader { geometry in
      let imageRect = PreviewOverlayGeometry.aspectFitRect(
        imageSize: imageSize,
        containerSize: geometry.size
      )
      if isActive, imageRect.width > 0, imageRect.height > 0 {
        let stroke = PreviewOverlayGeometry.documentLength(
          PreviewOverlayGeometry.strokeScreenLength, magnification: magnification)
        let handleSize = PreviewOverlayGeometry.documentLength(
          PreviewOverlayGeometry.cropHandleScreenLength, magnification: magnification)
        let hitPadding = PreviewOverlayGeometry.documentLength(
          PreviewOverlayGeometry.handleHitPadding, magnification: magnification)
        let minSize = PreviewOverlayGeometry.documentLength(
          PreviewOverlayGeometry.minCropScreenLength, magnification: magnification)
        let minNormalizedWidth = Double(minSize / max(imageRect.width, 1))
        let minNormalizedHeight = Double(minSize / max(imageRect.height, 1))
        let displayedRect = displayedCropRect(in: imageRect)
        ZStack {
          Color.clear
            .contentShape(Rectangle())

          if let displayedRect {
            Path { path in
              path.addRect(imageRect)
              path.addRect(displayedRect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
              .stroke(Color.white, lineWidth: stroke)
              .frame(width: displayedRect.width, height: displayedRect.height)
              .position(x: displayedRect.midX, y: displayedRect.midY)
              .allowsHitTesting(false)

            if drawStart == nil, let crop {
              ForEach(NormalizedCropRect.Handle.allCases, id: \.rawValue) { handle in
                cropHandle
                  .frame(width: handleSize, height: handleSize)
                  .position(
                    PreviewOverlayGeometry.documentPoint(
                      crop.handlePosition(handle), in: imageRect)
                  )
                  .help(handleHelp(handle))
                  .allowsHitTesting(false)
              }
            }
          }
        }
        .coordinateSpace(.named("cropOverlay"))
        .contentShape(Rectangle())
        .gesture(
          cropGesture(
            crop: crop,
            in: imageRect,
            hitRadius: handleSize / 2 + hitPadding,
            minSize: minSize,
            minWidth: minNormalizedWidth,
            minHeight: minNormalizedHeight))
      }
    }
    .allowsHitTesting(isActive)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Crop image")
    .accessibilityHint(
      "Drag a rectangle to crop, then adjust the handles. Drag inside the box to move it."
    )
    .accessibilityAction(named: Text("Crop five percent from each edge")) {
      onCropChanged(.init(x: 0.05, y: 0.05, width: 0.9, height: 0.9))
    }
    .accessibilityAction(named: Text("Crop ten percent from each edge")) {
      onCropChanged(.init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
    }
    .accessibilityHidden(!isActive)
    .onChange(of: isActive) {
      if !isActive {
        drawStart = nil
        drawEnd = nil
        dragOperation = nil
        dragOrigin = nil
        dragStart = nil
      }
    }
  }

  private var cropHandle: some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(.white)
      .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.85), lineWidth: 1))
      .shadow(color: .black.opacity(0.45), radius: 1)
  }

  private func displayedCropRect(in imageRect: CGRect) -> CGRect? {
    if let drawStart, let drawEnd {
      return PreviewOverlayGeometry.drawnCropRect(
        from: drawStart, to: drawEnd, in: imageRect, aspectRatio: aspectRatio)
    }
    if let crop {
      return PreviewOverlayGeometry.documentRect(for: crop, in: imageRect)
    }
    return nil
  }

  private func cropGesture(
    crop: NormalizedCropRect?,
    in imageRect: CGRect,
    hitRadius: CGFloat,
    minSize: CGFloat,
    minWidth: Double,
    minHeight: Double
  ) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named("cropOverlay"))
      .onChanged { value in
        let start = PreviewOverlayGeometry.clampedPoint(
          PreviewOverlayGeometry.documentGesturePoint(
            value.startLocation, magnification: magnification),
          to: imageRect)
        let current = PreviewOverlayGeometry.clampedPoint(
          PreviewOverlayGeometry.documentGesturePoint(
            value.location, magnification: magnification),
          to: imageRect)
        let operation: DragOperation
        if let dragOperation {
          operation = dragOperation
        } else {
          guard
            imageRect.contains(
              PreviewOverlayGeometry.documentGesturePoint(
                value.startLocation, magnification: magnification))
          else { return }
          if let crop,
            let handle = PreviewOverlayGeometry.nearestCropHandle(
              to: start, crop: crop, imageRect: imageRect, hitRadius: hitRadius)
          {
            operation = .handle(handle)
          } else if let crop,
            PreviewOverlayGeometry.documentRect(for: crop, in: imageRect).contains(start)
          {
            operation = .moving
          } else {
            operation = .drawing
            drawStart = start
          }
          dragOperation = operation
          dragOrigin = crop
          dragStart = start
          editingGestureAction("Crop", true)
        }

        switch operation {
        case .drawing:
          drawEnd = current
        case .moving:
          guard let dragOrigin, let dragStart else { return }
          onCropChanged(
            dragOrigin.translated(
              dx: (current.x - dragStart.x) / imageRect.width,
              dy: (current.y - dragStart.y) / imageRect.height))
        case .handle(let handle):
          guard let dragOrigin else { return }
          let point = PreviewOverlayGeometry.normalizedPoint(current, in: imageRect)
          if let aspectRatio {
            onCropChanged(
              dragOrigin.movingHandle(
                handle, to: point, minWidth: minWidth, minHeight: minHeight,
                aspectRatio: aspectRatio))
          } else {
            onCropChanged(
              dragOrigin.movingHandle(
                handle, to: point, minWidth: minWidth, minHeight: minHeight))
          }
        }
      }
      .onEnded { value in
        defer {
          drawStart = nil
          drawEnd = nil
          dragOperation = nil
          dragOrigin = nil
          dragStart = nil
          editingGestureAction("Crop", false)
        }
        guard let dragOperation else { return }
        guard case .drawing = dragOperation, let drawStart else { return }
        let end = PreviewOverlayGeometry.clampedPoint(
          PreviewOverlayGeometry.documentGesturePoint(
            value.location, magnification: magnification),
          to: imageRect)
        let rect = PreviewOverlayGeometry.drawnCropRect(
          from: drawStart, to: end, in: imageRect, aspectRatio: aspectRatio)
        guard rect.width >= minSize, rect.height >= minSize else { return }
        onCropChanged(PreviewOverlayGeometry.normalizedCrop(for: rect, in: imageRect))
      }
  }

  private func handleHelp(_ handle: NormalizedCropRect.Handle) -> String {
    switch handle {
    case .topLeft: "Top left crop"
    case .top: "Top crop"
    case .topRight: "Top right crop"
    case .right: "Right crop"
    case .bottomRight: "Bottom right crop"
    case .bottom: "Bottom crop"
    case .bottomLeft: "Bottom left crop"
    case .left: "Left crop"
    }
  }
}

struct PerspectiveCropOverlay: View {
  let isActive: Bool
  let crop: PerspectiveCrop?
  let image: NSImage?
  let imageSize: CGSize
  let sourceDimensions: PixelDimensions?
  let borderPercent: Double
  let rotation: Int
  let flipHorizontally: Bool
  let usesParallelAssist: Bool
  var magnification: CGFloat = 1
  let onCropChanged: (PerspectiveCrop) -> Void

  @State private var draggedCorner: Int?
  @State private var dragOrigin: PerspectiveCrop?
  @State private var selectedCorner: Int?
  @FocusState private var hasKeyboardFocus: Bool
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
        let handleSize = PreviewOverlayGeometry.documentLength(
          PreviewOverlayGeometry.handleScreenLength, magnification: magnification)
        let hitPadding = PreviewOverlayGeometry.documentLength(
          PreviewOverlayGeometry.handleHitPadding, magnification: magnification)
        let stroke = PreviewOverlayGeometry.documentLength(
          PreviewOverlayGeometry.strokeScreenLength, magnification: magnification, minimum: 0.05)
        let loupeSize = PreviewOverlayGeometry.documentLength(
          PreviewOverlayGeometry.loupeScreenLength, magnification: magnification)
        let framedCrop = crop.inset(borderPercent: borderPercent)
        let framePoints = framedCrop.points.map {
          documentPoint($0, in: imageRect)
        }
        ZStack {
          Color.clear
            .contentShape(Rectangle())

          Path { path in
            path.addRect(imageRect)
            path.move(to: framePoints[0])
            for point in framePoints.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
          }
          .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
          .allowsHitTesting(false)

          Path { path in
            path.move(to: points[0])
            path.addLine(to: points[1])
            path.addLine(to: points[2])
            path.addLine(to: points[3])
            path.closeSubpath()
          }
          .stroke(Color.accentColor, lineWidth: stroke)

          Path { path in
            if borderPercent > 0 {
              path.move(to: framePoints[0])
              for point in framePoints.dropFirst() { path.addLine(to: point) }
              path.closeSubpath()
            }
            for line in framedCrop.gridLines() {
              path.move(to: documentPoint(line.start, in: imageRect))
              path.addLine(to: documentPoint(line.end, in: imageRect))
            }
          }
          .stroke(
            Color.accentColor.opacity(0.85),
            style: StrokeStyle(
              lineWidth: stroke * 0.5,
              dash: [
                PreviewOverlayGeometry.documentLength(
                  4, magnification: magnification, minimum: 0.05)
              ])
          )

          ForEach(Array(points.enumerated()), id: \.offset) { index, point in
            cornerReticle(size: handleSize, stroke: stroke, selected: selectedCorner == index)
              .position(point)
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
                  format: "%.2f percent horizontal, %.2f percent vertical",
                  displayedPoints[index].x * 100,
                  displayedPoints[index].y * 100
                )
              )
              .accessibilityHint(
                "Drag the corner, or move it one source pixel with the move actions."
              )
              .accessibilityAction(named: Text("Move left")) {
                nudgeCorner(index, in: crop, displayedX: -1, displayedY: 0)
              }
              .accessibilityAction(named: Text("Move right")) {
                nudgeCorner(index, in: crop, displayedX: 1, displayedY: 0)
              }
              .accessibilityAction(named: Text("Move up")) {
                nudgeCorner(index, in: crop, displayedX: 0, displayedY: -1)
              }
              .accessibilityAction(named: Text("Move down")) {
                nudgeCorner(index, in: crop, displayedX: 0, displayedY: 1)
              }
              .allowsHitTesting(false)
          }

          if let activeCorner = draggedCorner ?? (hasKeyboardFocus ? selectedCorner : nil),
            let image
          {
            CornerLoupe(
              image: image,
              normalizedPoint: displayedPoints[activeCorner],
              samplePixelSize: 100
            )
            .frame(width: loupeSize, height: loupeSize)
            .position(points[activeCorner])
            .allowsHitTesting(false)
          }
        }
        .coordinateSpace(.named("previewOverlay"))
        .contentShape(Rectangle())
        .gesture(
          perspectiveGesture(
            crop: crop,
            points: points,
            imageRect: imageRect,
            hitRadius: handleSize / 2 + hitPadding)
        )
        .focusable()
        .focused($hasKeyboardFocus)
        .focusEffectDisabled()
        .onMoveCommand { direction in
          guard let selectedCorner else { return }
          let step: Double = NSEvent.modifierFlags.contains(.shift) ? 10 : 1
          switch direction {
          case .left: nudgeCorner(selectedCorner, in: crop, displayedX: -step, displayedY: 0)
          case .right: nudgeCorner(selectedCorner, in: crop, displayedX: step, displayedY: 0)
          case .up: nudgeCorner(selectedCorner, in: crop, displayedX: 0, displayedY: -step)
          case .down: nudgeCorner(selectedCorner, in: crop, displayedX: 0, displayedY: step)
          @unknown default: break
          }
        }
      }
    }
    .allowsHitTesting(isActive)
    .accessibilityHidden(!isActive)
    .onChange(of: isActive) {
      if !isActive {
        draggedCorner = nil
        dragOrigin = nil
        selectedCorner = nil
        hasKeyboardFocus = false
      }
    }
  }

  private func cornerReticle(size: CGFloat, stroke: CGFloat, selected: Bool) -> some View {
    let cross = size * 0.85
    let pad = size * 0.14
    return ZStack {
      Circle()
        .fill(selected ? Color.accentColor.opacity(0.4) : .black.opacity(0.22))
        .stroke(.white, lineWidth: stroke * 0.75)
      Circle()
        .stroke(Color.accentColor, lineWidth: stroke)
        .padding(pad)
      Rectangle().fill(.white).frame(width: stroke * 0.5, height: cross)
      Rectangle().fill(.white).frame(width: cross, height: stroke * 0.5)
      Circle().fill(Color.accentColor).frame(width: stroke * 1.5, height: stroke * 1.5)
    }
    .frame(width: size, height: size)
    .shadow(color: .black.opacity(0.65), radius: stroke)
  }

  private func perspectiveGesture(
    crop: PerspectiveCrop,
    points: [CGPoint],
    imageRect: CGRect,
    hitRadius: CGFloat
  ) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named("previewOverlay"))
      .onChanged { value in
        if draggedCorner == nil {
          let start = PreviewOverlayGeometry.documentGesturePoint(
            value.startLocation, magnification: magnification)
          guard
            let index = PreviewOverlayGeometry.nearestPointIndex(
              to: start, points: points, hitRadius: hitRadius)
          else { return }
          draggedCorner = index
          selectedCorner = index
          hasKeyboardFocus = true
          dragOrigin = crop
          editingGestureAction("Perspective", true)
        }
        guard let draggedCorner, let dragOrigin else { return }
        let assistEnabled = usesParallelAssist && !NSEvent.modifierFlags.contains(.option)
        onCropChanged(
          PreviewOverlayGeometry.movingPerspectiveCorner(
            draggedCorner, in: dragOrigin, screenTranslation: value.translation,
            imageRect: imageRect, magnification: magnification,
            rotation: rotation, flipHorizontally: flipHorizontally,
            parallelAssist: assistEnabled))
      }
      .onEnded { _ in
        guard draggedCorner != nil else { return }
        draggedCorner = nil
        dragOrigin = nil
        editingGestureAction("Perspective", false)
      }
  }

  private func nudgeCorner(
    _ index: Int,
    in crop: PerspectiveCrop,
    displayedX: Double,
    displayedY: Double
  ) {
    let rotated = rotation % 2 != 0
    let dimensions =
      sourceDimensions
      ?? PixelDimensions(
        width: Int(rotated ? imageSize.height : imageSize.width),
        height: Int(rotated ? imageSize.width : imageSize.height))
    onCropChanged(
      PreviewOverlayGeometry.nudgingPerspectiveCorner(
        index, in: crop, displayedPixels: CGSize(width: displayedX, height: displayedY),
        sourceDimensions: dimensions, rotation: rotation, flipHorizontally: flipHorizontally))
  }

  private func documentPoint(_ source: PerspectiveCrop.Point, in imageRect: CGRect) -> CGPoint {
    let point = PreviewOverlayGeometry.displayedPoint(
      source, rotation: rotation, flipHorizontally: flipHorizontally)
    return CGPoint(
      x: imageRect.minX + point.x * imageRect.width,
      y: imageRect.minY + point.y * imageRect.height)
  }
}

private struct CornerLoupe: View {
  let image: NSImage
  let normalizedPoint: CGPoint
  let samplePixelSize: CGFloat

  var body: some View {
    GeometryReader { geometry in
      let scale = geometry.size.width / max(1, samplePixelSize)
      let unit = geometry.size.width / PreviewOverlayGeometry.loupeScreenLength
      let scaledSize = CGSize(
        width: image.size.width * scale,
        height: image.size.height * scale
      )
      ZStack {
        Color.black
        RasterImage(image: image, interpolation: .none)
          .frame(width: scaledSize.width, height: scaledSize.height)
          .offset(
            x: (0.5 - normalizedPoint.x) * scaledSize.width,
            y: (0.5 - normalizedPoint.y) * scaledSize.height
          )
        Rectangle().fill(.black.opacity(0.8)).frame(width: unit, height: 34 * unit)
        Rectangle().fill(.black.opacity(0.8)).frame(width: 34 * unit, height: unit)
        Rectangle().fill(.white).frame(width: unit, height: 18 * unit)
        Rectangle().fill(.white).frame(width: 18 * unit, height: unit)
        Circle().stroke(Color.accentColor, lineWidth: 2 * unit).frame(
          width: 10 * unit, height: 10 * unit)
      }
      .clipShape(RoundedRectangle(cornerRadius: 8 * unit))
      .overlay(RoundedRectangle(cornerRadius: 8 * unit).stroke(.white, lineWidth: 2 * unit))
      .overlay(
        RoundedRectangle(cornerRadius: 10 * unit)
          .stroke(Color.accentColor, lineWidth: 2 * unit)
          .padding(-3 * unit)
      )
      .shadow(color: .black.opacity(0.8), radius: 5 * unit)
    }
    .accessibilityHidden(true)
  }
}

struct RebateRegionSelectionOverlay: View {
  let isActive: Bool
  let imageSize: CGSize
  var magnification: CGFloat = 1
  @Binding var dragStart: CGPoint?
  @Binding var dragEnd: CGPoint?
  let onSelection: (Double, Double, Double, Double) -> Void

  var body: some View {
    GeometryReader { geometry in
      let imageRect = PreviewOverlayGeometry.aspectFitRect(
        imageSize: imageSize,
        containerSize: geometry.size
      )
      let stroke = PreviewOverlayGeometry.documentLength(
        PreviewOverlayGeometry.strokeScreenLength, magnification: magnification)
      let minSize = PreviewOverlayGeometry.documentLength(2, magnification: magnification)
      ZStack {
        Color.clear
          .contentShape(Rectangle())
        if isActive, let dragStart, let dragEnd {
          Rectangle()
            .fill(Color.accentColor.opacity(0.15))
            .stroke(Color.accentColor, lineWidth: stroke)
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
      .coordinateSpace(.named("rebateOverlay"))
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named("rebateOverlay"))
          .onChanged { value in
            let start = PreviewOverlayGeometry.documentGesturePoint(
              value.startLocation, magnification: magnification)
            guard dragStart != nil || imageRect.contains(start) else { return }
            let point = PreviewOverlayGeometry.clampedPoint(
              PreviewOverlayGeometry.documentGesturePoint(
                value.location, magnification: magnification),
              to: imageRect)
            if dragStart == nil {
              dragStart = PreviewOverlayGeometry.clampedPoint(start, to: imageRect)
            }
            dragEnd = point
          }
          .onEnded { value in
            guard let start = dragStart else { return }
            let end = PreviewOverlayGeometry.clampedPoint(
              PreviewOverlayGeometry.documentGesturePoint(
                value.location, magnification: magnification),
              to: imageRect)
            dragEnd = end
            let selection = CGRect(
              x: min(start.x, end.x),
              y: min(start.y, end.y),
              width: abs(end.x - start.x),
              height: abs(end.y - start.y)
            )
            guard selection.width >= minSize, selection.height >= minSize,
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
