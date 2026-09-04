# IT-794 — Upstream SwiftTerm merge into `scape-selection-api`: reconciliation record

Date: 2026-09-04
Branch: `794-upstream-merge-wheel` (based on `scape-selection-api` @ `a1ed466`)
Merged: `upstream/main` @ `5cb37e8` ("Add support for sending control-space to the remote end")
**Not** the `v1.20.0` tag — the wheel rewrite this merge exists for (#657, `5d3026a`,
2026-09-03) and the parser-perf commits (`4b6cfc6`, `7d3d702`, `ec43534`, `0dd881e`)
all landed AFTER the tag. Divergence at merge time: fork 13 ahead, 277 behind.
Protocol: per-commit reconcile per `docs/spikes/2026-07-19-it304-upstream-merge-findings.md`
(the clean-but-wrong-auto-merge lesson applies twice below).

## Why this merge: the wheel path

The fork's entire `scrollWheel` rewrite is **DROPPED** in favor of upstream #657:

- Fork `wheelAccumulatorY` + 16pt `wheelPreciseNotchPoints` dead-zone + the
  `guard event.deltaY != 0` entry guard (the IT-794 built-in-trackpad suspect)
  → upstream `WheelDistanceAccumulator<WheelRoute>` (cell-height-quantized,
  route-scoped banking, reset on route suppression) + `WheelReportBudget`
  (bounds report/keystroke floods — the claude-code#42297 problem the 16pt
  notch hack approximated) + `scrollSensitivity` (public multiplier, floor
  0.05). Upstream consumes `scrollingDeltaY` (precise-first); its only zero
  check is `scrollingDeltaY == 0`.
- Fork `1f1e997` (wheel forwarding under mouse-reporting/alt-screen)
  → upstream `WheelRoute.mouse` / `.cursorKeys` routes; DECSET 1007
  alternate-scroll handled natively; `Shift`/`Option` request local handling.
- Coverage: upstream `WheelReportBudgetTests` + expanded `AlternateScrollModeTests`.

## Conflicted files (7) — resolutions

1. **MacTerminalView.swift** — class decl: upstream shape (NSTextInputClient
   moved to a bottom extension) + our `resizeSuspended` kept. `selection`:
   ours (`public`). mouseDown/mouseUp/mouseDragged: upstream's new
   semantic-click/withTerminal bodies with our `optionBypassesMouseReporting`
   gate re-inserted at all three sites. Wheel region: upstream wholesale (see
   above); git's conflict hunks interleaved our code with upstream's
   *commented-out legacy handler* (near-identical text), so the whole region
   was replaced from `git show 5cb37e8:` byte-for-byte rather than resolved
   hunk-by-hunk. Post-resolution `diff` vs pure upstream = exactly the
   intended fork surface.
2. **AppleTerminalView.swift** — `CellDimension` typealias: upstream position,
   our `public`. `selectedColumnsRange`: upstream's refactor moved the body
   into `SelectionService`; took the delegation and moved our rectangular
   branch into the service helper (single source). `scroll(toPosition:)`:
   upstream (no fork logic since IT-304). `feedPrepareLocked`: upstream —
   upstream deleted feed-time selection clearing entirely, which is a strict
   superset of our `allowMouseReporting && !userScrolling` preserve-selection
   gate; the gate is now meaningless and was dropped. `startDisplayUpdates()`
   no longer exists upstream (frameDriver architecture).
3. **BufferLine.swift** — upstream wholesale; our only delta (`isWrapped`
   `public internal(set)`) is now upstream's own shape.
4. **MacLocalTerminalView.swift** — kept our degenerate-size guard
   (`newCols >= 2, newRows >= 1` before TIOCSWINSZ). Ceded the old
   `guard process.running` to upstream (`process.updateWindowSize(&size)`
   returns Bool and is guarded at the call).
5. **SearchService.swift** — ours `public final class` + upstream's
   terminalLock doc comment. NOTE for Scape-side: upstream now documents
   "callers must hold `terminal.terminalLock`" — re-verify Scape's
   find-in-terminal call path in Phase 3.
6. **SelectionService.swift** — upstream added a `.row` selection mode with
   branches at the same three sites as our `.rectangular` branches
   (shiftExtend / pivotExtend / dragExtend); both kept, rectangular checked
   first (a rectangular selection never has row/word anchors). Our
   `setSelection` `.character` reset kept and extended: now also clears
   upstream's new `rowSelectionAnchor` (same uniformity argument as IT-304's
   `wordSelectionAnchor = nil` addition).
7. **Terminal.swift** — dropped `synchronizedOutputSavedYDisp` (declared-dead
   since IT-304 §Follow-ups; zero references verified pre-drop).

## Clean-but-wrong auto-merges caught (the IT-304 lesson, twice)

- **`getRectangularText` landed inside `ViewTerminal`.** Upstream appended a
  new `ViewTerminal: Terminal` subclass at Terminal.swift EOF; git anchored
  our end-of-class addition inside it. `SelectionService.terminal` is typed
  `Terminal`, so this FAILED at compile (lucky, loud). Moved into `Terminal`.
- **`queueSizeChange` bypassed `resizeSuspended`.** Upstream added a second
  resize entry point (coalesced live-drag path; `setFrameSize` routes to it
  whenever `inLiveResize`). Auto-merge kept our guard only on
  `processSizeChange`, so a suspended (hidden) view resized during a window
  live-drag would have reintroduced the content-duplication bug. This one
  COMPILED and would have shipped. Guard added to `queueSizeChange`.

## API surface changes affecting Scape (Phase 3 checklist)

- **`getTerminal()` is GONE upstream** (mutable terminal deliberately hidden
  behind `terminalLock`; new IO pipeline mutates it off-main). Fork grant:
  `withTerminal` widened to `public` instead of re-adding the racy accessor.
  Scape has 7 `getTerminal()` call sites to migrate (`ScapeTerminalView` ×4,
  `TerminalClickHandler`, `TerminalSession` ×2). CAUTION: `terminalLock` is
  NOT re-entrant — a delegate callback that already holds the lock
  (e.g. `send(source:data:)` from the parser) must NOT call `withTerminal`.
- `ScapeTerminalView.scrollWheel`'s comment block about fork wheel branches
  is stale — `userScrolling` maintenance re-verify against `WheelRoute`.
- Upstream maintains `userScrolling` on more paths now
  (`updateUserScrollingStateLocked` from `scrollTo`/`scroll(toPosition:)`);
  `terminal.userScrolling` stays `public` (ours).
- `SearchService` lock contract (see §5).
- Verified still present/overridable: `scrollPosition`, `scrollTo(row:)`,
  `scrollUp/Down(lines:)`, `open send(source:data:)`, `open bufferActivated`,
  `override viewWillDraw`, `setNeedsDisplay`, `LocalProcessTerminalView`
  (`shellPid`, `running`), `calculateMouseHit` ×2, `SearchResult` fields,
  `selection`/`search`/`cellDimension` grants, rect-selection API, `resizeSuspended`.

## Not touched (by design)

- **`Pty.swift` IT-301 fd hygiene intact, verified by symbol**: pre-fork
  `getdtablesize()` bound + `close`-loop in the forkpty child survive; the
  merge only appended upstream's `terminalControlBytesForPaste` helper.
  `ScapeTests/PipeFDInheritanceTests` re-verifies at the Phase-3 pin bump.
- README fork-note (push discipline) intact.

## Verification

- `swift build`: clean.
- `swift test`: **1332 tests, 115 suites, all pass** (3 runs; run 1 reported
  "1 issue" that never reproduced in runs 2–3 — transient, identity unknown
  because the first run's log was truncated; runs 2–3 fully green, run 3
  includes every post-conflict fix in this record).
- SelectionTests: 9 `testRectangular*` + mode-reset tests present and green.

## Follow-ups

- Phase 2 (IT-794): trace built-in trackpad with Scape's `SCAPE_SCROLL_TRACE`
  on the merged base; tune `scrollSensitivity` only if the trace shows a gap.
- Fork `main` periodic-sync question from IT-304 remains open (Lloyd/Nash).
