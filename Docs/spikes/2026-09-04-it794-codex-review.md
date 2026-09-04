# IT-794 Codex review — merge result

Date: 2026-09-04

Reviewed merge `57bbd81` against both parents (`a1ed466` and upstream
`5cb37e8`), beginning with the reconciliation record. This review enumerated
the fork-only surface from the actual `5cb37e8..57bbd81` diff and checked the
dropped wheel/feed behavior, the relocated selection behavior, the resize
guards, and the Pty child close loop against their current call sites.

## Verdict: BLOCKER

### 1. Dropping the fork wheel handler loses unconditional alternate-screen wheel forwarding

`Sources/SwiftTerm/Mac/MacTerminalView.swift:3867-3868`

The reconciliation record says the fork's alternate-screen wheel forwarding
is superseded by upstream's `.cursorKeys` route / native DECSET 1007 handling.
Those behaviors are not equivalent.

The fork at `a1ed466` routed wheel events to Up/Down whenever
`terminal.isCurrentBufferAlternate` was true (after the mouse-reporting path),
without consulting alternate-scroll mode. The merge result returns
`.cursorKeys` only when both `terminal.isDisplayBufferAlternate` and
`terminal.alternateScrollMode` are true; otherwise it returns `.none` and drops
the event. Consequently an alternate-screen program that does not enable
DECSET 1007, including ordinary pager configurations the fork explicitly
supported, no longer receives wheel-derived cursor keys. The upstream DECSET
1007 implementation covers protocol-correct alternate scroll, but it does not
cover the fork's unconditional compatibility fallback.

Concrete failure: wheel input over an alternate-screen pager/TUI with mouse
reporting off and DECSET 1007 off is ignored instead of moving Up/Down. This is
a dropped fork behavior in the principal IT-794 path and needs an explicit
product decision or restoration, not a “superseded” classification.

### 2. Selection auto-scroll mutates lock-guarded selection state outside `terminalLock`

`Sources/SwiftTerm/Mac/MacTerminalView.swift:3320-3322`

`scrollingTimerElapsed()` reads `selection.active`, then calls
`calculateMouseHit(at:)` (which briefly takes and releases `terminalLock`), and
then calls `selection.dragExtend(...)` after that lock has been released.
`SelectionService.swift:16` states that all selection state is guarded by
`terminal.terminalLock`. The new IO pipeline mutates the terminal off-main, so
`@MainActor` does not serialize this timer with terminal/parser work.

Concrete failure: while edge-drag auto-scroll is active, feed-time buffer
mutation/reflow/selection adjustment can race the timer's selection read and
write. The timer can extend against a different buffer state than the hit test,
lose a concurrent selection adjustment, or expose inconsistent start/end data
to rendering. This path should perform the active check, hit calculation, and
drag extension in one `withTerminal` critical section (while leaving viewport
scroll/delegate work outside as required).

This bug is present in upstream `5cb37e8` rather than introduced by a conflict
hunk, but it is a release blocker for this merge because the merge adopts the
off-main/non-reentrant locking architecture and the fork relies on selection
edge dragging.

## Confirmed reconciliations

- Rectangular selection is present at all fork sites: range calculation,
  shift/pivot/drag extension, mode declaration, and text extraction. Its range
  calculation is correctly hosted in `SelectionService.selectedColumnsRange`.
- `setSelection` resets `.character`, `wordSelectionAnchor`, and upstream's
  `rowSelectionAnchor`.
- Option bypass is present at mouse press, drag, and release. Each check occurs
  while `terminalLock` is held in the new handlers.
- Upstream's removal of feed-time selection clearing does preserve selection
  in every case covered by the fork's former conditional clear.
- Both resize entry points (`queueSizeChange` and `processSizeChange`) honor
  `resizeSuspended`.
- IT-301 Pty hygiene survives intact: `getdtablesize()` is sampled before
  `forkpty`, and the child closes every fd in `3..<fdLimit` before `execve`.
  Upstream's paste-control helper is additive and does not intersect the spawn
  path.

## Non-blocking notes

- The public `withTerminal` API accurately warns that the lock is
  non-reentrant. Host migration must not call it from terminal delegate
  callbacks already made under `terminalLock`.
- Public `SearchService` methods retain the upstream requirement that callers
  already hold `terminalLock`; Scape's Phase 3 migration must wrap its external
  search calls in `withTerminal` rather than calling `view.search.find*`
  directly.
