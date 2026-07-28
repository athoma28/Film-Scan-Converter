struct EditHistory<State: Equatable> {
  struct Entry: Equatable {
    let actionName: String
    let before: State
    let after: State
  }

  private(set) var undoEntries: [Entry] = []
  private(set) var redoEntries: [Entry] = []
  let limit: Int

  init(limit: Int = 100) {
    self.limit = max(1, limit)
  }

  var undoActionName: String? { undoEntries.last?.actionName }
  var redoActionName: String? { redoEntries.last?.actionName }

  mutating func record(actionName: String, before: State, after: State) {
    guard before != after else { return }
    undoEntries.append(Entry(
      actionName: actionName,
      before: before,
      after: after
    ))
    if undoEntries.count > limit {
      undoEntries.removeFirst(undoEntries.count - limit)
    }
    redoEntries.removeAll(keepingCapacity: true)
  }

  mutating func undo() -> Entry? {
    guard let entry = undoEntries.popLast() else { return nil }
    redoEntries.append(entry)
    return entry
  }

  mutating func redo() -> Entry? {
    guard let entry = redoEntries.popLast() else { return nil }
    undoEntries.append(entry)
    return entry
  }
}
