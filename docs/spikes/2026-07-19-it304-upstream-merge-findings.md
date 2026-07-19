# IT-304 — Upstream SwiftTerm merge into `scape-selection-api`: hunk-by-hunk findings

Date: 2026-07-19
Branch: `304-upstream-swiftterm-merge` (based on `scape-selection-api` @ `d0d66e9`)
Merged: `upstream/main` @ `1a7b5d2` ("Let subclasses customize link and key handling (#599)")
Merge base (fork point): `9446f60`
Divergence at merge time: fork 11 ahead, 42 behind (108 upstream commits since fork point).

This document records **which side won every conflicted hunk and why**, plus the
auto-merged overlaps that needed semantic judgment. It exists so the next merge
doesn't re-litigate our divergence. The fork's deliberate divergences are the
selection API (rectangular/column-block mode), scroll-lock coordination with the
host app, wheel-event handling, and the resize/PTY guards — see fork commits
`1dd10ec`..`d0d66e9`.

## Conflicted files (git-reported conflicts: 4)

### 1. `Sources/SwiftTerm/Apple/AppleTerminalView.swift` — 2 hunks, both in `scroll(toPosition:)`

**Hunk 1 — `maxScrollback` computation.** UPSTREAM WON.
Upstream added a `max(0, …)` clamp (`lines.count - rows` can be negative before
first layout). Strictly better than our unclamped line; no fork behavior
involved.

**Hunk 2 — userScrolling maintenance.** UPSTREAM WON — and it *implements our
fork's intent better than our own code did*.
Our side had `terminal.userScrolling = scrollPosition < 0.999` at the end of
`scroll(toPosition:)` (commit `c04d656`, "expose userScrolling for host-app
scroll-lock coordination"). Upstream (via #587/f971cbf line of work) introduced
`updateUserScrollingState(for:in:)` which computes `row < maxScrollback` and
writes **both** the view-level `userScrolling` and `terminal.userScrolling`, and
is called from `scrollTo(row:)` as well — a path our 0.999 hack never covered
(Scape calls `scrollTo(row:)` directly). Upstream even ships a test asserting
`terminal.userScrolling` is set (`testScrollToMarksTerminalAsUserScrolling`).
The fork's *reason* for the divergence — `terminal.userScrolling` as the public
scroll-lock signal — is preserved: the property stays `public` on `Terminal`
(ours, see Terminal.swift below) and is now maintained on more paths.

### 2. `Sources/SwiftTerm/SelectionService.swift` — 1 hunk in `dragExtend(bufferPosition:)`

**BOTH KEPT (combined).** Ours: early-return branch for
`selectionMode == .rectangular` (drag updates only `end`, no word expansion).
Theirs: new word-anchor pivot branch (`wordSelectionAnchor`) fixing #576 —
double-click-then-drag-backwards previously dropped the seed word. The branches
are mutually exclusive by mode; rectangular is checked first (a rectangular
selection never has a word anchor).

**Deliberate one-line addition beyond conflict resolution:** our fork's
`setSelection(start:end:)` (commit `b97855a`) resets `selectionMode = .character`;
upstream's invariant is that every site resetting mode to `.character` also
clears `wordSelectionAnchor`. Added `wordSelectionAnchor = nil` there to keep
the invariant uniform. Without it the stale anchor is unreachable in practice
(the word branch guards on `.word` mode) but would linger as a trap for any
future caller that sets `.word` mode manually.

Auto-merged in the same file, verified by inspection: our `public class`
visibility, the `.rectangular` enum case, rect branches in `shiftExtend` /
`pivotExtend` / `getSelectedText`, and upstream's `wordSelectionAnchor = nil`
resets in `startSelection` / `setSoftStart` / `select(row:)` / `selectNone`.

### 3. `Sources/SwiftTerm/SyncDebug.swift` — add/add conflict

**UPSTREAM WON (our stub deleted per its own stated plan).**
Both sides independently created this file: the fork point (`9446f60`) shipped
`SyncDebug.log(...)` call sites with no definition; our stub (`1cbf180`,
`4008276`) said in its header *"Drop this file when upstream publishes a real
definition."* Upstream has now published one (compile-time `enabled = false`,
stderr sink) — **and removed every `SyncDebug.log` call site** in the process,
so the type is currently dormant dead code either way (verified: zero call
sites post-merge). Taking upstream's file erases a permanent conflict surface.
What we lose: the `SCAPE_SWIFTTERM_SYNC_DEBUG=1` runtime env-var opt-in — which
no longer had anything to log anyway. If sync diagnostics are needed again,
re-adding call sites will be its own change.

### 4. `Tests/SwiftTermTests/SelectionTests.swift` — 1 hunk (both sides appended at EOF)

**BOTH KEPT.** Ours: the 12 `testRectangular*` / mode-reset tests (`16887ed`,
`b97855a`). Theirs: 2 word-drag regression tests (#576) appended at the same
spot, plus (auto-merged, mid-file) `testScrollToMarksTerminalAsUserScrolling`,
`testSelectionColorsOverrideCellAndDecorationColors`, and an `AppKit` import.

**Assertion-preservation audit** (the merge could damage the tests that police
the merge, so this was checked mechanically, not by eyeball):
- test-method set: post-merge = pre-merge + exactly the 4 upstream tests; zero removed.
- `#expect` assertions: 58 pre-merge → 70 post-merge; `comm -23` of sorted
  assertion texts shows **zero pre-merge assertions missing** post-merge.
- All 37 tests in the suite pass, including all 12 rectangular tests.

## Auto-merged files that still needed judgment

### `Sources/SwiftTerm/Mac/MacTerminalView.swift` (git auto-merged — but wrongly, fixed by hand)

Our fork had **deleted** the view-level `var userScrolling = false` shadow
(part of `c04d656`'s "single source of truth on Terminal" cleanup). Upstream
kept it and its new shared `updateUserScrollingState` (in AppleTerminalView)
assigns to it — the auto-merge honored our deletion, which would not compile on
macOS. **Resolution: restore the view-level property** (upstream's shape) with a
comment. Rationale: keeping the deletion would force `#if os(iOS)` surgery
inside upstream's shared code (iOS has its own functional `userScrolling`),
creating a much worse permanent divergence than one redundant-but-synced Mac
property. `terminal.userScrolling` remains the public API Scape consumes.

Verified intact after auto-merge, ours: `resizeSuspended` (view-level flag),
`optionBypassesMouseReporting` applied at `mouseDown`/`mouseUp`/`mouseDragged`
(Option-drag native selection inside mouse-reporting TUIs), and the full
`scrollWheel` rewrite (notch coalescing via `wheelAccumulatorY`, xterm-style
`alternateScroll` arrow-key fallback, cf. claude-code#42297). Upstream didn't
touch `scrollWheel`.
Theirs, new: macOS 26 per-window mouse-moved fallback registry, selection
auto-scroll timer (`startSelectionAutoScrollTimer`, fixes drag-past-edge
auto-scroll incl. the `scrollUp`→`scrollDown` bug), kitty AltGr composed-text
fix, viewport-row mouse-motion fix, `selectedTextForegroundColor`,
`requestOpenLink`/`openLink` refactor (overridable link handling, #599).

### `Sources/SwiftTerm/Terminal.swift` (clean auto-merge)

Ours kept: `public var userScrolling` (the `public` is our divergence —
upstream has it internal; Scape reads it), `getRectangularText(start:end:buffer:)`
(engine half of rectangular selection), `synchronizedOutputSavedYDisp`.
Theirs merged in: DECSET 1004 focus-state tracking + immediate `sendFocusReport`
on enable, the DECRST 1005/1006/1015/1016 fix (encoding reset no longer kills
mouse *tracking* — the mosh-resize bug), `refreshScrolledRegion` dirty-region
refactor, removal of all `SyncDebug.log` call sites and a stray
`print("\(pixelX);\(pixelY)")`.

### `Sources/SwiftTerm/Mac/MacLocalTerminalView.swift` (clean auto-merge)

Ours kept: degenerate-size guard (`newCols >= 2, newRows >= 1`) before
`TIOCSWINSZ` — protects readline/Tab-completion from SwiftUI's 0×0 sizing pass.
Theirs merged in: overridable `requestOpenLink` (#599). Disjoint regions.

### `Sources/SwiftTerm/Apple/AppleTerminalView.swift` (non-conflicted portions)

Ours kept: `resizeSuspended` early-return in `processSizeChange`, rectangular
branch in the selection-range computation, `feedPrepare` gating
(`allowMouseReporting && !terminal.userScrolling` — don't clear the user's
selection while output streams during scroll-lock), `public typealias CellDimension`.
Theirs merged in: CJK glyph slot centering (`GlyphSlotFit`, #578), selection
foreground/underline/strikethrough color override, `context.clear(dirtyRect)`
restricted-region repaint fix (#582), immediate-display-after-user-input path
(#553/8157b2f) — note its `recordUserInput()` hooks into `send(data:)` which we
did not modify, wide-glyph caret sizing, iOS sub-row scroll fixes.

## Not touched (by design)

- **`Sources/SwiftTerm/Pty.swift` — byte-identical to pre-merge.** Verified:
  `git diff scape-selection-api..HEAD -- Sources/SwiftTerm/Pty.swift` is empty.
  The IT-301 fd-hygiene fix (`bde965d`, `6b064a3`, `25371d2`) is unaffected.
  (Upstream's PTY read-backpressure work, f620c12, landed entirely in
  `LocalProcess.swift`.)

## Verification

- `swift build`: clean.
- `swift test`: **463 tests, 38 suites, all pass** (includes upstream's new
  FocusReportTests, GlyphAtlasTests, KittyOptionComposeTests).
- SelectionTests assertion audit: see §4 above.

## Follow-ups (not done in this merge)

1. `Terminal.synchronizedOutputSavedYDisp` (ours, from `1dd10ec`) is declared
   but never read/written — dead code. Left alone to keep the merge minimal;
   candidate for removal in a cleanup commit.
2. The ticket asks whether the fork's `main` should get a periodic upstream
   sync so the delta never reaches 108 commits again — decision belongs to
   Lloyd/Nash, not this merge.
3. Post-merge, our permanent divergence vs upstream shrinks to: rectangular
   selection (SelectionService/Terminal/AppleTerminalView + tests),
   `public` visibility grants (SelectionService, `Terminal.userScrolling`,
   `search`, `selection`, `cellDimension`, `calculateMouseHit`),
   `optionBypassesMouseReporting`, the `scrollWheel` rewrite, `resizeSuspended`,
   the `feedPrepare` scroll-lock gate, the MacLocal size guard, and the IT-301
   `Pty.swift` fix.
