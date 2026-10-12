import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Exact density-print input lookup")
struct DensityPrintLookupTests {
  @Test("Every UInt16 code retains the scalar log-transmittance Double bit pattern")
  func allInputCodesMatchScalar() {
    let table = DensityPrintProcessing.logTransmittanceByCode
    #expect(table.count == 65_536)
    let firstMismatch = (0...Int(UInt16.max)).first { code in
      let linear = max(
        FilmNegativeProcessing.sRGBToLinear(Double(code) / 65_535.0),
        DensityPrintProcessing.epsilon)
      return table[code].bitPattern != log10(linear).bitPattern
    }
    #expect(firstMismatch == nil, "First nonexact input code: \(firstMismatch as Any)")
  }
}
