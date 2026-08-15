import Foundation

/// Identifies a density-domain colour-negative stock profile.
public struct NegativeDensityProfileID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

/// How a dye-unmix matrix was derived. Matches NegPy's crosstalk provenance tags.
public enum NegativeDensityProvenance: String, Codable, Equatable, Sendable {
  case builtin = "built-in"
  case specsheetBased = "specsheet-based"
  case measured
  case tuned
}

/// Expected film-base colour family. Independent channel stretch handles all of
/// these; the tag is used for classification and documentation.
public enum NegativeMaskFamily: String, Codable, Equatable, Sendable {
  case orange
  case cyan
  case purple
  case generic
}

/// A stock (or scanning-setup) profile for density-domain inversion.
///
/// Dye-unmix matrices are stored in NegPy's RGB row-major convention
/// (out R/G/B × in R/G/B) so published TOML/JSON stays comparable. Application
/// converts to the engine's BGR working order.
public struct NegativeDensityProfile: Codable, Equatable, Sendable, Identifiable {
  public static let currentSchemaVersion = 1
  public static let negpyAttribution =
    "Dye-unmix matrix from NegPy (GPL-3.0), https://github.com/marcinz606/NegPy"

  public var schemaVersion: Int
  public var id: NegativeDensityProfileID
  public var displayName: String
  public var provenance: NegativeDensityProvenance
  public var attribution: String
  public var maskFamily: NegativeMaskFamily
  /// 3×3 RGB row-major unmix matrix.
  public var unmixRGB: [[Double]]
  public var unmixStrength: Double
  public var printGrade: Double
  public var autoDensity: Bool
  public var autoGrade: Bool
  public var castRemovalStrength: Double
  public var notes: String

  public init(
    schemaVersion: Int = currentSchemaVersion,
    id: NegativeDensityProfileID,
    displayName: String,
    provenance: NegativeDensityProvenance,
    attribution: String = Self.negpyAttribution,
    maskFamily: NegativeMaskFamily = .generic,
    unmixRGB: [[Double]],
    unmixStrength: Double = 0.5,
    printGrade: Double = 115,
    autoDensity: Bool = true,
    autoGrade: Bool = true,
    castRemovalStrength: Double = 0.5,
    notes: String = ""
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.displayName = displayName
    self.provenance = provenance
    self.attribution = attribution
    self.maskFamily = maskFamily
    self.unmixRGB = unmixRGB
    self.unmixStrength = min(max(unmixStrength, 0), 1)
    self.printGrade = printGrade
    self.autoDensity = autoDensity
    self.autoGrade = autoGrade
    self.castRemovalStrength = min(max(castRemovalStrength, 0), 1)
    self.notes = notes
  }

  public var unmixRGBFlat: [Double] {
    unmixRGB.flatMap { $0 }
  }

  public func withUnmix(flatRGB: [Double], strength: Double? = nil) -> NegativeDensityProfile {
    var copy = self
    if flatRGB.count == 9 {
      copy.unmixRGB = [
        [flatRGB[0], flatRGB[1], flatRGB[2]],
        [flatRGB[3], flatRGB[4], flatRGB[5]],
        [flatRGB[6], flatRGB[7], flatRGB[8]],
      ]
    }
    if let strength {
      copy.unmixStrength = min(max(strength, 0), 1)
    }
    return copy
  }

  /// Identity-blended, row-normalized unmix in BGR working order.
  public func appliedUnmixBGR() -> (BGRChannelValues, BGRChannelValues, BGRChannelValues) {
    let strength = unmixStrength
    let rgb = unmixRGBFlat
    let rr = rgb.count == 9 ? rgb[0] : 1
    let rg = rgb.count == 9 ? rgb[1] : 0
    let rb = rgb.count == 9 ? rgb[2] : 0
    let gr = rgb.count == 9 ? rgb[3] : 0
    let gg = rgb.count == 9 ? rgb[4] : 1
    let gb = rgb.count == 9 ? rgb[5] : 0
    let br = rgb.count == 9 ? rgb[6] : 0
    let bg = rgb.count == 9 ? rgb[7] : 0
    let bb = rgb.count == 9 ? rgb[8] : 1
    let blended = [
      [1 - strength + strength * bb, strength * bg, strength * br],
      [strength * gb, 1 - strength + strength * gg, strength * gr],
      [strength * rb, strength * rg, 1 - strength + strength * rr],
    ]
    func normalized(_ row: [Double]) -> BGRChannelValues {
      let sum = max(row[0] + row[1] + row[2], 1e-6)
      return BGRChannelValues(blue: row[0] / sum, green: row[1] / sum, red: row[2] / sum)
    }
    return (normalized(blended[0]), normalized(blended[1]), normalized(blended[2]))
  }
}

public enum NegativeDensityProfileCatalog {
  public static let genericC41 = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "generic_c41"),
    displayName: "Generic C-41",
    provenance: .builtin,
    maskFamily: .orange,
    unmixRGB: [
      [1.00, -0.05, -0.02],
      [-0.04, 1.00, -0.08],
      [-0.01, -0.10, 1.00],
    ],
    notes: "NegPy built-in Generic C41 fallback matrix"
  )

  public static let harmanPhoenixII = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "harman_phoenix_ii"),
    displayName: "Harman Phoenix II",
    provenance: .tuned,
    maskFamily: .cyan,
    unmixRGB: [
      [1.000, -0.047, -0.010],
      [-0.075, 1.000, -0.045],
      [-0.029, -0.135, 1.000],
    ],
    unmixStrength: 0.50,
    printGrade: 118,
    castRemovalStrength: 0.55,
    notes:
      "Tuned toward a same-scene phone JPEG (different time, angle, and lighting). "
      + "Blends the NegPy Gold-200 spec-sheet unmix toward Portra-like green cleanup; "
      + "cyan/purple mask is handled by independent channel stretch"
  )

  public static let fujicolor400 = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "fujicolor_400"),
    displayName: "Fujicolor 400",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.0000, -0.0459, -0.0272],
      [-0.0482, 1.0000, -0.0586],
      [-0.0226, -0.1489, 1.0000],
    ]
  )

  public static let fujicolor200 = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "fujicolor_200"),
    displayName: "Fujicolor 200",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.0000, -0.0462, -0.0272],
      [-0.0482, 1.0000, -0.0586],
      [-0.0231, -0.1388, 1.0000],
    ]
  )

  public static let kodakPortra400 = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "kodak_portra_400"),
    displayName: "Kodak Portra 400",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.000, -0.030, 0.000],
      [-0.129, 1.000, -0.040],
      [-0.050, -0.158, 1.000],
    ]
  )

  public static let kodakGold200 = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "kodak_gold_200"),
    displayName: "Kodak Gold 200",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.0000, -0.0579, -0.0171],
      [-0.0390, 1.0000, -0.0492],
      [-0.0152, -0.1191, 1.0000],
    ]
  )

  public static let kodakPortra160 = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "kodak_portra_160"),
    displayName: "Kodak Portra 160",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.0000, -0.0201, 0.0008],
      [-0.1176, 1.0000, -0.0400],
      [-0.0421, -0.1492, 1.0000],
    ]
  )

  public static let kodakPortra800 = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "kodak_portra_800"),
    displayName: "Kodak Portra 800",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.0000, -0.0201, 0.0008],
      [-0.1368, 1.0000, -0.0400],
      [-0.0578, -0.1588, 1.0000],
    ]
  )

  public static let kodakEktar100 = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "kodak_ektar_100"),
    displayName: "Kodak Ektar 100",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.0000, -0.0288, -0.0088],
      [-0.0984, 1.0000, -0.0390],
      [-0.0261, -0.1392, 1.0000],
    ]
  )

  public static let kodakUltramax400 = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "kodak_ultramax_400"),
    displayName: "Kodak Ultra Max 400",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.0000, -0.0579, -0.0171],
      [-0.0390, 1.0000, -0.0492],
      [-0.0152, -0.1191, 1.0000],
    ]
  )

  public static let kodakVision3500T = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "kodak_vision3_500t"),
    displayName: "Kodak VISION3 500T",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.000, -0.099, -0.006],
      [-0.170, 1.000, -0.040],
      [-0.090, -0.201, 1.000],
    ],
    notes: "Parent stock for CineStill 800T-style tungsten captures"
  )

  public static let kodakVision3250D = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "kodak_vision3_250d"),
    displayName: "Kodak VISION3 250D",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.001, -0.005, 0.000],
      [-0.140, 1.005, -0.025],
      [-0.019, -0.186, 1.005],
    ]
  )

  public static let fujicolorNatura1600 = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "fujicolor_natura_1600"),
    displayName: "Fujicolor Natura 1600",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.0000, -0.0564, -0.0261],
      [-0.0580, 1.0000, -0.0683],
      [-0.0217, -0.1387, 1.0000],
    ]
  )

  public static let fujicolorPro400H = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "fujicolor_pro_400h"),
    displayName: "Fujicolor Pro 400H",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.0000, -0.0278, -0.0186],
      [-0.0590, 1.0000, -0.0488],
      [-0.0128, -0.1196, 1.0000],
    ]
  )

  public static let fujicolorC200 = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "fujicolor_c200"),
    displayName: "Fujicolor C200",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.0000, -0.0459, -0.0272],
      [-0.0482, 1.0000, -0.0586],
      [-0.0226, -0.1489, 1.0000],
    ],
    notes: "Same spec-sheet estimate as Fujicolor 400"
  )

  public static let fujicolorSuperiaXtra400 = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "fujicolor_superia_xtra_400"),
    displayName: "Fujicolor Superia X-TRA 400",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.0000, -0.0459, -0.0272],
      [-0.0482, 1.0000, -0.0586],
      [-0.0226, -0.1489, 1.0000],
    ],
    notes: "Same spec-sheet estimate as Fujicolor 400"
  )

  public static let kodakAerocolorIV = NegativeDensityProfile(
    id: NegativeDensityProfileID(rawValue: "kodak_aerocolor_iv_2460"),
    displayName: "Kodak Aerocolor IV 2460",
    provenance: .specsheetBased,
    maskFamily: .orange,
    unmixRGB: [
      [1.0000, -0.0963, -0.0233],
      [-0.0580, 1.0000, -0.0683],
      [-0.0205, -0.1579, 1.0000],
    ]
  )

  public static let bundled: [NegativeDensityProfile] = [
    genericC41,
    harmanPhoenixII,
    fujicolor400,
    fujicolor200,
    fujicolorC200,
    fujicolorSuperiaXtra400,
    fujicolorNatura1600,
    fujicolorPro400H,
    kodakPortra160,
    kodakPortra400,
    kodakPortra800,
    kodakGold200,
    kodakEktar100,
    kodakUltramax400,
    kodakAerocolorIV,
    kodakVision3250D,
    kodakVision3500T,
  ]

  public static func profile(id: String) -> NegativeDensityProfile {
    bundled.first { $0.id.rawValue == id } ?? genericC41
  }

  public static func profile(id: NegativeDensityProfileID) -> NegativeDensityProfile {
    profile(id: id.rawValue)
  }

  public static func load(from directory: URL) -> [NegativeDensityProfile] {
    let contents =
      (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )) ?? []
    return contents.compactMap { url in
      guard url.pathExtension.lowercased() == "json" else { return nil }
      guard let data = try? Data(contentsOf: url) else { return nil }
      return try? JSONDecoder().decode(NegativeDensityProfile.self, from: data)
    }
  }
}
