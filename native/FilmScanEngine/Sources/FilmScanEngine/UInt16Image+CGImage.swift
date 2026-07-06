import CoreGraphics
import Foundation

extension UInt16Image {
  public func makePreviewCGImage16() -> CGImage? {
    guard let data = rgba16Data() else {
      return nil
    }

    guard let provider = CGDataProvider(data: data as CFData) else {
      return nil
    }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 16,
      bitsPerPixel: 64,
      bytesPerRow: width * 8,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: .byteOrder16Little.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
      ),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }

  public func makePreviewCGImage() -> CGImage? {
    guard let data = rgba8Data() else {
      return nil
    }

    guard let provider = CGDataProvider(data: data as CFData) else {
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
