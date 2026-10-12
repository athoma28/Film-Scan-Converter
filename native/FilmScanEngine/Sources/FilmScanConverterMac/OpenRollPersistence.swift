import Foundation

/// Coalesces browsing snapshots into one mailbox and writes off the main actor.
/// Failed saves retain the latest state for a subsequent submit or flush retry.
final class OpenRollPersistence: @unchecked Sendable {
  private struct Waiter {
    let revision: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private var pending: OpenRollStore.State?
  private var revision: UInt64 = 0
  private var savedRevision: UInt64 = 0
  private var pendingSince: DispatchTime?
  private var flushRequested = false
  private var waiters: [Waiter] = []
  // Only the serial queue accesses the last attempted state.
  private var state: OpenRollStore.State?
  private let queue = DispatchQueue(label: "FilmScanConverter.open-roll-persistence", qos: .utility)
  private let timer: DispatchSourceTimer
  private let debounceNanoseconds: UInt64
  private let maximumDelayNanoseconds: UInt64
  private let save: @Sendable (OpenRollStore.State) throws -> Void
  private let onCompletion: @Sendable (UInt64, Result<Void, Error>) -> Void

  init(
    debounce: TimeInterval = 0.3,
    maximumDelay: TimeInterval = 2,
    save: @escaping @Sendable (OpenRollStore.State) throws -> Void,
    onCompletion: @escaping @Sendable (UInt64, Result<Void, Error>) -> Void = { _, _ in }
  ) {
    debounceNanoseconds = UInt64(max(0, debounce) * 1_000_000_000)
    maximumDelayNanoseconds = UInt64(max(0, maximumDelay) * 1_000_000_000)
    self.save = save
    self.onCompletion = onCompletion
    timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .distantFuture)
    timer.setEventHandler { [weak self] in self?.writePendingState() }
    timer.resume()
  }

  deinit { timer.cancel() }

  @discardableResult
  func submit(_ state: OpenRollStore.State) -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    revision += 1
    pending = state
    scheduleLocked()
    return revision
  }

  func requestFlush() {
    lock.lock()
    defer { lock.unlock() }
    guard savedRevision < revision else { return }
    flushRequested = true
    scheduleLocked()
  }

  /// Waits for every snapshot submitted before this call. Later snapshots can
  /// supersede it; a caller ending the session also checks `hasUnsavedChanges`.
  func flush() async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if savedRevision >= revision {
        lock.unlock()
        continuation.resume()
        return
      }
      waiters.append(Waiter(revision: revision, continuation: continuation))
      flushRequested = true
      scheduleLocked()
      lock.unlock()
    }
  }

  var hasUnsavedChanges: Bool {
    lock.lock()
    defer { lock.unlock() }
    return savedRevision < revision
  }

  var pendingSnapshotCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return pending == nil ? 0 : 1
  }

  private func scheduleLocked() {
    let now = DispatchTime.now()
    if pendingSince == nil { pendingSince = now }
    let deadline: DispatchTime
    if flushRequested {
      deadline = now
    } else {
      deadline = DispatchTime(
        uptimeNanoseconds: min(
          now.uptimeNanoseconds + debounceNanoseconds,
          pendingSince!.uptimeNanoseconds + maximumDelayNanoseconds))
    }
    timer.schedule(deadline: deadline, leeway: .milliseconds(5))
  }

  private func writePendingState() {
    lock.lock()
    timer.schedule(deadline: .distantFuture)
    guard savedRevision < revision else {
      flushRequested = false
      pendingSince = nil
      lock.unlock()
      return
    }
    guard flushRequested || pending != nil else {
      lock.unlock()
      return
    }
    let nextState = pending
    let writingRevision = revision
    pending = nil
    pendingSince = nil
    flushRequested = false
    lock.unlock()

    if let nextState { state = nextState }
    // An unsaved revision always has either a pending or previously attempted
    // snapshot. The latter is retained when storage fails.
    guard let state else { return }
    let result: Result<Void, Error>
    do {
      try save(state)
      result = .success(())
    } catch {
      result = .failure(error)
    }
    lock.lock()
    if case .success = result { savedRevision = writingRevision }
    let completed = waiters.filter { $0.revision <= writingRevision }
    waiters.removeAll { $0.revision <= writingRevision }
    lock.unlock()
    onCompletion(writingRevision, result)
    for waiter in completed { waiter.continuation.resume(with: result) }
  }
}
