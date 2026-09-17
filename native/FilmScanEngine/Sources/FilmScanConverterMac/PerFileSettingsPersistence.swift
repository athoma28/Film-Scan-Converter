import FilmScanEngine
import Foundation

/// Owns the saved dictionary on a serial utility queue. The event handler only
/// replaces one mailbox entry; it never snapshots or encodes the full history.
///
/// Uninterrupted edits attempt a save at least every two seconds. An abrupt
/// process exit can lose pending edits (and edits received during a slow write).
/// Gesture release requests an immediate save; orderly quit awaits `flush()`.
final class PerFileSettingsPersistence: @unchecked Sendable {
  enum Change: Sendable {
    case set(path: String, parameters: ProcessingParameters, edited: Bool)
    case remove(path: String)
    case reset
  }

  private struct RevisionedChange {
    let revision: UInt64
    let change: Change
  }

  private struct Waiter {
    let revision: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  // Mailbox fields are protected by lock. `state` belongs exclusively to queue.
  private let lock = NSLock()
  private var pending: [String: RevisionedChange] = [:]
  private var pendingResetRevision: UInt64?
  private var revision: UInt64 = 0
  private var savedRevision: UInt64 = 0
  private var pendingSince: DispatchTime?
  private var flushRequested = false
  private var waiters: [Waiter] = []
  private var state: PerFileSettingsStore.State
  private let queue = DispatchQueue(label: "FilmScanConverter.settings-persistence", qos: .utility)
  private let timer: DispatchSourceTimer
  private let debounceNanoseconds: UInt64
  private let maximumDelayNanoseconds: UInt64
  private let save: @Sendable (PerFileSettingsStore.State) throws -> Void
  private let onFailure: @Sendable (Error) -> Void
  private let onCompletion: @Sendable (UInt64, Result<Void, Error>) -> Void

  init(
    initialState: PerFileSettingsStore.State,
    debounce: TimeInterval = 0.3,
    maximumDelay: TimeInterval = 2,
    save: @escaping @Sendable (PerFileSettingsStore.State) throws -> Void,
    onFailure: @escaping @Sendable (Error) -> Void = { _ in },
    onCompletion: @escaping @Sendable (UInt64, Result<Void, Error>) -> Void = { _, _ in }
  ) {
    // Detach the outer collections once at startup, so a first slider edit does
    // not pay a history-sized copy-on-write cost on the main actor.
    state = .init(
      settingsByPath: initialState.settingsByPath.reduce(into: [:]) { $0[$1.key] = $1.value },
      editedPaths: initialState.editedPaths.reduce(into: []) { $0.insert($1) })
    debounceNanoseconds = UInt64(max(0, debounce) * 1_000_000_000)
    maximumDelayNanoseconds = UInt64(max(0, maximumDelay) * 1_000_000_000)
    self.save = save
    self.onFailure = onFailure
    self.onCompletion = onCompletion
    timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .distantFuture)
    timer.setEventHandler { [weak self] in self?.writePendingChanges() }
    timer.resume()
  }

  deinit { timer.cancel() }

  /// Revisions are assigned under the mailbox lock, including remove/reset.
  /// A reset discards every earlier pending delta; later sets survive it.
  @discardableResult
  func submit(_ change: Change) -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    revision += 1
    switch change {
    case .set(let path, _, _), .remove(let path):
      pending[path] = RevisionedChange(revision: revision, change: change)
    case .reset:
      pending.removeAll(keepingCapacity: true)
      pendingResetRevision = revision
    }
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

  /// Waits until all revisions submitted before this call are on disk. A failed
  /// save throws but retains the writer's state for the next edit/flush to retry.
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

  /// Also useful for checking that input rate cannot grow the work queue.
  var pendingChangeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return pending.count + (pendingResetRevision == nil ? 0 : 1)
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
    // Rescheduling one source avoids a queued task/work item for every event.
    timer.schedule(deadline: deadline, leeway: .milliseconds(5))
  }

  private func writePendingChanges() {
    lock.lock()
    timer.schedule(deadline: .distantFuture)
    guard savedRevision < revision else {
      flushRequested = false
      pendingSince = nil
      lock.unlock()
      return
    }
    guard flushRequested || !pending.isEmpty || pendingResetRevision != nil else {
      lock.unlock()
      return
    }
    let changes = pending
    let resetRevision = pendingResetRevision
    let writingRevision = revision
    pending = [:]
    pendingResetRevision = nil
    pendingSince = nil
    flushRequested = false
    lock.unlock()

    if resetRevision != nil { state = .init(settingsByPath: [:], editedPaths: []) }
    for entry in changes.values {
      // Only later deltas survive a reset, even if producer ordering changes.
      if let resetRevision, entry.revision <= resetRevision { continue }
      switch entry.change {
      case .set(let path, let parameters, let edited):
        state.settingsByPath[path] = parameters
        if edited { state.editedPaths.insert(path) } else { state.editedPaths.remove(path) }
      case .remove(let path):
        state.settingsByPath.removeValue(forKey: path)
        state.editedPaths.remove(path)
      case .reset:
        break  // A reset is represented by pendingResetRevision, never a path.
      }
    }

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
    if case .failure(let error) = result { onFailure(error) }
    onCompletion(writingRevision, result)
    for waiter in completed { waiter.continuation.resume(with: result) }
  }
}
