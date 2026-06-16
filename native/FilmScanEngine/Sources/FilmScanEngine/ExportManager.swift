import Foundation
import os

public actor ExportManager {
  public struct ExportRequest: Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let image: UInt16Image
    public let parameters: ExportParameters

    public init(
      sourceURL: URL,
      destinationURL: URL,
      image: UInt16Image,
      parameters: ExportParameters
    ) {
      self.sourceURL = sourceURL
      self.destinationURL = destinationURL
      self.image = image
      self.parameters = parameters
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

    return results.sorted { $0.0 < $1.0 }.map { $0.1 }
  }

  private func exportOne(request: ExportRequest) async -> ExportResult {
    let signpostID = OSSignpostID(log: signpostLog)
    os_signpost(
      .begin, log: signpostLog, name: "Export File",
      signpostID: signpostID,
      "%{public}s", request.sourceURL.lastPathComponent)

    defer {
      os_signpost(
        .end, log: signpostLog, name: "Export File",
        signpostID: signpostID,
        "%{public}s", request.sourceURL.lastPathComponent)
    }

    do {
      try request.image.write(
        to: request.destinationURL,
        format: request.parameters.format,
        parameters: request.parameters
      )

      return ExportResult(
        sourceURL: request.sourceURL,
        destinationURL: request.destinationURL,
        error: nil
      )
    } catch {
      try? FileManager.default.removeItem(at: request.destinationURL)
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
