import CLibRawShim
import Foundation

/// Lifetime extends through every native worker; cancellation only sets an
/// atomic flag and never releases memory still used by LibRaw.
final class RawDecodeCancellation: @unchecked Sendable {
  @TaskLocal static var current: RawDecodeCancellation?
  let handle: OpaquePointer

  init() {
    guard let handle = fsc_raw_cancellation_create() else {
      fatalError("Cannot allocate cancellation flag")
    }
    self.handle = handle
  }
  deinit { fsc_raw_cancellation_free(handle) }
  func cancel() { fsc_raw_cancellation_cancel(handle) }
  var isCancelled: Bool { fsc_raw_cancellation_is_cancelled(handle) != 0 }
  func checkCancellation() throws { if isCancelled { throw CancellationError() } }
}

/// One authoritative decode at a time. Selected work precedes speculative
/// neighbours; cancellation follows the caller through the detached worker and
/// into native strips/wavefronts. Cancelled queued operations never decode.
public actor RawDecodeScheduler {
  public enum Priority: Int, Sendable { case lookahead, selected, export }
  private struct Job: Sendable {
    let priority: Priority
    let cancellation: RawDecodeCancellation
    let perform: @Sendable () -> Void
  }
  private var pending: [Job] = []
  private var active: Job?

  public init() {}

  var queuedRequestCount: Int { pending.count }

  public func run<T: Sendable>(
    priority: Priority = .selected, _ operation: @escaping @Sendable () throws -> T
  ) async throws -> T {
    let token = RawDecodeCancellation()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        pending.append(
          Job(
            priority: priority, cancellation: token,
            perform: {
              let result = Result {
                try token.checkCancellation()
                let value = try RawDecodeCancellation.$current.withValue(token) { try operation() }
                try token.checkCancellation()
                return value
              }
              continuation.resume(with: result)
            }))
        if let active, active.priority == .lookahead, priority != .lookahead {
          active.cancellation.cancel()
        }
        startNextIfIdle()
      }
    } onCancel: {
      token.cancel()
      Task { await self.cancelPending(token) }
    }
  }

  private func cancelPending(_ token: RawDecodeCancellation) {
    guard let index = pending.firstIndex(where: { $0.cancellation === token }) else { return }
    let job = pending.remove(at: index)
    job.perform()  // Only resumes its continuation: the cancelled flag is checked first.
  }

  private func startNextIfIdle() {
    guard active == nil, !pending.isEmpty else { return }
    let index = pending.indices.max {
      pending[$0].priority.rawValue < pending[$1].priority.rawValue
    }!
    let job = pending.remove(at: index)
    active = job
    Task.detached(priority: job.priority == .lookahead ? .utility : .userInitiated) {
      job.perform()
      await self.finished()
    }
  }

  private func finished() {
    active = nil
    startNextIfIdle()
  }
}
