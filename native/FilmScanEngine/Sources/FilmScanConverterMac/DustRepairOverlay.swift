import AppKit
import FilmScanEngine
import SwiftUI

enum DustBrushMode: String, CaseIterable, Identifiable {
  case heal = "Heal"
  case mark = "Mark"
  case erase = "Erase"
  var id: Self { self }
}

/// The dust editor displays the unframed source, so these coordinates survive
/// perspective, crop, orientation and preview-resolution changes.
struct DustRepairOverlay: View {
  let imageSize: CGSize
  let magnification: CGFloat
  let radius: Double
  let mode: DustBrushMode
  @Binding var sourcePoint: SIMD2<Double>?
  let onStroke: ([SIMD2<Double>], Double, SIMD2<Double>?) -> Void
  let onLimitExceeded: () -> Void

  @State private var points: [SIMD2<Double>] = []
  @State private var hoverPoint: CGPoint?
  @State private var isChoosingSource = false
  @State private var isDragging = false
  @State private var pointLimitReached = false

  var body: some View {
    GeometryReader { geometry in
      let rect = PreviewOverlayGeometry.aspectFitRect(
        imageSize: imageSize, containerSize: geometry.size)
      let brushRadius = radius * rect.width
      let outline = PreviewOverlayGeometry.documentLength(1.5, magnification: magnification)
      ZStack {
        Color.clear
        if let hoverPoint {
          Circle()
            .stroke(.yellow, lineWidth: outline)
            .frame(width: brushRadius * 2, height: brushRadius * 2)
            .position(hoverPoint)
            .allowsHitTesting(false)
        }
        if mode == .heal, let sourcePoint {
          let point = displayPoint(sourcePoint, in: rect)
          Circle()
            .stroke(.cyan, lineWidth: outline)
            .frame(width: brushRadius * 2, height: brushRadius * 2)
            .position(point)
            .allowsHitTesting(false)
        }
        if let first = points.first {
          Path { path in
            path.move(to: displayPoint(first, in: rect))
            for point in points.dropFirst() { path.addLine(to: displayPoint(point, in: rect)) }
          }
          .stroke(
            mode == .erase ? Color.red.opacity(0.65) : Color.yellow.opacity(0.55),
            style: StrokeStyle(lineWidth: brushRadius * 2, lineCap: .round, lineJoin: .round)
          )
          .allowsHitTesting(false)
          Circle()
            .fill(.yellow.opacity(0.5))
            .frame(width: brushRadius * 2, height: brushRadius * 2)
            .position(displayPoint(first, in: rect))
            .allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
      .onContinuousHover(coordinateSpace: .local) { phase in
        switch phase {
        case .active(let location):
          hoverPoint = PreviewOverlayGeometry.clampedPoint(
            PreviewOverlayGeometry.documentGesturePoint(location, magnification: magnification),
            to: rect)
        case .ended: hoverPoint = nil
        }
      }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let start = PreviewOverlayGeometry.documentGesturePoint(
              value.startLocation, magnification: magnification)
            guard rect.contains(start) else { return }
            let point = normalizedPoint(value.location, in: rect)
            if !isDragging {
              isDragging = true
              isChoosingSource = mode == .heal && NSEvent.modifierFlags.contains(.option)
            }
            if isChoosingSource {
              sourcePoint = point
              return
            }
            if let previous = points.last {
              let dx = (point.x - previous.x) * rect.width
              let dy = (point.y - previous.y) * rect.height
              guard hypot(dx, dy) >= max(0.5, brushRadius * 0.25) else { return }
              guard points.count < DustRepair.maximumPointsPerStroke - 1 else {
                pointLimitReached = true
                return
              }
            }
            points.append(point)
          }
          .onEnded { value in
            defer {
              points = []
              isChoosingSource = false
              isDragging = false
              pointLimitReached = false
            }
            if pointLimitReached {
              onLimitExceeded()
              return
            }
            guard !isChoosingSource, !points.isEmpty else { return }
            let endpoint = normalizedPoint(value.location, in: rect)
            if endpoint != points.last { points.append(endpoint) }
            onStroke(points, radius, mode == .heal ? sourcePoint : nil)
          }
      )
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(mode == .heal ? "Healing brush" : "Dust mask brush")
    .accessibilityHint("Drag to paint. Option-click in Heal mode chooses the texture source.")
  }

  private func displayPoint(_ point: SIMD2<Double>, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
  }

  private func normalizedPoint(_ point: CGPoint, in rect: CGRect) -> SIMD2<Double> {
    let location = PreviewOverlayGeometry.clampedPoint(
      PreviewOverlayGeometry.documentGesturePoint(point, magnification: magnification), to: rect)
    let normalized = PreviewOverlayGeometry.normalizedPoint(location, in: rect)
    return SIMD2(normalized.x, normalized.y)
  }
}
