import Foundation
import Testing

@Suite("Paired reference input contracts")
struct SampleRawCorpusTests {
  @Test("Reviewed orientation requires the exact JPEG and XMP contents")
  func reviewedOrientationRejectsChangedInputs() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("reference-orientation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let targetURL = directory.appendingPathComponent("reference.jpg")
    let jpegData = Data("original JPEG bytes".utf8)
    let xmpData = Data("original XMP bytes".utf8)
    try jpegData.write(to: targetURL)
    let orientation = SampleRawReferenceOrientation(
      targetFilename: targetURL.lastPathComponent,
      targetSHA256: SampleRawReferenceOrientation.digest(jpegData),
      xmpSHA256: SampleRawReferenceOrientation.digest(xmpData),
      targetAlignmentQuarterTurns: 1)
    #expect(
      try orientation.validatedQuarterTurns(targetURL: targetURL, xmpData: xmpData, frame: "test")
        == 1)
    #expect(throws: SampleRawReferenceError.self) {
      try orientation.validatedQuarterTurns(
        targetURL: targetURL, xmpData: Data("changed".utf8), frame: "test")
    }
    try Data("changed JPEG bytes".utf8).write(to: targetURL)
    #expect(throws: SampleRawReferenceError.self) {
      try orientation.validatedQuarterTurns(targetURL: targetURL, xmpData: xmpData, frame: "test")
    }
  }

  @Test("Malformed metadata reports the frame before attempting a RAW decode")
  func metadataFailureIdentifiesFrame() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("reference-error-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let xmpURL = directory.appendingPathComponent("frame.xmp")
    try Data(#"tiff:Orientation="invalid""#.utf8).write(to: xmpURL)
    let triplet = SampleRawTriplet(
      stockID: "test", stem: "frame", rawURL: directory.appendingPathComponent("missing.RAF"),
      targetURL: directory.appendingPathComponent("missing.jpg"), xmpURL: xmpURL,
      isMonochrome: false)
    do {
      _ = try SampleRawCorpus.loadAlignedReference(triplet)
      Issue.record("Invalid orientation should be rejected")
    } catch let error as SampleRawReferenceError {
      #expect(error.frame == "test/frame")
      #expect(error.reason.contains("Unsupported XMP orientation invalid"))
    }
  }
}
