import Accelerate
import Foundation

/// A source-space quadrilateral for an interactive perspective crop.
///
/// Coordinates are normalized with `(0, 0)` at the source image's top-left
/// and `(1, 1)` at its bottom-right.  The corner order is fixed so settings
/// can be safely persisted and the editor never has to infer a winding order.
public struct PerspectiveCrop: Codable, Equatable, Sendable {
  public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
      self.x = x
      self.y = y
    }
  }

  public var topLeft: Point
  public var topRight: Point
  public var bottomRight: Point
  public var bottomLeft: Point

  public init(topLeft: Point, topRight: Point, bottomRight: Point, bottomLeft: Point) {
    self.topLeft = topLeft
    self.topRight = topRight
    self.bottomRight = bottomRight
    self.bottomLeft = bottomLeft
  }

  public static let fullFrame = PerspectiveCrop(
    topLeft: Point(x: 0, y: 0),
    topRight: Point(x: 1, y: 0),
    bottomRight: Point(x: 1, y: 1),
    bottomLeft: Point(x: 0, y: 1)
  )

  public var points: [Point] { [topLeft, topRight, bottomRight, bottomLeft] }

  public var isValid: Bool {
    guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }) else {
      return false
    }
    let ring = points + [topLeft]
    let signedArea = zip(ring, ring.dropFirst()).reduce(0.0) { area, pair in
      area + pair.0.x * pair.1.y - pair.1.x * pair.0.y
    } / 2
    guard signedArea > 0.000_1 else { return false }
    return (0..<4).allSatisfy { index in
      let a = points[index]
      let b = points[(index + 1) % 4]
      let c = points[(index + 2) % 4]
      let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
      return cross > 0.000_1
    }
  }

  public func replacing(_ corner: Int, with point: Point) -> PerspectiveCrop {
    let clamped = Point(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    var result = self
    switch corner {
    case 0: result.topLeft = clamped
    case 1: result.topRight = clamped
    case 2: result.bottomRight = clamped
    case 3: result.bottomLeft = clamped
    default: preconditionFailure("Perspective crop corner must be in 0...3")
    }
    return result
  }
}

public enum PerspectiveTransform {

  /// Applies a simple axis-aligned crop in the current canvas coordinate
  /// system. Unlike film-frame and perspective crops, this is intended to run
  /// after orientation and straightening.
  public static func crop(
    _ image: UInt16Image,
    canvasRect: NormalizedCropRect
  ) -> UInt16Image? {
    guard let bounds = ImageGeometry.pixelBounds(
      for: canvasRect, imageWidth: image.width, imageHeight: image.height)
    else { return nil }
    var pixels = [UInt16]()
    pixels.reserveCapacity(bounds.width * bounds.height * image.channels)
    let componentsPerRow = bounds.width * image.channels
    for y in bounds.y..<(bounds.y + bounds.height) {
      let start = (y * image.width + bounds.x) * image.channels
      pixels.append(contentsOf: image.pixels[start..<(start + componentsPerRow)])
    }
    return UInt16Image(
      width: bounds.width,
      height: bounds.height,
      channels: image.channels,
      pixels: pixels)
  }

  /// Rotates the image clockwise in display coordinates and expands the canvas
  /// just enough to retain every source corner. This is the CPU authority for
  /// the simple straighten-line tool.
  public static func rotate(
    _ image: UInt16Image,
    clockwiseDegrees: Double
  ) -> UInt16Image {
    guard clockwiseDegrees.isFinite else { return image }
    let normalized = clockwiseDegrees.truncatingRemainder(dividingBy: 360)
    guard abs(normalized) > 0.000_001 else { return image }
    let quarterTurns = (normalized / 90).rounded()
    if abs(normalized - quarterTurns * 90) < 0.000_001 {
      return image.rotated(quarterTurns: Int(quarterTurns))
    }

    let dimensions = ImageGeometry.rotatedCanvasDimensions(
      PixelDimensions(width: image.width, height: image.height),
      clockwiseDegrees: normalized)
    let radians = normalized * .pi / 180
    let cosAngle = cos(radians)
    let sinAngle = sin(radians)
    let centerX = Double(image.width - 1) / 2
    let centerY = Double(image.height - 1) / 2
    func rotatedPoint(x: Double, y: Double) -> (x: Double, y: Double) {
      let dx = x - centerX
      let dy = y - centerY
      return (
        x: cosAngle * dx - sinAngle * dy,
        y: sinAngle * dx + cosAngle * dy
      )
    }

    let corners = [
      rotatedPoint(x: 0, y: 0),
      rotatedPoint(x: Double(image.width - 1), y: 0),
      rotatedPoint(x: Double(image.width - 1), y: Double(image.height - 1)),
      rotatedPoint(x: 0, y: Double(image.height - 1)),
    ]
    let minX = corners.map(\.x).min() ?? 0
    let minY = corners.map(\.y).min() ?? 0
    let outputWidth = dimensions.width
    let outputHeight = dimensions.height
    let homography: [Float] = [
      Float(cosAngle), Float(-sinAngle), Float(centerX - minX - cosAngle * centerX + sinAngle * centerY),
      Float(sinAngle), Float(cosAngle), Float(centerY - minY - sinAngle * centerX - cosAngle * centerY),
      0, 0, 1,
    ]
    return warpPerspective(
      image, homography: homography, outputWidth: outputWidth, outputHeight: outputHeight)
  }

  /// Straightens a selected source quadrilateral into a rectangular canvas.
  /// The result dimensions follow the mean opposing edge lengths, preserving
  /// the source detail density instead of stretching to an arbitrary size.
  public static func crop(
    _ image: UInt16Image,
    perspectiveCrop: PerspectiveCrop,
    borderPercent: Double = 0
  ) -> UInt16Image? {
    guard perspectiveCrop.isValid else { return nil }
    let insetScale = max(0, 1 - max(0, borderPercent) / 100)
    let center = PerspectiveCrop.Point(
      x: perspectiveCrop.points.map(\.x).reduce(0, +) / 4,
      y: perspectiveCrop.points.map(\.y).reduce(0, +) / 4
    )
    let points = perspectiveCrop.points.map {
      PerspectiveCrop.Point(
        x: center.x + ($0.x - center.x) * insetScale,
        y: center.y + ($0.y - center.y) * insetScale
      )
    }
    let source = points.map {
      (x: Float($0.x * Double(image.width - 1)), y: Float($0.y * Double(image.height - 1)))
    }
    func distance(_ a: (x: Float, y: Float), _ b: (x: Float, y: Float)) -> Double {
      hypot(Double(a.x - b.x), Double(a.y - b.y))
    }
    let outputWidth = max(1, Int(((distance(source[0], source[1]) + distance(source[3], source[2])) / 2).rounded()) + 1)
    let outputHeight = max(1, Int(((distance(source[0], source[3]) + distance(source[1], source[2])) / 2).rounded()) + 1)
    let destination: [(x: Float, y: Float)] = [
      (0, 0),
      (Float(outputWidth - 1), 0),
      (Float(outputWidth - 1), Float(outputHeight - 1)),
      (0, Float(outputHeight - 1)),
    ]
    guard let homography = computeHomography(srcPoints: source, dstPoints: destination) else {
      return nil
    }
    return warpPerspective(
      image, homography: homography, outputWidth: outputWidth, outputHeight: outputHeight)
  }

  public static func crop(
    _ image: UInt16Image,
    normalizedRect: RotatedRect,
    coordinateSpace: NormalizedCropCoordinateSpace = .imageAxes,
    borderPercent: Double = 0
  ) -> UInt16Image? {
    let rect = ContourDetection.denormalize(
      normalizedRect,
      imageWidth: image.width,
      imageHeight: image.height,
      coordinateSpace: coordinateSpace
    )
    guard rect.width > 1, rect.height > 1 else { return nil }

    let xCrop: Double
    let yCrop: Double
    if image.height > image.width {
      xCrop = borderPercent
      yCrop = borderPercent * Double(image.width) / Double(image.height)
    } else {
      yCrop = borderPercent
      xCrop = borderPercent * Double(image.height) / Double(image.width)
    }

    let box = CoordinateMath.shrinkBox(
      box: rect.boxPoints.map { (Double($0.x), Double($0.y)) },
      xPercent: xCrop,
      yPercent: yCrop
    )
    let destinationHeight = max(1, Int(rect.height * (1 - xCrop / 100)))
    let destinationWidth = max(1, Int(rect.width * (1 - yCrop / 100)))
    let source = box.map { (x: Float($0.x), y: Float($0.y)) }
    let destination: [(x: Float, y: Float)] = [
      (0, Float(destinationHeight - 1)),
      (0, 0),
      (Float(destinationWidth - 1), 0),
      (Float(destinationWidth - 1), Float(destinationHeight - 1)),
    ]
    guard let homography = computeHomography(srcPoints: source, dstPoints: destination) else {
      return nil
    }
    var result = warpPerspective(
      image,
      homography: homography,
      outputWidth: destinationWidth,
      outputHeight: destinationHeight
    )
    if rect.angle > 45 {
      result = result.rotated(quarterTurns: 1)
    }
    return result
  }

  public static func computeHomography(
    srcPoints: [(x: Float, y: Float)],
    dstPoints: [(x: Float, y: Float)]
  ) -> [Float]? {
    precondition(srcPoints.count == 4 && dstPoints.count == 4,
                 "Homography requires exactly 4 point correspondences")

    let n = 4
    let dim = 2 * n

    var a = [Double](repeating: 0, count: dim * dim)
    var b = [Double](repeating: 0, count: dim)

    for i in 0..<n {
      let x = Double(srcPoints[i].x)
      let y = Double(srcPoints[i].y)
      let xp = Double(dstPoints[i].x)
      let yp = Double(dstPoints[i].y)

      let r0 = 2 * i
      let r1 = 2 * i + 1

      a[0 * dim + r0] = x
      a[1 * dim + r0] = y
      a[2 * dim + r0] = 1
      a[3 * dim + r0] = 0
      a[4 * dim + r0] = 0
      a[5 * dim + r0] = 0
      a[6 * dim + r0] = -x * xp
      a[7 * dim + r0] = -y * xp

      a[0 * dim + r1] = 0
      a[1 * dim + r1] = 0
      a[2 * dim + r1] = 0
      a[3 * dim + r1] = x
      a[4 * dim + r1] = y
      a[5 * dim + r1] = 1
      a[6 * dim + r1] = -x * yp
      a[7 * dim + r1] = -y * yp

      b[r0] = xp
      b[r1] = yp
    }

    var n_ = Int32(dim)
    var nrhs = Int32(1)
    var lda = n_
    var ldb = n_
    var ipiv = [Int32](repeating: 0, count: dim)
    var info: Int32 = 0

    dgesv_(&n_, &nrhs, &a, &lda, &ipiv, &b, &ldb, &info)
    guard info == 0 else { return nil }

    return [
      Float(b[0]), Float(b[1]), Float(b[2]),
      Float(b[3]), Float(b[4]), Float(b[5]),
      Float(b[6]), Float(b[7]), 1.0,
    ]
  }

  public static func warpPerspective(
    _ image: UInt16Image,
    homography: [Float],
    outputWidth: Int,
    outputHeight: Int
  ) -> UInt16Image {
    precondition(homography.count == 9, "Homography must be a 3×3 matrix")
    precondition(outputWidth > 0 && outputHeight > 0,
                 "Output dimensions must be positive")

    guard let invH = invertHomographyDouble(homography) else {
      return UInt16Image(
        width: outputWidth,
        height: outputHeight,
        channels: image.channels,
        pixels: [UInt16](
          repeating: 0,
          count: outputWidth * outputHeight * image.channels
        )
      )
    }

    let h00 = invH[0]
    let h01 = invH[1]
    let h02 = invH[2]
    let h10 = invH[3]
    let h11 = invH[4]
    let h12 = invH[5]
    let h20 = invH[6]
    let h21 = invH[7]
    let h22 = invH[8]

    let channels = image.channels
    let srcWidth = image.width
    let srcHeight = image.height

    var output = [UInt16](repeating: 0, count: outputWidth * outputHeight * channels)

    for outY in 0..<outputHeight {
      for outX in 0..<outputWidth {
        let fx = Double(outX)
        let fy = Double(outY)

        let dx = h00 * fx + h01 * fy + h02
        let dy = h10 * fx + h11 * fy + h12
        let dz = h20 * fx + h21 * fy + h22

        guard dx.isFinite, dy.isFinite, dz.isFinite, abs(dz) > 1e-10 else { continue }

        let srcX = dx / dz
        let srcY = dy / dz
        guard srcX.isFinite, srcY.isFinite else { continue }

        let x0f = floor(srcX)
        let y0f = floor(srcY)
        let wx = srcX - x0f
        let wy = srcY - y0f
        let iwx = 1.0 - wx
        let iwy = 1.0 - wy

        let x0 = Int(x0f)
        let y0 = Int(y0f)
        let x1 = x0 + 1
        let y1 = y0 + 1

        let x0In = x0 >= 0 && x0 < srcWidth
        let x1In = x1 >= 0 && x1 < srcWidth
        let y0In = y0 >= 0 && y0 < srcHeight
        let y1In = y1 >= 0 && y1 < srcHeight

        let cx0 = min(max(x0, 0), srcWidth - 1)
        let cx1 = min(max(x1, 0), srcWidth - 1)
        let cy0 = min(max(y0, 0), srcHeight - 1)
        let cy1 = min(max(y1, 0), srcHeight - 1)

        let outStart = (outY * outputWidth + outX) * channels

        for c in 0..<channels {
          let v00 = x0In && y0In
            ? Double(image.pixels[(cy0 * srcWidth + cx0) * channels + c]) : 0
          let v10 = x1In && y0In
            ? Double(image.pixels[(cy0 * srcWidth + cx1) * channels + c]) : 0
          let v01 = x0In && y1In
            ? Double(image.pixels[(cy1 * srcWidth + cx0) * channels + c]) : 0
          let v11 = x1In && y1In
            ? Double(image.pixels[(cy1 * srcWidth + cx1) * channels + c]) : 0

          let interp = iwx * iwy * v00 + wx * iwy * v10 + iwx * wy * v01 + wx * wy * v11
          output[outStart + c] = UInt16(max(0, min(65535, interp.rounded())))
        }
      }
    }

    return UInt16Image(width: outputWidth, height: outputHeight,
                       channels: channels, pixels: output)
  }

  private static func invertHomographyDouble(_ h: [Float]) -> [Double]? {
    let a = Double(h[0]), b = Double(h[1]), c = Double(h[2])
    let d = Double(h[3]), e = Double(h[4]), f = Double(h[5])
    let g = Double(h[6]), hh = Double(h[7]), i = Double(h[8])

    let det = a * (e * i - f * hh) - b * (d * i - f * g) + c * (d * hh - e * g)
    guard det.isFinite, det != 0 else { return nil }
    let invDet = 1.0 / det

    let inverse = [
      (e * i - f * hh) * invDet,
      (c * hh - b * i) * invDet,
      (b * f - c * e) * invDet,
      (f * g - d * i) * invDet,
      (a * i - c * g) * invDet,
      (c * d - a * f) * invDet,
      (d * hh - e * g) * invDet,
      (b * g - a * hh) * invDet,
      (a * e - b * d) * invDet,
    ]
    return inverse.allSatisfy(\.isFinite) ? inverse : nil
  }
}
