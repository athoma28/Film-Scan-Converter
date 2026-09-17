# Coalesced settings persistence

The September 13 follow-up's settings stall is addressed by
`PerFileSettingsPersistence`. The main actor updates its current settings and
replaces one per-file delta in a locked mailbox. A serial utility queue owns a
separate history dictionary and performs both JSON encoding and atomic writes.
The on-disk version-two JSON format and version-one migration remain unchanged.

The mailbox retains at most one pending operation per changed path plus one
reset marker. Revisions include set, removal, edited-state changes, and reset.
Changes arriving during a write remain in that mailbox for the next write; they
never enqueue additional full dictionary snapshots or encodes.

Keyboard and text changes debounce for 300 ms. A continuous gesture schedules
a save within two seconds of its first pending change, subject to background
queue and filesystem delay. Gesture release, editor/selection transitions, and
batch look application request an immediate save. Orderly application quit
awaits all current edits, including any arriving during a write. A save failure
reports an error, retains the unsaved state for retry, and cancels orderly quit.
Successful retries clear that persistence error without replacing unrelated
status messages. Revision checks ignore stale background completion callbacks,
including a delayed failure from before a successful retry of the same edit.

An abrupt crash or force quit can lose edits received since the last successful
write. Normally the pending window is 300 ms after an isolated edit or up to two
seconds during continuous input, plus scheduling/encoding/I/O time; this is not
a hard durability guarantee. Failures extend the window until a later successful
edit-triggered or explicit flush. Removing/replacing the JSON file externally
while the app is open is not a supported synchronization mechanism.

Focused tests cover coalescing, revision order, reset/removal, changes arriving
during a blocked write, off-main save execution, retry, debounce, periodic saves,
gesture release, undo/reset, and flush/relaunch. The 640-entry synthetic history
test times 120 actual AppModel setters without decoding or rendering images;
its reported timings are a local event-handler check, not live-frame cadence or
a stable performance threshold. Existing persistence assertions explicitly await
the same flush barrier used for orderly termination.
