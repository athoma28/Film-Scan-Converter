import Foundation

/// Original, registered captures for one sequential stacking operation.
/// Only the reference, current decode, output, and a bounded row band need
/// resident pixel arrays. The stored samples retain their original HDR weights.
final class StoredScanStack {
  private let directory: URL
  private var reference: UInt16Image?
  private var referencePlanes: StackAnalysis.Pyramid?
  // Capture zero remains resident for registration and merging; handles store
  // only captures 1... so the reference never needs a redundant disk copy.
  private var handles: [FileHandle] = []
  private var alignments: [ScanStackAlignment] = []
  private var exposureOffsetsEV: [Double] = []

  init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws {
    directory = temporaryDirectory.appendingPathComponent("fsc-stack-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  deinit {
    for handle in handles { try? handle.close() }
    try? FileManager.default.removeItem(at: directory)
  }

  func append(_ image: UInt16Image) throws {
    try Task.checkCancellation()
    let registration: (alignment: ScanStackAlignment, exposureEV: Double)
    if let reference, let referencePlanes {
      registration = try StackAnalysis.registration(
        reference: reference, candidate: image, index: alignments.count,
        referencePlanes: referencePlanes)
    } else {
      referencePlanes = try StackAnalysis.prepareReference(image)
      reference = image
      alignments.append(
        ScanStackAlignment(translationX: 0, translationY: 0, confidence: 1, overlap: 1))
      exposureOffsetsEV.append(0)
      return
    }

    let url = directory.appendingPathComponent("\(alignments.count).pixels")
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forUpdating: url)
    do {
      try image.pixels.withUnsafeBufferPointer { buffer in
        // The synchronous write completes while the image owns this storage.
        let data = Data(
          bytesNoCopy: UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
          count: buffer.count * MemoryLayout<UInt16>.stride, deallocator: .none)
        try handle.write(contentsOf: data)
      }
    } catch {
      try? handle.close()
      throw error
    }
    handles.append(handle)
    alignments.append(registration.alignment)
    exposureOffsetsEV.append(registration.exposureEV)
  }

  func finish(mode: ScanStackMode, bandComponentLimit: Int = 8_388_608) throws
    -> MultiScanStackResult
  {
    guard alignments.count >= 2, let reference else { throw ScanStackError.insufficientImages }
    try Task.checkCancellation()
    let width = reference.width
    let height = reference.height
    let channels = reference.channels
    let componentsPerRow = width * channels
    let bytesPerRow = componentsPerRow * MemoryLayout<UInt16>.stride
    let rowsPerBand = max(1, bandComponentLimit / componentsPerRow / alignments.count)
    let effectiveMode = StackAnalysis.effectiveMode(mode, exposureOffsetsEV: exposureOffsetsEV)
    var pixels = [UInt16](repeating: 0, count: reference.pixels.count)

    for start in stride(from: 0, to: height, by: rowsPerBand) {
      try Task.checkCancellation()
      let rows = start..<min(start + rowsPerBand, height)
      var sources = [
        StackAnalysis.MergeSource(
          pixels: reference.pixels, rowOffset: 0,
          translationX: 0, translationY: 0, inverseExposureScale: 1)
      ]
      for (storedIndex, handle) in handles.enumerated() {
        let index = storedIndex + 1
        let alignment = alignments[index]
        let firstRow = min(height, max(0, rows.lowerBound + alignment.translationY))
        let lastRow = min(height, max(0, rows.upperBound + alignment.translationY))
        try handle.seek(toOffset: UInt64(firstRow * bytesPerRow))
        let data = try readExactly((lastRow - firstRow) * bytesPerRow, from: handle)
        var samples = [UInt16](repeating: 0, count: (lastRow - firstRow) * componentsPerRow)
        samples.withUnsafeMutableBytes { buffer in
          _ = data.copyBytes(to: buffer)
        }
        sources.append(
          StackAnalysis.MergeSource(
            pixels: samples,
            rowOffset: firstRow,
            translationX: alignment.translationX,
            translationY: alignment.translationY,
            inverseExposureScale: pow(2, -exposureOffsetsEV[index])))
      }
      let band = try StackAnalysis.mergeRows(
        width: width, height: height, channels: channels, rows: rows,
        sources: sources, mode: effectiveMode)
      pixels.replaceSubrange(
        (rows.lowerBound * componentsPerRow)..<(rows.upperBound * componentsPerRow), with: band)
    }
    return MultiScanStackResult(
      image: UInt16Image(width: width, height: height, channels: channels, pixels: pixels),
      effectiveMode: effectiveMode, alignments: alignments, exposureOffsetsEV: exposureOffsetsEV)
  }

  private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
    var data = Data()
    data.reserveCapacity(count)
    while data.count < count {
      try Task.checkCancellation()
      guard let next = try handle.read(upToCount: count - data.count), !next.isEmpty else {
        throw CocoaError(.fileReadCorruptFile)
      }
      data.append(next)
    }
    return data
  }
}
