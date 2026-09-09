extension UInt16Image {
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
