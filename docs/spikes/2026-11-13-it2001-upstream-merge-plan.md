# IT-2001: plan for merging upstream SwiftTerm into `scape-selection-api`

Date: 2026-11-13. Nash said go. This is the plan a builder follows in a fresh worktree; this branch stays docs only. Evidence is in `2026-11-13-it2001-upstream-merge-scoping-findings.md` ("the findings"). Tags: **[M]** measured (source named), **[I]** inferred.

Merge target: upstream `d4f52faaa` into fork `1b21b1bf3` (base `5cb37e865`; 12 conflicted files, 27 hunks). If upstream has moved when the builder starts, the builder still merges `d4f52faaa`; newer commits wait for the next sync.

## 1. Outcome and order

1. **Fork PR A (prep, on today's base, no behaviour change):** delete `TerminalReplayStream.swift`; replace the access widenings with one accessor block per class; the parser hook as one function.
2. **Fork PR B (the merge, the format revision and the three proofs: one review).**
3. **Scape pin-bump PR**, after PR B is merged into `scape-selection-api` **as a merge commit**, so the pinned SHA is reachable from that branch. (A squash or rebase leaves the tested SHA unreachable; that was missed once today.)
4. **Scape PR #1289 (S2.3, the session host) re-gates on the bumped pin.** It does not merge on the old pin.
5. Nash's hands-on check (section 9).

## 2. The condition on the session host, and the fallback

Scape PR #1289 ("tether", S2.3, on hold at `46faf0eff`, base `loom-1149-s21`) is already written on `HeadlessTerminal` **[M]** (`gh pr diff 1289`). It merges only after the pin bump.

**SwiftTerm API it uses, which PR B must keep with the same shape** (all **[M]** from its diff; "upstream" says what the merge target has):

| API | Note |
|---|---|
| `HeadlessTerminal(queue:options:onEnd:)`, `.terminal`, `.process`, `.send(data:)` | upstream adds defaulted `directDelivery:` and `onLaunchFailure:` before `onEnd`; the trailing-closure call still fits **[I]** |
| `HeadlessTerminal.onOutput` | fork-owned; called after the feed, on the feeding thread, under `terminalLock`. Merged cleanly into the right place. |
| `LocalProcess.startProcess(executable:args:environment:…)`, `.shellPid`, `.childfd` | unchanged upstream. #1289 duplicates `childfd` for its own resizes. |
| `PseudoTerminalHelpers.setWinSize(masterPtyDescriptor:windowSize:)` | unchanged |
| `TerminalOptions(cols:rows:scrollback:)` | unchanged **[I]** |
| `Terminal.terminalLock`, `.rows`, `.cols`, `.resize(cols:rows:)`, `.feed(byteArray:)`, `.getLine(row:)` | unchanged |
| `Terminal.synchronizedOutputTimeout` (set to `nil`), `.synchronizedOutputActive` | fork-owned |
| `Terminal.expireSynchronizedOutput() -> Bool` | #1289 uses the result in a `guard`. Upstream has a `Void` version of the same name. **The `Bool` version is the one kept.** |
| `Terminal.pendingParserBytes` (`nil` = wait), `.respondsToQueries` | fork-owned |
| `Terminal.exportForStreaming()`, `TerminalStreamingExport.screen.encoded()`, `.historyChunks(linesPerChunk:)`, chunk `.encoded()` | fork-owned; the encoded bytes become format v2 |
| `TerminalStateSnapshot(encoded:)`, `importState(_:)`, `TerminalHistoryChunk(encoded:)`, `importHistoryChunk(_:) -> Bool` | fork-owned |
| `@_spi(Replication) replicationDigest()` | fork-owned; tests only |

Two things the merge changes for #1289, to be handled when it re-gates, not in PR B:

- Upstream's `LocalProcess.updateWindowSize(_:)` is `public` (it is internal in the fork) **[M]**. #1289's comment names exactly this as what would let it drop its duplicated descriptor and the one race window it documents. Optional follow-up for the daemon lead.
- Upstream's `HeadlessTerminal.processTerminated` now changes program-status state under the lock before `onEnd`, and a failed launch is written into the terminal as text through `dataReceived`, so it passes `onOutput` and lands in the ring as ordinary output **[M]**. #1289 treats the termination callback as status only; that still holds.

**Fallback checkpoint.** The call is made by Lloyd at whichever comes first:

- the moment #1289 has everything it needs except the pin, or
- the end of working day 5 of the merge lane.

If at that moment PR B has not passed its own gate (section 8, fork rows), the fallback is option B of the findings: #1289 merges on the old pin, the merge lane continues, and the pin bump lands **before S2.4 starts**. In that case format v2 still lands with the pin bump and #1289's fixtures are regenerated then. Nothing else in this plan changes.

## 3. Decisions (each with its test)

| # | Decision | Test that pins it |
|---|---|---|
| D1 | **Block selection is upstream's**: `SelectionService.isBlock`, `startBlockSelection(bufferPosition:)`, the held-Option press. The fork's `SelectionMode.rectangular`, its branches, `optionBypassesMouseReporting` and `Terminal.getRectangularText` are deleted. | Upstream's block-selection tests pass unmodified; the fork's 9 `testRectangular*` tests are deleted in the same commit, and the commit message lists them. The fork's mode-reset tests for `setSelection` stay, extended to assert `isBlock == false`. |
| D2 | **Sync-end is upstream's** (`a329fc7`: latest value applied at the frame tick). The fork's `synchronizedOutputEnded` event and its drain branch are deleted. **Title coalescing is kept, re-expressed on the same mechanism**: the latest title is stored in the view's cross-thread state and applied in `applyPendingViewUpdates`; no per-title main-queue block. `TerminalEvent` keeps upstream's numbering. | `MainHopCoalescingTests` rewritten: N title changes and N sync-ends between two frame ticks cause one delegate call each, with the last value. `FrameDriverTests` (upstream) pass. IT-1075 is re-measured on the pin-bump PR (section 8). |
| D3 | **Private state stays private.** One marked, contiguous block of internal accessors per class (`Terminal`, `Buffer`, `BufferLine`) is the only surface the replication files use. `curAttr` is read through `currentAttribute` and written through `setCurrentAttribute`. New fork state on `Terminal` (`respondsToQueries`, the valve's "disabled" flag) lives behind upstream's `cold` holder, not as new stored properties. | `scripts/check-fixed-layout.sh` passes. A source-scan test: the replication files reference no member of the three classes outside the accessor blocks' names and public API. |
| D4 | **The parser hook is one function**, called from the single tail of the parse loop, plus one call where `finishProgramStatusSt` changes state outside the loop. | The every-byte corpus (`TerminalStateSnapshotTests`, 12 streams) passes; two streams are added: a cut at every byte of an OSC 7501, and of a CSI the whole-sequence fast path would take when complete. One A/B run of `Tools/SwiftTermBenchmarks` headless suite: no case slower than 1.5% in both orders (upstream's own bar). |
| D5 | **Pty: the fork's close loop stays**, beside upstream's `eb710ea` and its new signal reset in the child. | `LocalProcessLifecycleTests` (upstream) pass; Scape's `PipeFDInheritanceTests` on the pin-bump PR. |
| D6 | **The size guard stays**, inside upstream's `syncProcessWindowSizeIfNeeded()`: a size under 2 columns or 1 row is never sent to the child. | A unit test on the function's decision (0×0 and 1×1 send nothing; 2×1 sends). |
| D7 | **The valve API is the fork's**: `synchronizedOutputTimeout: TimeInterval?` and `expireSynchronizedOutput() -> Bool`. Upstream's `Void` duplicate is removed. | Proof P1. |
| D8 | **Mouse report encoding is upstream's** (functions that return bytes). The one call that sends them is user input and is not gated by `respondsToQueries`. | Proof P2 covers it from the other side: a replica still sends mouse reports. |
| D9 | **`ByteRunScanner`: guard the empty span** on the Swift < 6.4 path (the line that has kept upstream's Linux job red since 2026-11-04). | The fork's tests complete in the Swift 6.2 container. |
| D10 | Mechanical keeps: `public` on `search`, `cellDimension`, `lastResult`; `Buffer`'s mode flags through D3's block; the fork's `FrameDriver` test hook beside `setLinkRunning`. | compile + existing tests |

## 4. The three proofs, inside PR B

**P1. With `synchronizedOutputTimeout == nil` the terminal neither expires on its own nor asks anyone to run a timer.**

What I found at the spot **[M]** (trial tree `Terminal.swift:9237-9266`, `:10760`; fork `Terminal.swift:8250`, `:9528`): the fork's guard landed inside upstream's `applySynchronizedOutputWatchdog`, after the "not active → cancel" branch and before arming. That is correct for a plain `Terminal` on macOS and Linux. It leaves two paths ungated:

- the `#if SWIFTTERM_EMBEDDED` branch above it calls the new delegate timer `scheduleSynchronizedOutputTimeout` unconditionally (not a build we ship, but the guard should not depend on that);
- `ViewTerminal` **overrides** the whole function and hands the request to the view's own watchdog (`TerminalRenderOwner`). The guard is never reached, so a terminal inside a `TerminalView` still expires on the view's clock with the timeout set to `nil`. This is true in the fork today, before any merge. It does not affect the daemon or #1289 (plain `Terminal`), but it is exactly what S2.4's replica view would hit.

Decision: the gate moves one level up, to the one non-overridden caller (`reconcileSynchronizedOutputWatchdog`): when the timeout is `nil` the watchdog is told "not active". All three paths are then covered by one line.

Pinned by tests, with no wall-clock dependence (the watchdog's counters and a recording delegate):
- plain `Terminal`, `nil`: enter DEC 2026, feed, wait past the default timeout → still active; `armed == 0`; `expireSynchronizedOutput()` returns `true` once, then `false`.
- `ViewTerminal`, `nil`: the view's handler is never called with `active == true`.
- a delegate that records `scheduleSynchronizedOutputTimeout`: never called with `nil`.
- setting `nil` while a timer is pending cancels it.

**P2. A replica answers nothing.** Every reply the terminal generates from parsed input goes through `sendQueryResponse`; upstream's four typed `sendResponse` overloads are routed through it. Pinned two ways:

- a source-scan test: in `Sources/SwiftTerm` outside `Apple/`, `Mac/`, `iOS/`, `tdel?.send` appears only inside two named functions (the gated query sink and the user-input sink) and the lines a short allow-list names with a reason (paste, semantic click);
- a behaviour test over every reply path: the existing 12 parameterised queries plus one per report upstream added in this window (the builder lists them from `git log -S'sendResponse' 5cb37e865..d4f52faaa`, at least DECRQSS, the new DECRQM modes, OSC 110/111/112 colour queries, DECRQCRA when enabled). For each: the owner sends the expected bytes; a terminal with `respondsToQueries == false` sends none; and a mouse report is still sent.

**P3. The digest sees everything the census names.** `DigestDescriber` descends into class instances (today it prints only the type name **[M]**), so `Terminal.cold`, `reportedOnly`, `payloads` and `programStatusStore` are compared field by field. Pinned by: for each holder, two terminals that differ in one field of it produce different digests.

## 5. The format

- **`TerminalReplayStream.swift` is deleted in PR A**, before the merge. Scape's one use (`TerminalReplicationHarness.swift:190`, the `.byteStream` format, and its measured-not-required class `SnapshotFormatT3ByteStreamTests`) is removed in the pin-bump PR.
- **`STSS` becomes version 2. The v2 decoder refuses v1 bytes**, and refuses any other version, before reading a field. Pinned: a v1 header and a recorded v1 snapshot both throw; nothing is imported. `STSH` moves to 2 with it, so one number describes a build (a chunk never pairs with a screen part of another version).
- **The field census decides field by field.** Criterion: any terminal state that a reader of the replica can observe (what is drawn, what the next byte does, what a query would answer, what the host reads through public API) is **carried**; anything else is **excluded with a written reason**. The census is one table in the source: every stored property of `Terminal`, `Buffer`, `BufferLine` and of each reference-typed holder they own, each marked carried or excluded.
- **The census test fails when state appears that the census does not name**: the reflected property names of those types (and holders) must equal the census's names, both ways. This is what turns the next upstream field into a failing test at merge time.
- Carried explicitly in v2 (from the findings, section 4): `pendingWrap` and `savedPendingWrap` per buffer, **restored after the cursor is set** (the cursor setters clear the flag); character protection (terminal and per buffer, saved); `characterProtectionMode`; `keyboardActionMode`, `sendReceiveMode`, `backarrowKeyMode`, `reverseWraparoundExtended`, `noClearOnColumnChange`; `cursorStartsNewGrapheme`; `cold.moreFix`; the OSC 10/11 overrides in `cold` (the OSC colour, not the host's); the modes in `reportedOnly`. Removed: `savedWraparound`, `savedReverseWraparound`. `bulkInsertBlocked` is derived on import. `usedStart` is excluded (storage bound; cells are compared to full width).
- **Program status is carried** (a host reads it through public API). Its change on child exit has no byte behind it: the replica applies it when it applies **the session's existing exit event**. No new ring event. The fork exposes the one call the replica makes; #1289's exit path calls it when it re-gates.
- Images stay "declared lost until redraw".

## 6. How PR B is structured so it can be read

One PR, one review, commits in this order. Each commit builds except where stated; the reviewer reads commit by commit.

1. **The merge commit**, with only mechanical resolutions (D10, the Pty and `SearchService` hunks, both-kept hunks). Decision hunks are resolved to upstream's side with a `// IT-2001: Dn` marker where fork code was dropped. This commit is allowed not to build; its message says so and lists every conflicted file with the side taken.
2. **One commit per decision, named `IT-2001 D1` … `D9`**, each with its test. After D1 to D9 the tree builds.
3. **The auto-merge audit commit**: fixes for files git merged without a conflict, each named in the message. The known list: the duplicate `expireSynchronizedOutput`, `noteWritten(from:upTo:)`, the `sendResponse` overloads, the event numbering, the watchdog gate. The builder reads every auto-merged file the fork had changed (findings, section 3) against both sides and adds what else turns up.
4. **Format v2 and the census** (section 5).
5. **The three pins** (P1, P2, P3) if not already landed with their decisions.
6. A findings record under `docs/spikes/`, as the two earlier merges left: which side won each hunk and why.

PR B merges into `scape-selection-api` with a **merge commit**. The builder records the resulting SHA; that SHA is the pin.

## 7. Invariants (true after PR B; each is pinned by a test above or below)

1. A snapshot is taken under `terminalLock`, between feeds; `pendingParserBytes` fed to a fresh parser puts it in the same state; `nil` means "wait".
2. Owner and replica digests are equal at every cut of the corpus, and again after the rest of the stream, whole and streamed.
3. A replica (`respondsToQueries == false`) writes nothing to its delegate except user input.
4. With `synchronizedOutputTimeout == nil`, DEC 2026 ends only by the application's own reset or by `expireSynchronizedOutput()`.
5. No state change in the owner is invisible to the replica: it follows from a byte, from an ordered ring event (resize, valve, exit), or it is excluded in the census.
6. The decoder never half-decodes: a wrong magic, version or length throws before any state changes.
7. A history chunk is refused, changing nothing, once its buffer's grid has changed.
8. Hot-path types keep a fixed layout; the fork adds no stored property to `Terminal`.
9. The shared sources build with `Apple/`, `Mac/`, `iOS/` excluded, on Swift 6.2.

## 8. The gate

**Fork, PR A and PR B (all green before merge):**

| Check | Where |
|---|---|
| `swift build`; `swift test` (whole suite, through the shared SwiftPM lock) | macOS |
| `swift build --target SwiftTerm`; `swift test --filter "TerminalStateSnapshotTests\|ReplicationPrimitivesTests\|CellStorageTests\|LocalProcessLifecycleTests"`, then the whole suite | `swift:6.2-noble` container. **This is our Linux evidence; upstream's job is red.** A test that fails there and also fails at upstream `d4f52faaa` is recorded, not fixed, unless it is D9. |
| `scripts/check-fixed-layout.sh` | macOS, release |
| `swift test -c release -Xswiftc -enable-testing --filter ReplicationSizeTimeTests`: the screen part under 50 ms and 1 MiB at 200 × 60 | macOS |
| D4's benchmark A/B | macOS, once |
| Assertion audit for every test file the merge touched: no pre-merge assertion missing unless its commit names it | as in the IT-304 record |

**Scape pin-bump PR (all green before merge):**

| Suite | Bar |
|---|---|
| T3 full sweep, `SCAPE_T3_FULL=1 swift test --filter SnapshotFormatT3` | every cut passes whole and streamed; the comparator tells every one-byte-earlier pair apart; the cut and resync counts are reported beside the last run's (1,238 cuts, 8 resyncs, 2,440 pairs). A count that moved is explained, not waved through. |
| Full Mac headless run, `scripts/run-headless-tests.sh`, with `required-tests.tsv` and `check-headless-core.py` (pins agree) | all required identities exactly once |
| Headless Core on Linux amd64 and arm64 (CI) | green |
| Xcode terminal tests: the `ScapeTests` files that import SwiftTerm, at least `PipeFDInheritanceTests`, `CodexDeliveryPolicyTests`, `CursorDisplayTests`, `ComposerDeliveryGateTests`, `ShellTerminalSpectatorTests`, `TerminalRedrawGateTransitionTests`, `SwiftTermViewFocusGuardTests`, `KimiStatusAndScreenTests` | green |
| IT-1075 re-measured: the same repro (a dozen agent terminals in tight DEC 2026 frame loops with title spinners) | the main queue does not grow; the number is recorded beside the old one |

**What changes in Scape, file by file** (at `f63b5c5f6`) **[M]**:

| File | Change |
|---|---|
| `Package.swift:403`, `Package.resolved:243`, `Scape.xcodeproj/project.pbxproj:9679`, `Scape.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:153` | the four pin locations, all to PR B's merge SHA |
| `docs/claude/headless-daemon.md:122` | the pin and the API list it names |
| `Scape/Terminal/ScapeTerminalView.swift:1374-1384` | the Option-click rectangular selection: removed; the view's own Option-drag does it (D1) |
| `Scape/Terminal/ScapeTerminalView.swift:1225-1267` | the `dataReceived(slice:)` override, unavailable upstream: becomes a Scape-named method for direct feeds that calls `feed(byteArray:)`; its filtering and accounting are unchanged |
| `ScapeTests/CodexDeliveryPolicyTests.swift`, `ScapeTests/CursorDisplayTests.swift` | call the renamed method |
| `Headless/Tests/TerminalReplicationHarness.swift`, `SnapshotFormatT3Tests.swift`, `Headless/required-tests.tsv` | the `.byteStream` format and `SnapshotFormatT3ByteStreamTests` removed; format v2; any exclusion-name changes |
| anything else the compiler names | fixed in the same PR and listed in its description; one known candidate is the single cursor-colour call in `ScapeTerminalView` |

## 9. Nash's part: about one hour, at the end

On a build of the pin-bump PR. Tick each; anything odd, say which step.

- [ ] **Paste:** paste a multi-line command into a shell; paste into Claude Code's prompt; paste something long (a few hundred lines).
- [ ] **Select and copy:** drag-select text, copy, paste elsewhere. Double-click a word, a URL and a file path. Triple-click a long wrapped line (it now selects the whole logical line).
- [ ] **Block selection:** hold Option and drag a rectangle in a shell; copy it; check the pasted block. Do the same inside Claude Code. Then Option-click once inside Claude Code's input (its cursor should move; no selection should start).
- [ ] **Resize and split:** drag the window edge while output streams; split a pane; close the split. Switch to another tab, resize the window, switch back: the hidden tab's content is right.
- [ ] **Mouse in vim:** `vim` with `:set mouse=a`: click to place the cursor, drag to select, scroll with the wheel and the trackpad. Then `less` on a long file: wheel and trackpad scroll it.
- [ ] **Scrollback while output streams:** run something that prints continuously, scroll up and stay there, select text while it streams, scroll back to the bottom.
- [ ] **Many agents:** a dozen agent sessions working at once for a few minutes: typing stays responsive, titles keep updating.
- [ ] **Odds and ends:** Tab completion in a brand-new tab straight away; find-in-terminal; a few accented or CJK characters through the input method; move the window to another display and check the text is sharp.

## 10. Effort

| Step | Days |
|---|---:|
| PR A: prep (delete the replay stream, accessor blocks, parser hook as one function) | 0.5 to 1 |
| PR B: merge commit and D1 to D10 | 2 |
| PR B: audit commit, format v2, census, P1 to P3 | 1.5 |
| PR B: gate (macOS, Linux container, layout, benchmark) | 0.5 |
| Scape pin-bump PR: changes and its gate | 1 to 1.5 |
| IT-1075 re-measure; Nash's hour | 0.5 |
| **Total** | **6 to 7** (range 5 to 8) |

All figures are estimates **[I]**. The fallback checkpoint is in section 2.

## 11. Out of scope

- Offering fork commits upstream (the fd close loop, the `ByteRunScanner` guard, the size guard, the valve API, title coalescing, the lazy attribute table, `onOutput`, `respondsToQueries`, the parser hook): a later ticket. D9's one-line fix is carried in the fork now regardless.
- Upstream commits after `d4f52faaa`.
- Using upstream's public `LocalProcess.updateWindowSize` in the session host, and any other change to #1289 beyond re-gating on the new pin.
- S2.4's replica view. (P1 removes one obstacle to it; nothing else here builds it.)
- Linux CI on the fork and the weekly upstream canary (findings, 6.6 items 8 and 9): recommended, separate tickets.
- Replacing `getText(maxUTF8Bytes:)` with upstream's bounded snapshots.
- Compatibility between format versions. There is none: v2 refuses v1.
