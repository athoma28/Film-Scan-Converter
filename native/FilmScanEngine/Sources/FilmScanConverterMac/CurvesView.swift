import FilmScanEngine
import SwiftUI

enum CurveChannel: String, CaseIterable, Identifiable {
  case rgb = "RGB"
  case red = "R"
  case green = "G"
  case blue = "B"

  var id: String { rawValue }

  var color: Color {
    switch self {
    case .rgb: .white
    case .red: .red
    case .green: .green
    case .blue: .blue
    }
  }
}

struct IntegratedCurvesView: View {
  @ObservedObject var model: AppModel
  @State private var selectedChannel: CurveChannel = .rgb
  @State private var selectedPointIndex: Int? = nil
  @State private var isDraggingPoint = false

  private let pointRadius: CGFloat = 5
  private let selectedPointRadius: CGFloat = 7

  var body: some View {
    VStack(spacing: 8) {
      channelPicker

      GeometryReader { geometry in
        let graphSize = min(geometry.size.width, geometry.size.height)
        let inset: CGFloat = selectedPointRadius + 2
        let drawRect = CGRect(
          x: (geometry.size.width - graphSize) / 2 + inset,
          y: (geometry.size.height - graphSize) / 2 + inset,
          width: graphSize - inset * 2,
          height: graphSize - inset * 2
        )
        let fullRect = CGRect(
          x: (geometry.size.width - graphSize) / 2,
          y: (geometry.size.height - graphSize) / 2,
          width: graphSize,
          height: graphSize
        )

        ZStack {
          Rectangle()
            .fill(Color(white: 0.20))
            .frame(width: graphSize, height: graphSize)
            .position(x: fullRect.midX, y: fullRect.midY)

          gridLines(drawRect: drawRect)
          diagonal(drawRect: drawRect)
          curvePath(drawRect: drawRect)
          controlPoints(drawRect: drawRect)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onEnded { value in
              if !isDraggingPoint {
                handleGraphTapOrDrag(location: value.startLocation, drawRect: drawRect)
              }
              isDraggingPoint = false
            }
        )
      }
      .aspectRatio(1, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 5))
      .overlay(
        RoundedRectangle(cornerRadius: 5)
          .stroke(.white.opacity(0.1), lineWidth: 1)
      )

      HStack(spacing: 6) {
        pointInfoRow

        Spacer()

        Menu {
          ForEach(CurveChannel.allCases) { ch in
            Button {
              resetChannel(ch)
            } label: {
              Text("Reset \(ch.rawValue)")
            }
          }
          Button(role: .destructive) {
            resetChannel(.rgb)
            resetChannel(.red)
            resetChannel(.green)
            resetChannel(.blue)
            selectedChannel = .rgb
            selectedPointIndex = nil
          } label: {
            Text("Reset All Channels")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 24)
      }

      presetButtonsRow
    }
  }

  private var channelPicker: some View {
    HStack(spacing: 0) {
      ForEach(CurveChannel.allCases) { channel in
        Button {
          selectedChannel = channel
          selectedPointIndex = nil
        } label: {
          Text(channel.rawValue)
            .font(.caption)
            .fontWeight(selectedChannel == channel ? .semibold : .regular)
            .foregroundStyle(selectedChannel == channel ? .white : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
              selectedChannel == channel
                ? channel.color.opacity(channel == .rgb ? 0.25 : 0.45)
                : Color.clear
            )
        }
        .buttonStyle(.plain)
      }
    }
    .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.13)))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(.white.opacity(0.06), lineWidth: 1)
    )
  }

  private func gridLines(drawRect: CGRect) -> some View {
    Canvas { context, _ in
      for i in 1..<4 {
        let frac = CGFloat(i) / 4.0
        let x = drawRect.minX + drawRect.width * frac
        let y = drawRect.minY + drawRect.height * frac

        var h = Path(); h.move(to: CGPoint(x: x, y: drawRect.minY)); h.addLine(to: CGPoint(x: x, y: drawRect.maxY))
        context.stroke(h, with: .color(.white.opacity(0.06)), lineWidth: 0.5)

        var v = Path(); v.move(to: CGPoint(x: drawRect.minX, y: y)); v.addLine(to: CGPoint(x: drawRect.maxX, y: y))
        context.stroke(v, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
      }
    }
  }

  private func diagonal(drawRect: CGRect) -> some View {
    Path { path in
      path.move(to: CGPoint(x: drawRect.minX, y: drawRect.maxY))
      path.addLine(to: CGPoint(x: drawRect.maxX, y: drawRect.minY))
    }
    .stroke(.white.opacity(0.12), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
  }

  private func curvePath(drawRect: CGRect) -> some View {
    let sorted = currentControlPoints.sorted { $0.input < $1.input }

    return Path { path in
      guard sorted.count >= 2 else { return }
      let toView = makeViewTransform(drawRect: drawRect)
      let sampleCount = max(64, Int(drawRect.width.rounded()))
      let samples = FilmProcessing.curveSamples(
        controlPoints: sorted,
        sampleCount: sampleCount
      ) ?? sorted
      for (index, sample) in samples.enumerated() {
        let point = toView(CGPoint(
          x: sample.input,
          y: min(max(sample.output, 0), 1)
        ))
        if index == 0 {
          path.move(to: point)
        } else {
          path.addLine(to: point)
        }
      }
    }
    .stroke(selectedChannel.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
  }

  private func controlPoints(drawRect: CGRect) -> some View {
    let points = currentControlPoints
    let sorted = points.enumerated().sorted { $0.element.input < $1.element.input }
    let toView = makeViewTransform(drawRect: drawRect)

    return ForEach(Array(sorted), id: \.offset) { originalIndex, point in
      let viewPt = toView(CGPoint(x: point.input, y: point.output))
      let isEndpoint = abs(point.input) < 0.001 || abs(point.input - 1.0) < 0.001
      let isSelected = selectedPointIndex == originalIndex
      let size: CGFloat = isSelected ? selectedPointRadius * 2 : pointRadius * 2

      ZStack {
        if isSelected {
          Circle()
            .fill(selectedChannel.color.opacity(0.3))
            .frame(width: size + 6, height: size + 6)
        }
        Circle()
          .fill(Color.white)
        Circle()
          .stroke(selectedChannel.color, lineWidth: isSelected ? 2 : 1.5)
          .fill(isEndpoint ? Color.white : Color(white: 0.25))
      }
      .frame(width: size, height: size)
      .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 0.5)
      .position(viewPt)
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            isDraggingPoint = true
            selectedPointIndex = originalIndex
            handlePointDrag(value: value, pointIndex: originalIndex, drawRect: drawRect)
          }
      )
      .onTapGesture(count: 2) { deletePoint(at: originalIndex) }
      .onTapGesture(count: 1) { selectedPointIndex = originalIndex }
    }
  }

  private var pointInfoRow: some View {
    let points = currentControlPoints
    if let idx = selectedPointIndex, idx < points.count {
      let pt = points[idx]
      return AnyView(
        HStack(spacing: 6) {
          labeledField(
            "In",
            value: Binding(
              get: { Int((pt.input * 255).rounded()) },
              set: { updatePointInput(at: idx, value: Double($0) / 255.0) }
            )
          )
          labeledField(
            "Out",
            value: Binding(
              get: { Int((pt.output * 255).rounded()) },
              set: { updatePointOutput(at: idx, value: Double($0) / 255.0) }
            )
          )
        }
      )
    } else {
      return AnyView(
        Text("Click point to edit values")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      )
    }
  }

  private func labeledField(_ label: String, value: Binding<Int>) -> some View {
    HStack(spacing: 2) {
      Text(label)
        .font(.system(size: 8))
        .foregroundStyle(.tertiary)
        .frame(width: 16, alignment: .leading)
      TextField("", value: value, format: .number)
        .textFieldStyle(.plain)
        .font(.caption)
        .monospacedDigit()
        .frame(width: 32)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.12)))
    }
  }

  private var presetButtonsRow: some View {
    HStack(spacing: 6) {
      compactPresetButton("Linear", systemImage: "line.diagonal") { applyPresetToCurrent(.linear) }
      compactPresetButton("S-Curve", systemImage: "function") { applyPresetToCurrent(.mediumContrast) }
      compactPresetButton("Strong S", systemImage: "chart.line.uptrend.xyaxis") { applyPresetToCurrent(.strongContrast) }
    }
  }

  private func compactPresetButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: systemImage).font(.system(size: 9))
        Text(title).font(.caption2)
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private enum CurvePreset { case linear, mediumContrast, strongContrast }

  private func applyPresetToCurrent(_ preset: CurvePreset) {
    let pts: [CurvePoint]
    switch preset {
    case .linear:
      pts = [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)]
    case .mediumContrast:
      pts = [
        CurvePoint(input: 0, output: 0),
        CurvePoint(input: 0.25, output: 0.17),
        CurvePoint(input: 0.5, output: 0.5),
        CurvePoint(input: 0.75, output: 0.83),
        CurvePoint(input: 1, output: 1),
      ]
    case .strongContrast:
      pts = [
        CurvePoint(input: 0, output: 0),
        CurvePoint(input: 0.30, output: 0.10),
        CurvePoint(input: 0.5, output: 0.5),
        CurvePoint(input: 0.70, output: 0.90),
        CurvePoint(input: 1, output: 1),
      ]
    }
    setControlPoints(pts)
    selectedPointIndex = nil
  }

  private func resetChannel(_ channel: CurveChannel) {
    let pts = [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)]
    switch channel {
    case .rgb: model.setCurveControlPoints(pts)
    case .red: model.setRedCurveControlPoints(pts)
    case .green: model.setGreenCurveControlPoints(pts)
    case .blue: model.setBlueCurveControlPoints(pts)
    }
    if selectedChannel == channel { selectedPointIndex = nil }
  }

  private var currentControlPoints: [CurvePoint] {
    let pts: [CurvePoint]
    switch selectedChannel {
    case .rgb: pts = model.parameters.curveControlPoints
    case .red: pts = model.parameters.redCurveControlPoints
    case .green: pts = model.parameters.greenCurveControlPoints
    case .blue: pts = model.parameters.blueCurveControlPoints
    }
    let resolved = pts.isEmpty
      ? [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)]
      : pts
    return resolved.sorted { $0.input < $1.input }
  }

  private func setControlPoints(_ points: [CurvePoint]) {
    let normalized = points.map {
      CurvePoint(
        input: min(max($0.input, 0), 1),
        output: min(max($0.output, 0), 1)
      )
    }.sorted { $0.input < $1.input }
    switch selectedChannel {
    case .rgb: model.setCurveControlPoints(normalized)
    case .red: model.setRedCurveControlPoints(normalized)
    case .green: model.setGreenCurveControlPoints(normalized)
    case .blue: model.setBlueCurveControlPoints(normalized)
    }
  }

  private func makeViewTransform(drawRect: CGRect) -> (CGPoint) -> CGPoint {
    { pt in CGPoint(x: drawRect.minX + pt.x * drawRect.width, y: drawRect.maxY - pt.y * drawRect.height) }
  }

  private func makeInverseTransform(drawRect: CGRect) -> (CGPoint) -> CGPoint {
    { pt in
      CGPoint(
        x: min(max((pt.x - drawRect.minX) / drawRect.width, 0), 1),
        y: min(max((drawRect.maxY - pt.y) / drawRect.height, 0), 1)
      )
    }
  }

  private func handleGraphTapOrDrag(location: CGPoint, drawRect: CGRect) {
    let inv = makeInverseTransform(drawRect: drawRect)
    let norm = inv(location)
    let points = currentControlPoints
    let toView = makeViewTransform(drawRect: drawRect)

    let nearExisting = points.enumerated().contains { idx, pt in
      let vpt = toView(CGPoint(x: pt.input, y: pt.output))
      let r = (selectedPointIndex == idx ? selectedPointRadius : pointRadius) + 4
      return hypot(vpt.x - location.x, vpt.y - location.y) < r
    }
    guard !nearExisting else { return }

    var newPoints = points
    let newPoint = CurvePoint(input: norm.x, output: norm.y)
    newPoints.append(newPoint)
    newPoints.sort { $0.input < $1.input }
    setControlPoints(newPoints)
    selectedPointIndex = newPoints.firstIndex(of: newPoint)
  }

  private func handlePointDrag(value: DragGesture.Value, pointIndex: Int, drawRect: CGRect) {
    let inv = makeInverseTransform(drawRect: drawRect)
    let norm = inv(value.location)
    var points = currentControlPoints
    guard pointIndex < points.count else { return }

    if pointIndex == 0 {
      points[pointIndex] = CurvePoint(input: 0, output: min(max(norm.y, 0), 1))
    } else if pointIndex == points.count - 1 {
      points[pointIndex] = CurvePoint(input: 1, output: min(max(norm.y, 0), 1))
    } else {
      let spacing = 1.0 / 255.0
      let lower = points[pointIndex - 1].input + spacing
      let upper = points[pointIndex + 1].input - spacing
      points[pointIndex] = CurvePoint(
        input: min(max(norm.x, lower), upper),
        output: min(max(norm.y, 0), 1)
      )
    }
    setControlPoints(points)
  }

  private func deletePoint(at index: Int) {
    var points = currentControlPoints
    guard points.count > 2, index < points.count else { return }
    let pt = points[index]
    if abs(pt.input) < 0.001 || abs(pt.input - 1.0) < 0.001 { return }
    points.remove(at: index)
    setControlPoints(points)
    if selectedPointIndex == index { selectedPointIndex = nil }
  }

  private func updatePointInput(at index: Int, value: Double) {
    var points = currentControlPoints
    guard index < points.count else { return }
    guard index > 0, index < points.count - 1 else { return }
    let spacing = 1.0 / 255.0
    let lower = points[index - 1].input + spacing
    let upper = points[index + 1].input - spacing
    points[index] = CurvePoint(
      input: min(max(value, lower), upper),
      output: points[index].output
    )
    setControlPoints(points)
  }

  private func updatePointOutput(at index: Int, value: Double) {
    var points = currentControlPoints
    guard index < points.count else { return }
    points[index] = CurvePoint(
      input: points[index].input,
      output: min(max(value, 0), 1)
    )
    setControlPoints(points)
  }
}
