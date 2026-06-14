import CoreGraphics
import Foundation

extension UInt16Image {
  public func makePreviewCGImage() -> CGImage? {
    guard channels == 1 || channels == 3 else {
      return nil
    }

    var bytes = [UInt8]()
    bytes.reserveCapacity(width * height * 4)
    for pixelIndex in 0..<(width * height) {
      if channels == 1 {
        let value = UInt8(truncatingIfNeeded: pixels[pixelIndex] >> 8)
        bytes.append(contentsOf: [value, value, value, 255])
      } else {
        let componentIndex = pixelIndex * 3
        bytes.append(UInt8(truncatingIfNeeded: pixels[componentIndex + 2] >> 8))
        bytes.append(UInt8(truncatingIfNeeded: pixels[componentIndex + 1] >> 8))
        bytes.append(UInt8(truncatingIfNeeded: pixels[componentIndex] >> 8))
        bytes.append(255)
      }
    }

    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
      return nil
    }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }
}
