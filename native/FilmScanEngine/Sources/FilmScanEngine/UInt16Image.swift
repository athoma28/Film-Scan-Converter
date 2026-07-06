import Foundation

public struct UInt16Image: Equatable, Sendable {
  public let width: Int
  public let height: Int
  public let channels: Int
  public private(set) var pixels: [UInt16]

  public init(width: Int, height: Int, channels: Int, pixels: [UInt16]) {
    precondition(width > 0 && height > 0, "Image dimensions must be positive")
    precondition(channels > 0, "An image must have at least one channel")
    precondition(
      pixels.count == width * height * channels,
      "Pixel count does not match image dimensions"
    )
    self.width = width
    self.height = height
    self.channels = channels
    self.pixels = pixels
  }

  mutating func neutralizeInvertedZeroLight(from source: UInt16Image, threshold: UInt16) {
    precondition(
      width == source.width && height == source.height && channels == source.channels,
      "Black-mask source must match the output image"
    )
    for pixelIndex in 0..<(width * height) {
      let base = pixelIndex * channels
      var sourceMaximum: UInt16 = 0
      for channel in 0..<channels {
        sourceMaximum = max(sourceMaximum, source.pixels[base + channel])
      }
      if sourceMaximum <= threshold {
        for channel in 0..<channels {
          pixels[base + channel] = 65535
        }
      }
    }
  }

  public func rotated(quarterTurns: Int, flipHorizontally: Bool = false) -> UInt16Image {
    let normalizedTurns = ((quarterTurns % 4) + 4) % 4
    let rotated: UInt16Image

    switch normalizedTurns {
    case 0:
      rotated = self
    case 1:
      rotated = remapped(width: height, height: width) { x, y in
        (y, height - 1 - x)
      }
    case 2:
      rotated = remapped(width: width, height: height) { x, y in
        (width - 1 - x, height - 1 - y)
      }
    default:
      rotated = remapped(width: height, height: width) { x, y in
        (width - 1 - y, x)
      }
    }

    guard flipHorizontally else {
      return rotated
    }
    return rotated.remapped(width: rotated.width, height: rotated.height) { x, y in
      (rotated.width - 1 - x, y)
    }
  }

  public func addingFrame(percent: Int, aspectRatio: AspectRatio? = nil) -> UInt16Image {
    if percent == 0 && aspectRatio == nil {
      return self
    }

    let frameSize = max(1, Int(Double(min(width, height) * percent) / 100.0))
    var framed = padded(
      top: frameSize,
      bottom: frameSize,
      left: frameSize,
      right: frameSize
    )

    guard let aspectRatio else {
      return framed
    }

    let targetRatio = Double(aspectRatio.width) / Double(aspectRatio.height)
    let currentRatio = Double(framed.width) / Double(framed.height)
    if currentRatio > targetRatio {
      let newHeight = Int(Double(framed.width) / targetRatio)
      let total = newHeight - framed.height
      framed = framed.padded(top: total / 2, bottom: total - total / 2, left: 0, right: 0)
    } else {
      let newWidth = Int(Double(framed.height) * targetRatio)
      let total = newWidth - framed.width
      framed = framed.padded(top: 0, bottom: 0, left: total / 2, right: total - total / 2)
    }
    return framed
  }

  public func resizedToFit(maxDimension: Int) -> UInt16Image {
    precondition(maxDimension > 0, "Maximum dimension must be positive")
    let largestDimension = max(width, height)
    guard largestDimension > maxDimension else {
      return self
    }

    let scale = Double(maxDimension) / Double(largestDimension)
    let outputWidth = max(1, Int((Double(width) * scale).rounded()))
    let outputHeight = max(1, Int((Double(height) * scale).rounded()))
    return remapped(width: outputWidth, height: outputHeight) { x, y in
      (
        min(width - 1, x * width / outputWidth),
        min(height - 1, y * height / outputHeight)
      )
    }
  }

  public func resized(width outputWidth: Int, height outputHeight: Int) -> UInt16Image {
    precondition(outputWidth > 0 && outputHeight > 0, "Output dimensions must be positive")
    guard outputWidth != width || outputHeight != height else {
      return self
    }
    return remapped(width: outputWidth, height: outputHeight) { x, y in
      (
        min(width - 1, x * width / outputWidth),
        min(height - 1, y * height / outputHeight)
      )
    }
  }

  private func remapped(
    width outputWidth: Int,
    height outputHeight: Int,
    sourceCoordinate: (_ x: Int, _ y: Int) -> (x: Int, y: Int)
  ) -> UInt16Image {
    var output = [UInt16](repeating: 0, count: outputWidth * outputHeight * channels)
    for y in 0..<outputHeight {
      for x in 0..<outputWidth {
        let source = sourceCoordinate(x, y)
        let sourceStart = (source.y * width + source.x) * channels
        let outputStart = (y * outputWidth + x) * channels
        for channel in 0..<channels {
          output[outputStart + channel] = pixels[sourceStart + channel]
        }
      }
    }
    return UInt16Image(width: outputWidth, height: outputHeight, channels: channels, pixels: output)
  }

  private func padded(top: Int, bottom: Int, left: Int, right: Int) -> UInt16Image {
    let outputWidth = width + left + right
    let outputHeight = height + top + bottom
    var output = [UInt16](repeating: .max, count: outputWidth * outputHeight * channels)

    for y in 0..<height {
      let sourceStart = y * width * channels
      let outputStart = ((y + top) * outputWidth + left) * channels
      output.replaceSubrange(
        outputStart..<(outputStart + width * channels),
        with: pixels[sourceStart..<(sourceStart + width * channels)]
      )
    }
    return UInt16Image(width: outputWidth, height: outputHeight, channels: channels, pixels: output)
  }

  func rgba16Data() -> Data? {
    guard channels == 1 || channels == 3 else {
      return nil
    }

    let pixelCount = width * height
    var data = Data(count: pixelCount * 8)
    let singleChannel = channels == 1
    data.withUnsafeMutableBytes { (rbp: UnsafeMutableRawBufferPointer) in
      let buf = rbp.bindMemory(to: UInt16.self)
      pixels.withUnsafeBufferPointer { src in
        if singleChannel {
          var di = 0
          for i in 0..<pixelCount {
            let v = src[i]
            buf[di] = v
            buf[di + 1] = v
            buf[di + 2] = v
            buf[di + 3] = .max
            di += 4
          }
        } else {
          var si = 0
          var di = 0
          for _ in 0..<pixelCount {
            buf[di] = src[si + 2]
            buf[di + 1] = src[si + 1]
            buf[di + 2] = src[si]
            buf[di + 3] = .max
            si += 3
            di += 4
          }
        }
      }
    }
    return data
  }

  func rgba8Data() -> Data? {
    guard channels == 1 || channels == 3 else {
      return nil
    }

    let pixelCount = width * height
    var data = Data(count: pixelCount * 4)
    let singleChannel = channels == 1
    data.withUnsafeMutableBytes { (rbp: UnsafeMutableRawBufferPointer) in
      let buf = rbp.bindMemory(to: UInt8.self)
      pixels.withUnsafeBufferPointer { src in
        if singleChannel {
          var di = 0
          for i in 0..<pixelCount {
            let v = UInt8(truncatingIfNeeded: src[i] >> 8)
            buf[di] = v
            buf[di + 1] = v
            buf[di + 2] = v
            buf[di + 3] = 255
            di += 4
          }
        } else {
          var si = 0
          var di = 0
          for _ in 0..<pixelCount {
            buf[di] = UInt8(truncatingIfNeeded: src[si + 2] >> 8)
            buf[di + 1] = UInt8(truncatingIfNeeded: src[si + 1] >> 8)
            buf[di + 2] = UInt8(truncatingIfNeeded: src[si] >> 8)
            buf[di + 3] = 255
            si += 3
            di += 4
          }
        }
      }
    }
    return data
  }
}
