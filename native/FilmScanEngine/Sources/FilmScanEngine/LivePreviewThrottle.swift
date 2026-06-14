public struct LivePreviewThrottle: Sendable {
  public let maximumFramesPerSecond: Double
  private var lastAcceptedTimestamp: Double?

  public init(maximumFramesPerSecond: Double = 20) {
    precondition(maximumFramesPerSecond > 0, "Frame rate must be positive")
    self.maximumFramesPerSecond = maximumFramesPerSecond
  }

  public mutating func shouldProcess(timestamp: Double) -> Bool {
    guard let lastAcceptedTimestamp else {
      self.lastAcceptedTimestamp = timestamp
      return true
    }

    let elapsed = timestamp - lastAcceptedTimestamp
    guard elapsed < 0 || elapsed >= 1 / maximumFramesPerSecond else {
      return false
    }
    self.lastAcceptedTimestamp = timestamp
    return true
  }
}
