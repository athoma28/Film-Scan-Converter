import CoreGraphics
import Testing

/// Read visible RGB samples without treating row padding or skipped alpha as pixels.
func previewRGBPixels(
  _ image: CGImage, sourceLocation: SourceLocation = #_sourceLocation
) throws -> [UInt8] {
  try #require(
    image.bitsPerComponent == 8 && image.bitsPerPixel == 32, sourceLocation: sourceLocation)
  try #require(
    image.alphaInfo == .noneSkipLast || image.alphaInfo == .premultipliedLast
      || image.alphaInfo == .last, sourceLocation: sourceLocation)
  try #require(
    image.bitmapInfo.intersection(.byteOrderMask) != .byteOrder32Little,
    sourceLocation: sourceLocation)
  try #require(image.bytesPerRow >= image.width * 4, sourceLocation: sourceLocation)
  let data = try #require(image.dataProvider?.data, sourceLocation: sourceLocation)
  try #require(
    CFDataGetLength(data) >= image.bytesPerRow * (image.height - 1) + image.width * 4,
    sourceLocation: sourceLocation)
  let pointer = try #require(CFDataGetBytePtr(data), sourceLocation: sourceLocation)
  var pixels: [UInt8] = []
  pixels.reserveCapacity(image.width * image.height * 3)
  for y in 0..<image.height {
    for x in 0..<image.width {
      let pixel = pointer + y * image.bytesPerRow + x * 4
      pixels.append(contentsOf: UnsafeBufferPointer(start: pixel, count: 3))
    }
  }
  return pixels
}

@discardableResult
func expectPreviewRGBPixelsMatch(
  _ actual: CGImage, _ expected: CGImage, tolerance: Int = 0, label: String = "Preview",
  requireOpaque: Bool = false,
  sourceLocation: SourceLocation = #_sourceLocation
) throws -> [UInt8] {
  try #require(
    actual.width == expected.width && actual.height == expected.height,
    "\(label): dimensions differ", sourceLocation: sourceLocation)
  let actualPixels = try previewRGBPixels(actual, sourceLocation: sourceLocation)
  let expectedPixels = try previewRGBPixels(expected, sourceLocation: sourceLocation)
  try #require(actualPixels.count == expectedPixels.count, sourceLocation: sourceLocation)
  var maximumDifference = 0
  var worstIndex = 0
  for index in expectedPixels.indices {
    let difference = abs(Int(actualPixels[index]) - Int(expectedPixels[index]))
    if difference > maximumDifference {
      maximumDifference = difference
      worstIndex = index
    }
  }
  #expect(
    maximumDifference <= tolerance,
    """
    \(label): max RGB error \(maximumDifference)/255 at pixel \(worstIndex / 3), \
    channel \(worstIndex % 3): actual \(actualPixels[worstIndex]), expected \(expectedPixels[worstIndex])
    """, sourceLocation: sourceLocation)
  if requireOpaque && actual.alphaInfo != .noneSkipLast {
    // RGB extraction validated this RGBA layout. A skipped alpha byte has no
    // display meaning; meaningful GPU alpha must preserve the opaque source.
    let data = try #require(actual.dataProvider?.data, sourceLocation: sourceLocation)
    let pointer = try #require(CFDataGetBytePtr(data), sourceLocation: sourceLocation)
    let minimumAlpha = withExtendedLifetime(data) {
      var minimum = 255
      for y in 0..<actual.height {
        for x in 0..<actual.width {
          minimum = min(minimum, Int(pointer[y * actual.bytesPerRow + x * 4 + 3]))
        }
      }
      return minimum
    }
    #expect(
      minimumAlpha >= 255 - tolerance,
      "\(label): minimum alpha \(minimumAlpha)/255, expected opaque output",
      sourceLocation: sourceLocation)
  }
  return actualPixels
}
