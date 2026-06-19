import Foundation

public struct CaptureProfileID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct FilmStockProfileID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct CaptureProfile: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var id: CaptureProfileID
  public var cameraModel: String
  public var lensModel: String
  public var backlightDescription: String
  public var estimatedColorTemperature: Double?
  public var normalizationParams: CaptureNormalizationParameters
  public var preferredISO: Double?
  public var notes: String

  public init(
    schemaVersion: Int = 1,
    id: CaptureProfileID,
    cameraModel: String = "",
    lensModel: String = "",
    backlightDescription: String = "",
    estimatedColorTemperature: Double? = nil,
    normalizationParams: CaptureNormalizationParameters = CaptureNormalizationParameters(),
    preferredISO: Double? = nil,
    notes: String = ""
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.cameraModel = cameraModel
    self.lensModel = lensModel
    self.backlightDescription = backlightDescription
    self.estimatedColorTemperature = estimatedColorTemperature
    self.normalizationParams = normalizationParams
    self.preferredISO = preferredISO
    self.notes = notes
  }

  public static let `default` = CaptureProfile(
    id: CaptureProfileID(rawValue: "default"),
    cameraModel: "Unknown",
    normalizationParams: CaptureNormalizationParameters()
  )
}

public struct FilmStockProfile: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var id: FilmStockProfileID
  public var displayName: String
  public var filmType: FilmType
  public var c41Profile: GenericC41Profile
  public var displayRendering: DisplayRenderingParameters
  public var notes: String

  public init(
    schemaVersion: Int = 1,
    id: FilmStockProfileID,
    displayName: String,
    filmType: FilmType,
    c41Profile: GenericC41Profile = .identity,
    displayRendering: DisplayRenderingParameters = DisplayRenderingParameters(),
    notes: String = ""
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.displayName = displayName
    self.filmType = filmType
    self.c41Profile = c41Profile
    self.displayRendering = displayRendering
    self.notes = notes
  }

  public static let genericColorNegative = FilmStockProfile(
    id: FilmStockProfileID(rawValue: "generic_colour_negative"),
    displayName: "Generic Color Negative",
    filmType: .colourNegative
  )

  public static let genericBW = FilmStockProfile(
    id: FilmStockProfileID(rawValue: "generic_bw_negative"),
    displayName: "Generic B&W Negative",
    filmType: .blackAndWhiteNegative
  )
}

public struct ResolvedPipelineProfile: Codable, Equatable, Sendable {
  public var captureProfile: CaptureProfile
  public var stockProfile: FilmStockProfile
  public var resolvedBaseDensity: ResolvedBaseDensity?

  public init(
    captureProfile: CaptureProfile,
    stockProfile: FilmStockProfile,
    resolvedBaseDensity: ResolvedBaseDensity? = nil
  ) {
    self.captureProfile = captureProfile
    self.stockProfile = stockProfile
    self.resolvedBaseDensity = resolvedBaseDensity
  }
}

public enum ProfileResolutionError: Error, Equatable, Sendable {
  case missingCaptureProfile(CaptureProfileID)
  case missingStockProfile(FilmStockProfileID)
  case incompatibleSchemaVersion(Int, supported: Int)
}

public final class ProfileStore: Sendable {
  public let baseDirectory: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  private static let captureProfilesSubdirectory = "CaptureProfiles"
  private static let stockProfilesSubdirectory = "FilmStockProfiles"
  private static let rollProfilesSubdirectory = "RollProfiles"

  public init(baseDirectory: URL) {
    self.baseDirectory = baseDirectory
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
  }

  public init?(appGroupIdentifier: String) {
    guard let base = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first?.appendingPathComponent(appGroupIdentifier) else {
      return nil
    }
    self.baseDirectory = base
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
  }

  private func ensureDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true)
  }

  private func profileURL(
    for id: CaptureProfileID, in directory: URL
  ) -> URL {
    directory.appendingPathComponent("\(id.rawValue).json")
  }

  private func profileURL(
    for id: FilmStockProfileID, in directory: URL
  ) -> URL {
    directory.appendingPathComponent("\(id.rawValue).json")
  }

  private func profileURL(for rollID: String, in directory: URL) -> URL {
    directory.appendingPathComponent("\(rollID).json")
  }

  // MARK: - Capture Profiles

  private var captureProfilesDirectory: URL {
    baseDirectory.appendingPathComponent(Self.captureProfilesSubdirectory)
  }

  public func saveCaptureProfile(_ profile: CaptureProfile) throws {
    try ensureDirectory(captureProfilesDirectory)
    let url = profileURL(for: profile.id, in: captureProfilesDirectory)
    let data = try encoder.encode(profile)
    try data.write(to: url, options: .atomic)
  }

  public func loadCaptureProfile(id: CaptureProfileID) throws -> CaptureProfile? {
    let url = profileURL(for: id, in: captureProfilesDirectory)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let data = try Data(contentsOf: url)
    let profile = try decoder.decode(CaptureProfile.self, from: data)
    try validateSchemaVersion(profile.schemaVersion, supported: 1)
    return profile
  }

  public func listCaptureProfiles() -> [CaptureProfileID] {
    guard let contents = try? FileManager.default.contentsOfDirectory(
      at: captureProfilesDirectory, includingPropertiesForKeys: nil
    ) else {
      return []
    }
    return contents
      .filter { $0.pathExtension == "json" }
      .compactMap {
        CaptureProfileID(rawValue: $0.deletingPathExtension().lastPathComponent)
      }
  }

  // MARK: - Film Stock Profiles

  private var stockProfilesDirectory: URL {
    baseDirectory.appendingPathComponent(Self.stockProfilesSubdirectory)
  }

  public func saveFilmStockProfile(_ profile: FilmStockProfile) throws {
    try ensureDirectory(stockProfilesDirectory)
    let url = profileURL(for: profile.id, in: stockProfilesDirectory)
    let data = try encoder.encode(profile)
    try data.write(to: url, options: .atomic)
  }

  public func loadFilmStockProfile(id: FilmStockProfileID) throws -> FilmStockProfile? {
    let url = profileURL(for: id, in: stockProfilesDirectory)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let data = try Data(contentsOf: url)
    let profile = try decoder.decode(FilmStockProfile.self, from: data)
    try validateSchemaVersion(profile.schemaVersion, supported: 1)
    return profile
  }

  public func listFilmStockProfiles() -> [FilmStockProfileID] {
    guard let contents = try? FileManager.default.contentsOfDirectory(
      at: stockProfilesDirectory, includingPropertiesForKeys: nil
    ) else {
      return []
    }
    return contents
      .filter { $0.pathExtension == "json" }
      .compactMap {
        FilmStockProfileID(rawValue: $0.deletingPathExtension().lastPathComponent)
      }
  }

  // MARK: - Roll Profiles

  private var rollProfilesDirectory: URL {
    baseDirectory.appendingPathComponent(Self.rollProfilesSubdirectory)
  }

  public func saveRollProfile(_ profile: RollProfile) throws {
    try ensureDirectory(rollProfilesDirectory)
    let url = profileURL(for: profile.rollID, in: rollProfilesDirectory)
    let data = try encoder.encode(profile)
    try data.write(to: url, options: .atomic)
  }

  public func loadRollProfile(rollID: String) throws -> RollProfile? {
    let url = profileURL(for: rollID, in: rollProfilesDirectory)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let data = try Data(contentsOf: url)
    var profile = try decoder.decode(RollProfile.self, from: data)
    try validateSchemaVersion(
      profile.schemaVersion, supported: RollProfile.currentSchemaVersion)
    if profile.rollID.isEmpty {
      profile.rollID = rollID
      profile.schemaVersion = RollProfile.currentSchemaVersion
    }
    return profile
  }

  public func loadRollProfiles() throws -> [RollProfile] {
    try ensureDirectory(rollProfilesDirectory)
    let contents = try FileManager.default.contentsOfDirectory(
      at: rollProfilesDirectory, includingPropertiesForKeys: nil
    )
    return try contents
      .filter { $0.pathExtension == "json" }
      .map { url in
        let rollID = url.deletingPathExtension().lastPathComponent
        guard let profile = try loadRollProfile(rollID: rollID) else {
          throw CocoaError(.fileNoSuchFile)
        }
        return profile
      }
  }

  // MARK: - Built-in Profiles

  public func builtInCaptureProfiles() -> [CaptureProfile] {
    [.default]
  }

  public func builtInFilmStockProfiles() -> [FilmStockProfile] {
    [.genericColorNegative, .genericBW]
  }

  // MARK: - Resolution

  public func resolveCaptureProfile(
    id: CaptureProfileID
  ) throws -> CaptureProfile {
    if let stored = try loadCaptureProfile(id: id) {
      return stored
    }
    if let builtIn = builtInCaptureProfiles().first(where: { $0.id == id }) {
      return builtIn
    }
    if id == CaptureProfile.default.id {
      return .default
    }
    throw ProfileResolutionError.missingCaptureProfile(id)
  }

  public func resolveStockProfile(
    id: FilmStockProfileID
  ) throws -> FilmStockProfile {
    if let stored = try loadFilmStockProfile(id: id) {
      return stored
    }
    if let builtIn = builtInFilmStockProfiles().first(where: { $0.id == id }) {
      return builtIn
    }
    throw ProfileResolutionError.missingStockProfile(id)
  }

  public func resolvePipeline(
    captureProfileID: CaptureProfileID,
    stockProfileID: FilmStockProfileID,
    rollProfile: RollProfile? = nil,
    frameMeasurement: BGRChannelValues? = nil,
    automaticBaseDensity: BGRChannelValues? = nil,
    manualBaseDensity: BGRChannelValues? = nil
  ) throws -> ResolvedPipelineProfile {
    let captureProfile = try resolveCaptureProfile(id: captureProfileID)
    let stockProfile = try resolveStockProfile(id: stockProfileID)

    let baseDensity = FilmNegativeProcessing.resolveBaseDensity(
      rollProfile: rollProfile,
      frameMeasurement: frameMeasurement,
      automaticBaseDensity: automaticBaseDensity,
      defaultBaseDensity: nil,
      manualBaseDensity: manualBaseDensity
    )

    return ResolvedPipelineProfile(
      captureProfile: captureProfile,
      stockProfile: stockProfile,
      resolvedBaseDensity: baseDensity
    )
  }

  private func validateSchemaVersion(_ version: Int, supported: Int) throws {
    guard version <= supported else {
      throw ProfileResolutionError.incompatibleSchemaVersion(version, supported: supported)
    }
  }
}
