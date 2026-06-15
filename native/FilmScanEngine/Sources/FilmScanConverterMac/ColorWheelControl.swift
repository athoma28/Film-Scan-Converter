import SwiftUI

struct ColorWheelControl: View {
  let title: String
  let hue: Double
  let strength: Double
  let setHue: (Double) -> Void
  let setStrength: (Double) -> Void

  var body: some View {
    VStack(spacing: 5) {
      Text(title)
        .font(.caption)
        .fontWeight(.medium)

      GeometryReader { geometry in
        let size = min(geometry.size.width, geometry.size.height)
        let radius = size / 2
        let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)

        ZStack {
          Circle()
            .fill(
              AngularGradient(
                colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                center: .center
              )
            )
          Circle()
            .fill(
              RadialGradient(
                colors: [.white, .white.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: radius
              )
            )
          Circle()
            .stroke(.white.opacity(0.45), lineWidth: 1)
          Circle()
            .stroke(.black.opacity(0.35), lineWidth: 2)
          Circle()
            .fill(.white)
            .stroke(.black.opacity(0.8), lineWidth: 1.5)
            .shadow(radius: 1)
            .frame(width: 11, height: 11)
            .position(markerPosition(center: center, radius: radius - 7))
        }
        .frame(width: size, height: size)
        .position(x: center.x, y: center.y)
        .contentShape(Circle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { update(from: $0.location, center: center, radius: radius) }
        )
        .onTapGesture(count: 2) {
          setStrength(0)
        }
      }
      .aspectRatio(1, contentMode: .fit)

      Text("\(Int(hue.rounded()))°  \(Int((strength * 100).rounded()))%")
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title) color wheel")
    .accessibilityValue("\(Int(hue.rounded())) degrees, \(Int((strength * 100).rounded())) percent")
  }

  private func markerPosition(center: CGPoint, radius: CGFloat) -> CGPoint {
    let radians = hue * .pi / 180
    let distance = radius * strength
    return CGPoint(
      x: center.x + cos(radians) * distance,
      y: center.y - sin(radians) * distance
    )
  }

  private func update(from point: CGPoint, center: CGPoint, radius: CGFloat) {
    let dx = point.x - center.x
    let dy = center.y - point.y
    let distance = min(hypot(dx, dy), radius)
    var degrees = atan2(dy, dx) * 180 / .pi
    if degrees < 0 {
      degrees += 360
    }
    setHue(degrees)
    setStrength(Double(distance / radius))
  }
}
