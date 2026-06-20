import Foundation

/// Settings matching the legacy Python dust detector's class parameters.
public struct DustDetectionParameters: Codable, Equatable, Hashable, Sendable {
  public var thresholdPercent: Double
  public var maximumParticleArea: Double
  public var closingIterations: Int
  /// Horizontal and vertical percentages excluded from percentile sampling.
  public var ignoredBorderPercent: SIMD2<Double>

  public init(
    thresholdPercent: Double = 10,
    maximumParticleArea: Double = 15,
    closingIterations: Int = 5,
    ignoredBorderPercent: SIMD2<Double> = .zero
  ) {
    self.thresholdPercent = thresholdPercent
    self.maximumParticleArea = maximumParticleArea
    self.closingIterations = closingIterations
    self.ignoredBorderPercent = ignoredBorderPercent
  }
}

/// Deterministic dust-mask generation compatible with the legacy detector.
public enum DustDetection {
  public static func findMask(
    in image: UInt16Image,
    parameters: DustDetectionParameters = DustDetectionParameters()
  ) -> UInt16Image {
    precondition(image.channels == 3, "Dust detection requires a 3-channel BGR image")

    let width = image.width
    let height = image.height
    let pixelCount = width * height
    guard pixelCount > 0 else {
      return UInt16Image(width: width, height: height, channels: 1, pixels: [])
    }

    let multiplier = (Double(width + height) / 2) / 800
    let roundedMultiplier = multiplier.rounded(.toNearestOrEven)
    let kernelSize = max(Int(roundedMultiplier) * 2 + 1, 1)
    let maximumArea = multiplier * multiplier * parameters.maximumParticleArea

    var gray = [UInt8](repeating: 0, count: pixelCount)
    for pixelIndex in 0..<pixelCount {
      let base = pixelIndex * 3
      gray[pixelIndex] = bgrToGray(
        blue: image.pixels[base],
        green: image.pixels[base + 1],
        red: image.pixels[base + 2]
      )
    }

    let insetX = Int(
      parameters.ignoredBorderPercent.x / 100 * Double(width))
    let insetY = Int(
      parameters.ignoredBorderPercent.y / 100 * Double(height))
    var histogram = [Int](repeating: 0, count: 256)
    let sampleCount: Int
    if insetX <= 0 || insetY <= 0 || insetX * 2 >= width || insetY * 2 >= height {
      for value in gray { histogram[Int(value)] += 1 }
      sampleCount = gray.count
    } else {
      for y in insetY..<(height - insetY) {
        for x in insetX..<(width - insetX) {
          histogram[Int(gray[y * width + x])] += 1
        }
      }
      sampleCount = (width - insetX * 2) * (height - insetY * 2)
    }

    let minimum = percentile(histogram: histogram, count: sampleCount, fraction: 0.005)
    let maximum = percentile(histogram: histogram, count: sampleCount, fraction: 0.995)
    let threshold = (maximum - minimum) * parameters.thresholdPercent / 100 + minimum

    var binary = gray.map { Double($0) > threshold ? UInt8(0) : UInt8(255) }
    let iterations = max(parameters.closingIterations, 0)
    if kernelSize > 1, iterations > 0 {
      for _ in 0..<iterations {
        binary = squareMorphology(
          binary, width: width, height: height, kernelSize: kernelSize, dilating: true)
      }
      for _ in 0..<iterations {
        binary = squareMorphology(
          binary, width: width, height: height, kernelSize: kernelSize, dilating: false)
      }
    }

    var mask = retainSmallComponents(
      binary, width: width, height: height, maximumArea: maximumArea)
    if kernelSize > 1 {
      mask = squareMorphology(
        mask, width: width, height: height, kernelSize: kernelSize, dilating: true)
    }
    return UInt16Image(
      width: width,
      height: height,
      channels: 1,
      pixels: mask.map(UInt16.init)
    )
  }

  private static func bgrToGray(blue: UInt16, green: UInt16, red: UInt16) -> UInt8 {
    func scale8(_ value: UInt16) -> Int { (Int(value) + 128) / 257 }
    let value =
      (1868 * scale8(blue) + 9617 * scale8(green) + 4899 * scale8(red) + 8192) >> 14
    return UInt8(value)
  }

  private static func percentile(
    histogram: [Int],
    count: Int,
    fraction: Double
  ) -> Double {
    guard count > 0 else { return 0 }
    let position = Double(count - 1) * fraction
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    let weight = position - Double(lower)

    var cumulative = 0
    var lowerValue = 0
    var upperValue = 0
    var foundLower = false
    for value in histogram.indices {
      cumulative += histogram[value]
      if cumulative > lower, !foundLower {
        lowerValue = value
        foundLower = true
      }
      if cumulative > upper {
        upperValue = value
        break
      }
    }
    return Double(lowerValue) * (1 - weight) + Double(upperValue) * weight
  }

  /// Square binary morphology using an integral image, keeping each pass O(pixels).
  private static func squareMorphology(
    _ source: [UInt8],
    width: Int,
    height: Int,
    kernelSize: Int,
    dilating: Bool
  ) -> [UInt8] {
    let stride = width + 1
    var integral = [Int](repeating: 0, count: (height + 1) * stride)
    for y in 0..<height {
      var rowSum = 0
      for x in 0..<width {
        if source[y * width + x] != 0 { rowSum += 1 }
        integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + rowSum
      }
    }

    let radius = kernelSize / 2
    var output = [UInt8](repeating: 0, count: source.count)
    for y in 0..<height {
      let y0 = max(y - radius, 0)
      let y1 = min(y + radius + 1, height)
      for x in 0..<width {
        let x0 = max(x - radius, 0)
        let x1 = min(x + radius + 1, width)
        let foregroundCount = integral[y1 * stride + x1] - integral[y0 * stride + x1]
          - integral[y1 * stride + x0] + integral[y0 * stride + x0]
        let inBoundsCount = (x1 - x0) * (y1 - y0)
        let isForeground = dilating ? foregroundCount > 0 : foregroundCount == inBoundsCount
        output[y * width + x] = isForeground ? 255 : 0
      }
    }
    return output
  }

  private static func retainSmallComponents(
    _ binary: [UInt8],
    width: Int,
    height: Int,
    maximumArea: Double
  ) -> [UInt8] {
    var visited = [Bool](repeating: false, count: binary.count)
    var output = [UInt8](repeating: 0, count: binary.count)
    var queue = [Int]()
    var component = [Int]()

    for start in binary.indices where binary[start] != 0 && !visited[start] {
      queue.removeAll(keepingCapacity: true)
      component.removeAll(keepingCapacity: true)
      queue.append(start)
      visited[start] = true
      var cursor = 0

      while cursor < queue.count {
        let index = queue[cursor]
        cursor += 1
        component.append(index)
        let x = index % width
        let y = index / width
        for dy in -1...1 {
          for dx in -1...1 where dx != 0 || dy != 0 {
            let nx = x + dx
            let ny = y + dy
            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
            let neighbor = ny * width + nx
            if binary[neighbor] != 0, !visited[neighbor] {
              visited[neighbor] = true
              queue.append(neighbor)
            }
          }
        }
      }

      if contourArea(of: component, in: binary, width: width, height: height) < maximumArea {
        for index in component { output[index] = 255 }
      }
    }
    return output
  }

  /// Trace the outer 8-connected boundary through foreground pixel centers,
  /// then apply the same shoelace area definition used by OpenCV contours.
  private static func contourArea(
    of component: [Int],
    in binary: [UInt8],
    width: Int,
    height: Int
  ) -> Double {
    guard component.count >= 3 else { return 0 }
    let start = component.min {
      let lhsY = $0 / width
      let rhsY = $1 / width
      return lhsY == rhsY ? $0 % width < $1 % width : lhsY < rhsY
    }!
    let directions = [
      SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1), SIMD2(-1, 1),
      SIMD2(-1, 0), SIMD2(-1, -1), SIMD2(0, -1), SIMD2(1, -1),
    ]
    func isForeground(_ point: SIMD2<Int>) -> Bool {
      point.x >= 0 && point.x < width && point.y >= 0 && point.y < height
        && binary[point.y * width + point.x] != 0
    }
    func directionIndex(from center: SIMD2<Int>, to point: SIMD2<Int>) -> Int {
      let delta = SIMD2(point.x - center.x, point.y - center.y)
      return directions.firstIndex(of: delta) ?? 4
    }
    func offset(_ point: SIMD2<Int>, by delta: SIMD2<Int>) -> SIMD2<Int> {
      SIMD2(point.x + delta.x, point.y + delta.y)
    }

    let startPoint = SIMD2(start % width, start / width)
    var current = startPoint
    var backtrack = offset(startPoint, by: SIMD2(-1, 0))
    var contour = [SIMD2<Int>]()
    contour.reserveCapacity(component.count)
    let maximumSteps = max(component.count * 4, 8)

    for _ in 0..<maximumSteps {
      contour.append(current)
      let backtrackDirection = directionIndex(from: current, to: backtrack)
      var foundPoint: SIMD2<Int>?
      var foundDirection = backtrackDirection
      for step in 1...8 {
        let candidateDirection = (backtrackDirection + step) % 8
        let candidate = offset(current, by: directions[candidateDirection])
        if isForeground(candidate) {
          foundPoint = candidate
          foundDirection = candidateDirection
          break
        }
      }
      guard let next = foundPoint else { break }
      backtrack = offset(current, by: directions[(foundDirection + 7) % 8])
      if next == startPoint, contour.count > 1 { break }
      current = next
    }

    guard contour.count >= 3 else { return 0 }
    var twiceArea = 0
    for index in contour.indices {
      let currentPoint = contour[index]
      let nextPoint = contour[(index + 1) % contour.count]
      twiceArea += currentPoint.x * nextPoint.y - nextPoint.x * currentPoint.y
    }
    return Double(abs(twiceArea)) / 2
  }
}
