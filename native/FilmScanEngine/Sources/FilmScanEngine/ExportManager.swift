import Foundation
import os

public actor ExportManager {
  public struct ExportRequest: Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let image: UInt16Image
    public let parameters: ExportParameters
    public let correlationID: String

    public init(
      sourceURL: URL,
      destinationURL: URL,
      image: UInt16Image,
      parameters: ExportParameters,
      correlationID: String = UUID().uuidString
    ) {
      self.sourceURL = sourceURL
      self.destinationURL = destinationURL
      self.image = image
      self.parameters = parameters
      self.correlationID = correlationID
    }
  }

  public struct ExportResult: Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let error: Error?

    public var isSuccess: Bool { error == nil }

    public init(sourceURL: URL, destinationURL: URL, error: Error?) {
      self.sourceURL = sourceURL
      self.destinationURL = destinationURL
      self.error = error
    }
  }

  public enum ExportManagerError: Error, LocalizedError, Equatable {
    case cancelled
    case noImages
    case insufficientMemory(Int, Int)
    case invalidDestination(URL)

    public var errorDescription: String? {
      switch self {
      case .cancelled: "Export cancelled."
      case .noImages: "No images to export."
      case .insufficientMemory(let needed, let available):
        "Insufficient memory: need \(needed) MB, have \(available) MB."
      case .invalidDestination(let url):
        "Cannot write to \(url.path)"
      }
    }
  }

  private let signpostLog = OSLog(
    subsystem: "film.scan.converter", category: "Export")

  public init() {}

  public func export(
    requests: [ExportRequest],
    progress: (@Sendable (Int, Int, Bool) -> Void)? = nil
  ) async -> [ExportResult] {
    var results: [ExportResult] = []

    for (index, request) in requests.enumerated() {
      if Task.isCancelled {
        for remaining in requests[index...] {
          results.append(
            ExportResult(
              sourceURL: remaining.sourceURL,
              destinationURL: remaining.destinationURL,
              error: ExportManagerError.cancelled
            ))
        }
        return results
      }

      let result = await exportOne(request: request)
      results.append(result)
      progress?(index + 1, requests.count, result.isSuccess)
    }

    return results
  }

  public func exportBatch(
    requests: [ExportRequest],
    maxConcurrent: Int? = nil,
    progress: (@Sendable (Int, Int, Bool) -> Void)? = nil
  ) async -> [ExportResult] {
    guard !requests.isEmpty else {
      return []
    }

    let concurrency = boundedConcurrency(
      requested: maxConcurrent,
      totalImages: requests.count
    )

    let sorted = requests.enumerated().sorted {
      estimatedMemory($0.element.image) > estimatedMemory($1.element.image)
    }

    var results = [(Int, ExportResult)]()
    var completed = 0
    let total = requests.count

    await withTaskGroup(of: (Int, ExportResult).self) { group in
      var iterator = sorted.makeIterator()

      for _ in 0..<min(concurrency, total) {
        guard let (index, request) = iterator.next() else { break }
        group.addTask {
          let result = await self.exportOne(request: request)
          return (index, result)
        }
      }

      for await (index, result) in group {
        results.append((index, result))
        completed += 1
        progress?(completed, total, result.isSuccess)

        if !Task.isCancelled, let (nextIndex, nextRequest) = iterator.next() {
          group.addTask {
            let result = await self.exportOne(request: nextRequest)
            return (nextIndex, result)
          }
        }
      }
    }

    if results.count < total {
      let completedIndices = Set(results.map(\.0))
      for (index, request) in requests.enumerated() where !completedIndices.contains(index) {
        results.append(
          (
            index,
            ExportResult(
              sourceURL: request.sourceURL,
              destinationURL: request.destinationURL,
              error: ExportManagerError.cancelled
            )
          ))
        completed += 1
        progress?(completed, total, false)
      }
    }

    return results.sorted { $0.0 < $1.0 }.map { $0.1 }
  }

  private func exportOne(request: ExportRequest) async -> ExportResult {
    guard !Task.isCancelled else {
      return ExportResult(
        sourceURL: request.sourceURL,
        destinationURL: request.destinationURL,
        error: ExportManagerError.cancelled
      )
    }

    let signpostID = OSSignpostID(log: signpostLog)
    os_signpost(
      .begin, log: signpostLog, name: "Export File",
      signpostID: signpostID,
      "file=%{public}s correlation=%{public}s",
      request.sourceURL.lastPathComponent, request.correlationID)

    defer {
      os_signpost(
        .end, log: signpostLog, name: "Export File",
        signpostID: signpostID,
        "file=%{public}s correlation=%{public}s",
        request.sourceURL.lastPathComponent, request.correlationID)
    }

    let writeID = OSSignpostID(log: signpostLog)
    os_signpost(
      .begin, log: signpostLog, name: "Write and Finalize",
      signpostID: writeID,
      "file=%{public}s correlation=%{public}s",
      request.sourceURL.lastPathComponent, request.correlationID)
    do {
      try request.image.write(
        to: request.destinationURL,
        format: request.parameters.format,
        parameters: request.parameters
      )
      os_signpost(
        .end, log: signpostLog, name: "Write and Finalize",
        signpostID: writeID,
        "file=%{public}s correlation=%{public}s",
        request.sourceURL.lastPathComponent, request.correlationID)

      return ExportResult(
        sourceURL: request.sourceURL,
        destinationURL: request.destinationURL,
        error: nil
      )
    } catch {
      os_signpost(
        .end, log: signpostLog, name: "Write and Finalize",
        signpostID: writeID,
        "file=%{public}s correlation=%{public}s",
        request.sourceURL.lastPathComponent, request.correlationID)
      let cleanupID = OSSignpostID(log: signpostLog)
      os_signpost(
        .begin, log: signpostLog, name: "Cleanup",
        signpostID: cleanupID,
        "file=%{public}s correlation=%{public}s",
        request.sourceURL.lastPathComponent, request.correlationID)
      try? FileManager.default.removeItem(at: request.destinationURL)
      os_signpost(
        .end, log: signpostLog, name: "Cleanup",
        signpostID: cleanupID,
        "file=%{public}s correlation=%{public}s",
        request.sourceURL.lastPathComponent, request.correlationID)
      return ExportResult(
        sourceURL: request.sourceURL,
        destinationURL: request.destinationURL,
        error: error
      )
    }
  }

  private func boundedConcurrency(
    requested: Int?,
    totalImages: Int
  ) -> Int {
    if let requested, requested > 0 {
      return min(requested, totalImages)
    }
    let processorCount = ProcessInfo.processInfo.activeProcessorCount
    let memoryBased = safeParallelImageCount()
    return min(processorCount, memoryBased, totalImages)
  }

  private func safeParallelImageCount() -> Int {
    let physicalBytes = ProcessInfo.processInfo.physicalMemory
    let physicalMB = Int(physicalBytes) / (1024 * 1024)
    if physicalMB > 16384 {
      return ProcessInfo.processInfo.activeProcessorCount
    } else if physicalMB > 8192 {
      return min(ProcessInfo.processInfo.activeProcessorCount, 4)
    } else if physicalMB > 4096 {
      return min(ProcessInfo.processInfo.activeProcessorCount, 2)
    } else {
      return 1
    }
  }

  private func estimatedMemory(_ image: UInt16Image) -> Int {
    image.width * image.height * image.channels * 2
  }
}
