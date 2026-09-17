extension UInt16Image {
  /// Copy only the exact diagnostic sample positions, so asynchronous statistics
  /// do not extend the lifetime of a full-resolution corrected CPU buffer.
  public func previewStatisticsSample() -> PreviewStatisticsSample {
    let count = min(width * height, RenderReadyLinearImage.statisticsSampleLimit)
    let total = width * height
    var sampled = [UInt16](repeating: 0, count: count * channels)
    for index in 0..<count {
      let pixel = count == 1 ? total / 2 : index * (total - 1) / (count - 1)
      for channel in 0..<channels {
        sampled[index * channels + channel] = pixels[pixel * channels + channel]
      }
    }
    return PreviewStatisticsSample(
      image: UInt16Image(width: count, height: 1, channels: channels, pixels: sampled),
      totalPixelCount: total)
  }

  /// Bounded preview diagnostics in normalized display-code space. This
  /// preserves the preview's existing luminance and clipping contract; it
  /// does not linearize the image. Grayscale is treated as equal BGR values.
  /// No full-frame floating-point conversion or image copy is needed.
  public func previewStatistics(
    maximumSampleCount: Int = RenderReadyLinearImage.statisticsSampleLimit
  ) -> RenderReadyImageStatistics? {
    guard channels == 1 || channels == 3 else { return nil }
    return RenderReadyLinearImage.sampleStatistics(
      pixelCount: width * height,
      maximumSampleCount: maximumSampleCount
    ) { index in
      let base = index * channels
      let blue = Double(pixels[base]) / 65_535
      if channels == 1 {
        return (blue, blue, blue)
      }
      return (blue, Double(pixels[base + 1]) / 65_535, Double(pixels[base + 2]) / 65_535)
    }
  }
}

/// A compact, exact snapshot of the diagnostic sample, including source size.
public struct PreviewStatisticsSample: Sendable {
  public let image: UInt16Image
  public let totalPixelCount: Int

  public func statistics() -> RenderReadyImageStatistics? {
    guard let result = image.previewStatistics() else { return nil }
    return RenderReadyImageStatistics(
      totalPixelCount: totalPixelCount, sampleCount: result.sampleCount,
      linearLuminance: result.linearLuminance, logLuminance: result.logLuminance,
      lowClippingRatios: result.lowClippingRatios, highClippingRatios: result.highClippingRatios,
      normalizedToneReferences: result.normalizedToneReferences)
  }
}
