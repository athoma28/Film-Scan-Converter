import Accelerate
import Foundation

public enum PerspectiveTransform {

  public static func crop(
    _ image: UInt16Image,
    normalizedRect: RotatedRect,
    borderPercent: Double = 0
  ) -> UInt16Image? {
    let rect = ContourDetection.denormalize(
      normalizedRect,
      imageWidth: image.width,
      imageHeight: image.height
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
    let outputWidth = max(1, Int(rect.height * (1 - xCrop / 100)))
    let outputHeight = max(1, Int(rect.width * (1 - yCrop / 100)))
    let source = box.map { (x: Float($0.x), y: Float($0.y)) }
    let destination: [(x: Float, y: Float)] = [
      (0, Float(outputWidth - 1)),
      (0, 0),
      (Float(outputHeight - 1), 0),
      (Float(outputHeight - 1), Float(outputWidth - 1)),
    ]
    guard let homography = computeHomography(srcPoints: source, dstPoints: destination) else {
      return nil
    }
    var result = warpPerspective(
      image,
      homography: homography,
      outputWidth: outputHeight,
      outputHeight: outputWidth
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

    let invH = invertHomographyDouble(homography)

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

        guard abs(dz) > 1e-10 else { continue }

        let srcX = dx / dz
        let srcY = dy / dz

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

  private static func invertHomographyDouble(_ h: [Float]) -> [Double] {
    let a = Double(h[0]), b = Double(h[1]), c = Double(h[2])
    let d = Double(h[3]), e = Double(h[4]), f = Double(h[5])
    let g = Double(h[6]), hh = Double(h[7]), i = Double(h[8])

    let det = a * (e * i - f * hh) - b * (d * i - f * g) + c * (d * hh - e * g)
    let invDet = 1.0 / det

    return [
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
  }
}
