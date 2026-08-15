import Foundation

/// Identifies an RA4 / neutral paper character used after density-print inversion.
public struct DensityPaperProfileID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

/// Print-paper character for the density-print path.
///
/// Tonal fields override the H&D curve shape. Color fields model RA4 dye-layer
/// contrast crossover (`channelGammaRGB`), highlight base tint (`baseTintCMY`),
/// and unwanted dye absorptions (`dyeMatrixRGB`, NegPy RGB row-major, applied
/// to density above paper base). The Neutral profile reproduces the previous
/// hardcoded defaults exactly.
public struct DensityPaperProfile: Codable, Equatable, Sendable, Identifiable {
  public static let negpyAttribution =
    "RA4 paper character from NegPy (GPL-3.0), https://github.com/marcinz606/NegPy"

  public var id: DensityPaperProfileID
  public var displayName: String
  public var attribution: String
  public var dMax: Double
  public var dMin: Double
  public var toeSharpnessBase: Double
  public var shoulderSharpnessBase: Double
  public var toeHeight: Double
  public var shoulderHeight: Double
  public var paperMidtoneGamma: Double
  public var paperGammaWidth: Double
  /// Per-channel (R, G, B) slope multipliers.
  public var channelGammaRGB: [Double]
  /// Per-channel (C, M, Y) additions to the paper-white floor.
  public var baseTintCMY: [Double]
  /// 3×3 RGB row-major dye-coupling matrix, `D_rgb = M · D_dye` above base.
  public var dyeMatrixRGB: [[Double]]
  public var notes: String

  public init(
    id: DensityPaperProfileID,
    displayName: String,
    attribution: String = Self.negpyAttribution,
    dMax: Double = DensityPrintProcessing.dMax,
    dMin: Double = DensityPrintProcessing.dMin,
    toeSharpnessBase: Double = DensityPrintProcessing.toeSharpnessBase,
    shoulderSharpnessBase: Double = DensityPrintProcessing.shoulderSharpnessBase,
    toeHeight: Double = DensityPrintProcessing.toeHeight,
    shoulderHeight: Double = DensityPrintProcessing.shoulderHeight,
    paperMidtoneGamma: Double = DensityPrintProcessing.paperMidtoneGamma,
    paperGammaWidth: Double = DensityPrintProcessing.paperGammaWidth,
    channelGammaRGB: [Double] = [1, 1, 1],
    baseTintCMY: [Double] = [0, 0, 0],
    dyeMatrixRGB: [[Double]] = [
      [1, 0, 0],
      [0, 1, 0],
      [0, 0, 1],
    ],
    notes: String = ""
  ) {
    self.id = id
    self.displayName = displayName
    self.attribution = attribution
    self.dMax = dMax
    self.dMin = dMin
    self.toeSharpnessBase = toeSharpnessBase
    self.shoulderSharpnessBase = shoulderSharpnessBase
    self.toeHeight = toeHeight
    self.shoulderHeight = shoulderHeight
    self.paperMidtoneGamma = paperMidtoneGamma
    self.paperGammaWidth = paperGammaWidth
    self.channelGammaRGB = channelGammaRGB.count == 3 ? channelGammaRGB : [1, 1, 1]
    self.baseTintCMY = baseTintCMY.count == 3 ? baseTintCMY : [0, 0, 0]
    self.dyeMatrixRGB = dyeMatrixRGB
    self.notes = notes
  }

  public var isNeutral: Bool {
    id.rawValue == DensityPaperProfileCatalog.neutral.id.rawValue
  }

  /// Paper-white floor per BGR channel, including CMY base tint.
  public var paperDMinBGR: BGRChannelValues {
    let cyan = baseTintCMY[0]
    let magenta = baseTintCMY[1]
    let yellow = baseTintCMY[2]
    return BGRChannelValues(
      blue: max(0, dMin + yellow),
      green: max(0, dMin + magenta),
      red: max(0, dMin + cyan)
    )
  }

  /// Channel-gamma slope multipliers in BGR order.
  public var channelGammaBGR: BGRChannelValues {
    BGRChannelValues(
      blue: channelGammaRGB[2],
      green: channelGammaRGB[1],
      red: channelGammaRGB[0]
    )
  }

  /// Row-normalized dye-coupling matrix in BGR working order.
  public func appliedDyeMixBGR() -> (BGRChannelValues, BGRChannelValues, BGRChannelValues) {
    let rgb = dyeMatrixRGB.flatMap { $0 }
    let rr = rgb.count == 9 ? rgb[0] : 1
    let rg = rgb.count == 9 ? rgb[1] : 0
    let rb = rgb.count == 9 ? rgb[2] : 0
    let gr = rgb.count == 9 ? rgb[3] : 0
    let gg = rgb.count == 9 ? rgb[4] : 1
    let gb = rgb.count == 9 ? rgb[5] : 0
    let br = rgb.count == 9 ? rgb[6] : 0
    let bg = rgb.count == 9 ? rgb[7] : 0
    let bb = rgb.count == 9 ? rgb[8] : 1
    let rows = [
      [bb, bg, br],
      [gb, gg, gr],
      [rb, rg, rr],
    ]
    func normalized(_ row: [Double]) -> BGRChannelValues {
      let sum = max(row[0] + row[1] + row[2], 1e-6)
      return BGRChannelValues(blue: row[0] / sum, green: row[1] / sum, red: row[2] / sum)
    }
    return (normalized(rows[0]), normalized(rows[1]), normalized(rows[2]))
  }
}

public enum DensityPaperProfileCatalog {
  public static let neutral = DensityPaperProfile(
    id: DensityPaperProfileID(rawValue: "neutral"),
    displayName: "Neutral",
    notes: "Identity paper: previous density-print defaults, no RA4 dye coupling"
  )

  public static let kodakEnduraPremier = DensityPaperProfile(
    id: DensityPaperProfileID(rawValue: "kodak_endura"),
    displayName: "Kodak Endura Premier",
    dMax: 2.55,
    dMin: 0.06,
    toeSharpnessBase: 3.5,
    paperMidtoneGamma: 0.22,
    channelGammaRGB: [1.04, 1.0, 0.98],
    dyeMatrixRGB: [
      [0.95, 0.04, 0.01],
      [0.08, 0.88, 0.04],
      [0.04, 0.14, 0.82],
    ],
    notes: "Deep blacks; red densest at Dmax (cool shadows). Dye matrix estimated, not measured."
  )

  public static let fujiCrystalArchive = DensityPaperProfile(
    id: DensityPaperProfileID(rawValue: "fuji_crystal"),
    displayName: "Fujicolor Crystal Archive",
    dMax: 2.35,
    dMin: 0.03,
    channelGammaRGB: [1.0, 1.03, 1.05],
    baseTintCMY: [0.0, -0.01, -0.015],
    dyeMatrixRGB: [
      [0.96, 0.03, 0.01],
      [0.06, 0.91, 0.03],
      [0.03, 0.11, 0.86],
    ],
    notes: "Brilliant whites with a slight cool base. Dye matrix estimated, not measured."
  )

  public static let bundled: [DensityPaperProfile] = [
    neutral,
    kodakEnduraPremier,
    fujiCrystalArchive,
  ]

  public static func profile(id: String) -> DensityPaperProfile {
    bundled.first { $0.id.rawValue == id } ?? neutral
  }

  public static func profile(id: DensityPaperProfileID) -> DensityPaperProfile {
    profile(id: id.rawValue)
  }
}
