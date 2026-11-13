# IT-2001: plan for merging upstream SwiftTerm into `scape-selection-api`

Date: 2026-11-13. Nash said go. This is the plan a builder follows in a fresh worktree; this branch stays docs only. Evidence is in `2026-11-13-it2001-upstream-merge-scoping-findings.md` ("the findings"). Tags: **[M]** measured (source named), **[I]** inferred. Revision 2 folds in the daemon lead's design read (two P1s, conditions C1 to C6) and the Codex plan review (three P1s, six P2s, two P3s; cited as X1 to X11).

Merge target: upstream `d4f52faaa` into fork `1b21b1bf3` (base `5cb37e865`; 12 conflicted files, 27 hunks). If upstream has moved when the builder starts, the builder still merges `d4f52faaa`.

## 1. Outcome and order

1. **Fork PR A (prep, on today's base, no behaviour change):** delete `TerminalReplayStream.swift`; one accessor block per class in place of the access widenings; the parser hook as one function. **May start now.**
2. **Fork PR B (the merge, the format revision and the proofs: one review).** Its first commit is a true two-parent merge of `d4f52faaa`.
3. **Scape pin-bump PR**, pinned to PR B's merge commit on `scape-selection-api`.
4. **Scape PR #1289 (S2.3, the session host) re-gates on the bumped pin.** It does not merge on the old pin.
5. Nash's hands-on check (section 9).

**The pin is a tested tree.** Nothing else lands on `scape-selection-api` between PR A's merge and PR B's. PR B merges as a **merge commit** (a squash or rebase leaves the tested SHA unreachable from the branch; missed once today). The builder records `git rev-parse <merge-sha>^{tree}` and `git rev-parse <gated-head>^{tree}`, both quoted in the pin-bump PR; if they differ, the fork gate is rerun on the merge commit before the bump.

## 2. The condition on the session host, and the fallback

Scape PR #1289 ("tether", S2.3, on hold at `46faf0eff`) is written on `HeadlessTerminal` **[M]** (`gh pr diff 1289`). It merges only after the pin bump.

**SwiftTerm API it uses, which PR B keeps with the same shape** (**[M]** from its diff):

| API | Note |
|---|---|
| `HeadlessTerminal(queue:options:onEnd:)`, `.terminal`, `.process`, `.send(data:)` | upstream adds defaulted `directDelivery:` and `onLaunchFailure:` before `onEnd`; the trailing-closure call still fits **[I]** |
| `HeadlessTerminal.onOutput` | fork-owned: after the feed, on the feeding thread, under `terminalLock` |
| `LocalProcess.startProcess(…)`, `.shellPid`, `.childfd`; `PseudoTerminalHelpers.setWinSize(masterPtyDescriptor:windowSize:)`; `TerminalOptions(cols:rows:scrollback:)` | unchanged upstream |
| `Terminal.terminalLock`, `.rows`, `.cols`, `.resize(cols:rows:)`, `.feed(byteArray:)`, `.getLine(row:)` | unchanged |
| `Terminal.synchronizedOutputTimeout` (set to `nil`), `.synchronizedOutputActive`, `.expireSynchronizedOutput() -> Bool` | fork-owned. #1289 uses the `Bool` in a `guard`; upstream's `Void` duplicate is removed. **Confirmed by the lead.** |
| `Terminal.pendingParserBytes` (`nil` = wait), `.respondsToQueries` | fork-owned |
| `exportForStreaming()`, `TerminalStreamingExport.screen.encoded()`, `.historyChunks(linesPerChunk:)`, `TerminalStateSnapshot(encoded:)`, `importState(_:)`, `TerminalHistoryChunk(encoded:)`, `importHistoryChunk(_:) -> Bool` | fork-owned; the bytes become format v2 |
| `@_spi(Replication) replicationDigest()` | fork-owned; tests only |

**#1289's re-gate list gains** (owned by its builder, named here so it is not lost):

- one test that a failed launch arrives as ordinary ring output (upstream writes "Process launch failed" into the terminal through `dataReceived`, so it passes `onOutput`) **[M]**;
- its exit path makes the one program-status call of section 5, **ordered after the final output entry and before any snapshot taken after the exit** (one test: a snapshot taken after exit shows the exited status and the last output) (X9);
- **a failed launch cannot leave a session "starting"**: upstream's `processFailedToStart` calls `onLaunchFailure`, or writes diagnostic output, and does not call `onEnd` **[M]** (upstream `HeadlessTerminal.swift`, that function's body), so the host ends the session from its own spawn check (it already throws on `pid <= 0`) or from `onLaunchFailure`; one test (X9);
- it stays as written on `childfd`. Upstream's `LocalProcess.updateWindowSize(_:)` is `public` (internal in the fork) **[M]**; taking it is **a ticket after #1289 merges**, a separate small PR, whose builder first quotes upstream's body, its lock and queue, and whether the host's thread may call it.

**Fallback.** Lloyd makes the call at whichever comes first: #1289 has everything it needs except the pin, or the end of working day 5 **counted from the day PR A's builder starts**. If PR B has not passed its gate (section 8) by then: #1289 merges on the old pin, the merge lane continues, the pin bump lands before S2.4 starts, and #1289's fixtures are regenerated with it. **Condition: under the fallback no build containing the session host leaves the building before the pin bump** (otherwise v1 is a shipped format). "Merged" is not "shipped": on developer machines the bump then means a **clean daemon restart**; no v1 snapshot or chunk is kept on disk (they exist only on the wire and in fixtures), and a v1 peer is **refused** by the version check, never converted (X9).

## 3. Decisions (each with its test)

| # | Decision | Test that pins it |
|---|---|---|
| D1 | **Block selection is upstream's** (`isBlock`, `startBlockSelection(bufferPosition:)`, the held-Option press). The fork's `SelectionMode.rectangular`, its branches, `optionBypassesMouseReporting` and `getRectangularText` are deleted. | Upstream's block-selection tests pass unmodified. The fork's 9 `testRectangular*` tests are deleted **only with a table in that commit's message: each of the nine beside the upstream test that "covers X", or "not covered: why it is gone"** (C6). The `setSelection` mode-reset tests stay, extended to assert `isBlock == false`. |
| D2 | **Sync-end is upstream's** (`a329fc7`). The fork's `synchronizedOutputEnded` event is deleted. **Title coalescing is kept, re-expressed on the same mechanism** (latest title in the view's cross-thread state, applied in `applyPendingViewUpdates`). `TerminalEvent` keeps upstream's numbering. | `MainHopCoalescingTests` rewritten: N title changes and N sync-ends between two frame ticks give one delegate call each, with the last value. Upstream's `FrameDriverTests` pass. IT-1075 re-measured (section 8). |
| D3 | **Private state stays private.** One marked, contiguous block of internal accessors per class (`Terminal`, `Buffer`, `BufferLine`) is the only surface the replication files use. `respondsToQueries` and the valve's "disabled" flag live behind upstream's `cold` holder. | `scripts/check-fixed-layout.sh` passes, **its output quoted in PR B** (C4). A source-scan test: the replication files name no member of the three classes outside the accessor blocks and public API. |
| D4 | **The parser hook is one function at the loop's single tail, and nowhere else.** `finishProgramStatusSt` is called from inside the loop and its caller reaches the tail, so it gets no hook of its own (no double count) (X4). Contract: the function sees every transition exactly once, with the batch index of its first byte and the bytes consumed; bytes handled before the tail (printable runs, the CSI-digit `continue`, OSC/APC continuation bytes at the start of a batch) belong to the open sequence by position, not by a hook call; a C0 executed inside a sequence is skipped, never replayed; a parser reset during the parse clears the record; a transition that consumes zero bytes records nothing. | The every-byte corpus (12 streams) plus one stream per contract clause, each cut at every byte: `consumed > 1` (whole CSI), CSI digits split across feeds, OSC and APC continuation bytes at a batch start, C0 inside CSI and inside OSC, RIS mid-sequence, an OSC 7501 with a well-formed and with a malformed (zero-byte) terminator. **A/B on the same merged engine with and without the hook** (not against the old fork): no headless case slower than 1.5% in both orders; allocations per parse call unchanged when the batch ends in ground state. |
| D5 | **Pty: the fork's close loop stays**, beside upstream's `eb710ea` and its signal reset in the child. | Upstream's `LocalProcessLifecycleTests`; Scape's `PipeFDInheritanceTests` on the pin-bump PR. |
| D6 | **The size guard stays**, inside upstream's `syncProcessWindowSizeIfNeeded()`. | Unit test on the decision: 0×0 and 1×1 send nothing; 2×1 sends. |
| D7 | **The valve API is the fork's** (`synchronizedOutputTimeout: TimeInterval?`, `expireSynchronizedOutput() -> Bool`). | Proof P1. |
| D8 | **Mouse report encoding is upstream's.** The one call that sends the bytes is user input, not gated. | P2: a replica still sends mouse reports. |
| D9 | **`ByteRunScanner`, Swift < 6.4 path: no force-unwrap of an empty buffer.** The failing expression is `UnsafeRawPointer(buffer.baseAddress!)` in `vectorScanC0` (`ByteRunScanner.swift:208`) and the same line in its two siblings; `wordAndVectorScansAgreeWithScalarSearches` calls them directly with a zero-length span on its first iteration (`length = (0 * 37) % 200`) **[M]** (upstream job log: `ByteRunScanner.swift:208: Fatal error: Unexpectedly found nil`; test source `:130-147`). The public entry points guard length; these three do not. Each returns `start` when the base address is nil (X10). | That test passes in the Swift 6.2 container. |
| D10 | Mechanical keeps: `public` on `search`, `cellDimension`, `lastResult`; the fork's `FrameDriver` test hook beside `setLinkRunning`. | compile + existing tests |

## 4. The proofs, inside PR B

### P1. With `synchronizedOutputTimeout == nil`, no timer runs or fires; the view still knows a synchronized update is open

**What each receiver does with `active`** (**[M]**, trial tree; the builder re-quotes from the merged tree before coding):

| Receiver | Code | Uses `active` for |
|---|---|---|
| `Terminal.applySynchronizedOutputWatchdog`, normal build (`Terminal.swift:9245-9290`) | `guard active else { …synchronizedOutputTimeoutItem.cancel()… return }`, then `scheduleEventTimer(.synchronizedOutput, deadline: .now() + synchronizedOutputTimeoutSeconds, …)` | cancel or arm; nothing else |
| the same, `#if SWIFTTERM_EMBEDDED` (`:9246-9249`) | `if active { tdel?.scheduleSynchronizedOutputTimeout(source: self, afterMilliseconds: 1_000) }` | ask the host for a timer; no cancel exists |
| `ViewTerminal` override (`:10760`) → `SynchronizedOutputWatchdog.Target.update` (`Apple/SynchronizedOutputWatchdog.swift:57-91`) | `if active { … arm(deadline) } else { guard generation == state.armedGeneration else { return } … disarm() }` | arm, rearm, disarm; nothing else |

**The view's knowledge of DEC 2026 does not come from this signal**: it reads `terminal.synchronizedOutputActive` (`TerminalRenderOwner.swift:274`, `TerminalSnapshot.swift:354`, `MacTerminalView.swift:4042`) **[M]**. No receiver uses `active` for more than arming, so the gate may tell the watchdog "do not arm" without a separate argument. If the re-quote finds otherwise, the gate passes `arm: false` and leaves `active` true.

Why the gate must move: the fork's guard sits inside the function's normal-build body. That is correct for a plain `Terminal` (the daemon, #1289) and is bypassed by the Embedded branch and by `ViewTerminal`'s override; the override bypass exists in the fork today (`Terminal.swift:9528` at `1b21b1bf3`) **[M]**.

**Decisions** (X1, lead P1-1):

1. **Gate.** `reconcileSynchronizedOutputWatchdog` is `final` and is the only caller of `apply…`; with the timeout `nil` it passes "not active". `Terminal.synchronizedOutputActive` is untouched.
2. **Setter reconciliation.** Setting `nil` cancels the terminal's own item (today) **and** marks the watchdog dirty and reconciles under `terminalLock`, so the view's watchdog is disarmed too (today it is not). Setting a value while a window is open re-arms.
3. **Stale-callback rejection, in one place.** Both timer paths end in `Terminal.synchronizedOutputWatchdogFired(generation:)` (the terminal's own item, `:9281-9285`; the view's `Target.fire`, `SynchronizedOutputWatchdog.swift:114`) **[M]**. It returns without effect when the timeout is `nil`, in addition to its `active` and `generation` checks. A callback already in flight when `nil` is set therefore changes nothing.
4. **Embedded contract.** The host timer is requested only through the same gate, so it is never requested with `nil`. SwiftTerm cannot cancel a host timer already requested, and upstream's host calls the public `expireSynchronizedOutput()`, which must keep working with `nil` (it is how a replica applies the owner's event). So for Embedded the rule is written at the delegate method: **a host that sets `nil` drops its own pending timer; a late call is treated as an ordered expiry.** We do not build or ship Embedded; this path is proved by construction (pins 7 and 8), and the plan says so plainly (X10).

**Pins** (no wall-clock dependence: counters, recording delegates, callbacks delivered by hand):

1. plain `Terminal`, `nil` from the start, DEC 2026 open: still active, `armed == 0`; `expireSynchronizedOutput()` returns `true` once, then `false`.
2. `ViewTerminal`, `nil`, DEC 2026 open: **the view still holds its display** and the view watchdog's `armed == 0`.
3. `ViewTerminal`, `nil`: `expireSynchronizedOutput()` returns `true` once; **the view is released and redraws**.
4. **Arm → set `nil` → deliver the old callback**, plain `Terminal`: the captured work item is run by hand; the mode stays active; `fired` does not advance.
5. **Arm → set `nil` → deliver the old callback**, `ViewTerminal`: the view watchdog is disarmed by the setter; `Target.fire()` called by hand changes nothing.
6. **Arm → set `nil` → deliver the old callback**, host timer: the normal-build seam (pin 7) records one request before `nil`, none after; a direct call to `synchronizedOutputWatchdogFired` with the old generation changes nothing.
7. The decision "request a timer, cancel, or nothing" is one pure function of (active, timeout is nil, armed generation), used by all three branches and unit-tested in the normal build.
8. Source pins: no `override func reconcileSynchronizedOutputWatchdog`; the Embedded branch's only timer request is on that function's result.

### P2. A replica answers nothing, and still sends what the user does

**Two sinks, and nothing else writes to the delegate** (X2):

- **the reply sink** (`sendQueryResponse`, gated by `respondsToQueries`): every byte generated from parsed input. That is the whole `sendResponse` family (labelled text, unlabelled text, bytes, prefix + text, prefix + bytes, prefix + text + suffix, variadic), the focus report sent when DECSET 1004 is enabled, and Kitty clipboard replies.
- **the user-input sink** (not gated): `sendUserInput`, paste (including Kitty paste), mouse packets (D8), semantic-prompt click packets and repeated semantic cursor movement, and focus reports caused by a real focus change. Upstream sends the semantic click through `sendResponse` (`Terminal.swift:3540` upstream) **[M]**; it moves to the user-input sink, or a replica's clicks would be swallowed.

Pinned:

- **Source scan (C5):** in `Sources/SwiftTerm` outside `Apple/`, `Mac/`, `iOS/`, the pattern `tdel\s*\?\s*\.\s*send\s*\(` (so `tdel?.send (` and `terminal.tdel?.send(` both match) appears only inside the two sinks. The allow-list is closed and empty unless a line is added with a reason; any other match fails.
- **Site table:** the builder enumerates, from the merged tree, every call that reaches either sink and records it in the findings record with its sink. `git log -S` is only a cross-check.
- **Behaviour, one case per reply site in that table**, including a clipboard reply and the 1004 enable-time focus report: the owner sends the expected bytes; a terminal with `respondsToQueries == false` sends none.
- **Behaviour, user input on a replica:** a mouse packet, a semantic click, a paste and `sendUserInput` are all sent with `respondsToQueries == false`.

### P3. The census and the digest prove different things (X3)

- **The census proves classification coverage, not serialization correctness.** It shows that every stored property was looked at and marked carried or excluded. That a carried field is exported and imported correctly is proved by the corpus (digests equal at every cut) and by a populated fixture per field (below).
- **The digest compares logical state, in canonical form.** It descends into a class instance **only for holders the census names**, tracks visited objects (no cycles), walks superclass mirrors, and **fails instead of truncating**: the depth-eight "…" becomes a test failure. Back-references (delegate, parent terminal, any `weak`/`unowned`) are excluded by name with a reason.
- **`payloads` is not compared by reflection.** Atom codes, cache slots, collection thresholds and retry counters are allocation state: two terminals with the same hyperlinks may hold different atoms. The canonical comparison is the one the digest already uses per cell (the link's target string) plus the active hyperlink's target. The holder's fields are census exclusions, each with that reason.
- **What reflection cannot see is listed and audited by hand in the findings record**: static atom tables, storage behind unsafe pointers (cell pages are covered by the per-cell comparison to full width), lazily built caches. Each gets a line: compared canonically, rebuilt on import, or excluded, and why.
- **Fixtures.** For every carried field and every named holder, a test sets a non-default value on the owner, exports, imports, and requires equal digests, and separately requires that two terminals differing only in that field digest differently. A holder that is `nil` or absent at reflection fails the census test (the lead's condition a).

## 5. The format

- **`TerminalReplayStream.swift` is deleted in PR A.** Scape's one use (`TerminalReplicationHarness.swift:190`, the `.byteStream` format, and `SnapshotFormatT3ByteStreamTests`) goes in the pin-bump PR.
- **`STSS` and `STSH` are both version 2, from ONE constant.** Each decoder refuses v1, and any other version, before reading a field. Pinned for each: a v1 header and a recorded v1 payload throw and nothing is imported.
- **The version names the schema, not the session** (X5). It does not stop a v2 chunk being paired with an unrelated v2 screen part. That stays the job of the checks that exist today and are kept and re-pinned: a chunk carries its buffer's grid and is refused when the grid differs; the host pairs parts by its own `asOfSeq`.
- **The field census decides field by field.** Criterion: terminal state a reader of the replica can observe (what is drawn, what the next byte does, what a query would answer, what the host reads through public API) is **carried**; anything else is **excluded with a written reason**. **Images are the stated exception**: Kitty and sixel images are drawable state that is not carried (X6).
- **The census test** compares reflected property names to the census both ways (see P3 for what that does and does not prove).
- **Preservation obligations** (already in v1; each keeps an explicit test): cursor style, margins, tab stops, charsets and saved cursors for **both** buffers, protection per cell.
- **Restore order per buffer:** everything that can touch `x` or `y` first (cursor, saved cursor, origin mode, margins, resize); protection **through its setters**, so `bulkInsertBlocked` is derived, never decoded; **`pendingWrap` last; `savedPendingWrap` restored as its own field**. Pins: a pending-wrap cut on the **normal** buffer and one on the **alternate** buffer each continue identically to the owner; `savedPendingWrap` is proved by a restore-cursor (DECRC) fed after the import.
- New in v2: `pendingWrap`, `savedPendingWrap`; character protection (terminal, per buffer, saved) and `characterProtectionMode`; `keyboardActionMode`, `sendReceiveMode`, `backarrowKeyMode`, `reverseWraparoundExtended`, `noClearOnColumnChange`; `cursorStartsNewGrapheme`; `cold.moreFix`; the `reportedOnly` DEC modes **and `reportedOnly.attributeChangeExtent`**. Removed: `savedWraparound`, `savedReverseWraparound`. Excluded: `usedStart` (storage bound).
- **Hyperlinks:** targets are carried; **atom identities never are**. The importer rebuilds upstream's link cache by interning each target through the normal path (X6).
- **OSC 10/11 overrides:** the snapshot carries the OSC colour only. The importer installs it **over the replica's own host colour**, so OSC 110/111 on the replica restore the replica's theme. Pin: owner and replica with different host colours; after import and OSC 110 each shows its own.
- **Program status is carried with its ordering and replacement semantics**, not only the public record list: an update fed after import replaces or appends exactly as on the owner (pin). Its change on child exit has no byte behind it: the replica applies it with **the session's existing exit event**. No new ring event.
- **Import onto a terminal that already has state** (a resync) **resets image state**: Kitty and sixel images, placements, pending transmissions and animation timers are cleared, so nothing stale is drawn over imported text. Pin: import over a terminal holding an image leaves no image and no live timer (X6).
- **State changes with no byte (C3).** The builder lists every state change in the merged core driven by a clock or callback (timers, `asyncAfter`, date comparisons in `Sources/SwiftTerm` outside `Apple/`, `Mac/`, `iOS/`). Each is an ordered host event or a census exclusion with a reason. The list goes in PR B's findings record **and to the daemon lead**. Known so far: the DEC 2026 valve; program status on exit.

## 6. How PR B is structured so it can be read

One PR, one review, commits in this order. **The gate runs at the head.**

1. **A true two-parent merge of `d4f52faaa`** with mechanical resolutions (D10, the Pty and `SearchService` hunks, both-kept hunks), decision hunks taken from upstream's side with a `// IT-2001: Dn` marker, **and the compile repairs** (the duplicate `expireSynchronizedOutput`, `noteWritten(from:upTo:)`, references to the two removed saved fields). Every repair is listed in the commit message. **Goal: this commit and every later one compile** (X8). Tests are green only at the head; the PR body says from which commit the fork's replication tests pass. If the builder finds the merge commit cannot compile without making a decision, the PR body **declares the range from the merge commit to the named first building commit non-bisectable**, in those words.
2. **One commit per decision, `IT-2001 D1` … `D9`**, each with its test.
3. **The auto-merge audit commit** (X7). Named checks, each answered in the findings record:

   | Area | Check |
   |---|---|
   | `CellStorage`, `CellArena` | the fork's lazily grown attribute table against upstream's attribute cache (`768c4f0`): a cached identifier never outlives a table growth; `CellStorageTests` including the full-growth test |
   | `CharData`, payloads | payload lifetime and collection (`41502dc`): an imported line's links survive a collection; `getText(maxUTF8Bytes:)` still bounded |
   | `SearchEngine`, `SearchService` | the fork's `public` grants against upstream's line cache; the lock contract |
   | `KittyClipboardProtocol` | reply and paste sinks (P2) |
   | `HeadlessTerminal`, `LocalProcess`, `TerminalIOPipeline` | `onOutput` is still called once per fed batch, in order, under the lock, with `directDelivery` false and true |
   | `CircularList`, `TerminalOptions` | line capacity and trimming as the snapshot assumes (the `aBufferHoldingMoreLinesThanItsRowsRoundTrips` case) |
   | `Package.swift` | compiler and trait branches on Swift 6.2 and 6.4; `SWIFTTERM_EXCLUDE_APPLE` kept; no new dependency on Linux |
   | every other auto-merged file the fork had changed | read against both sides |
4. **Format v2 and the census.**
5. **The pins** (P1, P2, P3) not already landed with their decisions.
6. **A findings record** under `docs/spikes/`: which side won each hunk and why; P2's site table; P3's hand audit; C3's list; D1's table; the layout check's output; the Linux baseline (section 8).

## 7. Invariants (true after PR B)

1. A snapshot is taken under `terminalLock`, between feeds; `pendingParserBytes` fed to a fresh parser puts it in the same state; `nil` means "wait".
2. Owner and replica digests are equal at every cut of the corpus, and after the rest of the stream, whole and streamed.
3. A replica writes nothing to its delegate except user input.
4. With `synchronizedOutputTimeout == nil`, DEC 2026 ends only by the application's reset or by `expireSynchronizedOutput()`; a view shows the held frame until then.
5. No state change in the owner is invisible to the replica: it follows from a byte, from an ordered event (resize, valve, exit), or it is a census exclusion.
6. A decoder never half-decodes: wrong magic, version or length throws before any state changes.
7. A history chunk is refused, changing nothing, once its buffer's grid has changed.
8. Hot-path types keep a fixed layout; the fork adds no stored property to `Terminal`.
9. The shared sources build with `Apple/`, `Mac/`, `iOS/` excluded, on Swift 6.2.

## 8. The gate

**Fork, PR A and PR B, at the head:**

| Check | Where |
|---|---|
| `swift build`; `swift test` (whole suite, through the shared SwiftPM lock) | macOS |
| `swift build --target SwiftTerm`; the whole suite | `swift:6.2-noble` container. **This is our Linux evidence; upstream's job is red.** First the builder records the exact failures of unmodified upstream `d4f52faaa` plus D9 in the same container (test names, quoted). Only a test on that list may fail in PR B, and **never a replication-critical one** (`TerminalStateSnapshotTests`, `ReplicationPrimitivesTests`, `ReplicationSizeTimeTests`, the census, P1 to P3, `CellStorageTests`, `LocalProcessLifecycleTests`) (X10). |
| `scripts/check-fixed-layout.sh` (output quoted) | macOS, release |
| `ReplicationSizeTimeTests`, release: the screen part under 50 ms and 1 MiB at 200 × 60 | macOS |
| D4's benchmark A/B | macOS, once |
| Assertion audit of every test file the merge touched: no pre-merge assertion missing unless its commit names it | as in the IT-304 record |

**Scape pin-bump PR:**

| Suite | Bar |
|---|---|
| Compile-only Xcode build of the app and test targets (C2) | clean |
| The python guards (C2): `check-headless-core.py` (pins agree), `check-required-tests.py`, `check-headless-inert.py`. This is my reading of "the three"; the builder runs every `scripts/check-*.py` the headless runner runs. | pass |
| **A sweep of `ScapeTests` and `Headless/Tests` for source-text pins** that name a SwiftTerm symbol or the pin SHA (tests that read source files as text), each updated or confirmed (C2) | listed in the PR |
| T3 full sweep (`SCAPE_T3_FULL=1`) | every cut passes whole and streamed; the comparator tells every one-byte-earlier pair apart; counts reported beside the last run's (1,238 cuts, 8 resyncs, 2,440 pairs); a count that moved is explained |
| Full Mac headless run with `required-tests.tsv` | all required identities exactly once |
| Headless Core on Linux amd64 and arm64 (CI) | green |
| Xcode terminal tests: the `ScapeTests` files that import SwiftTerm | green |
| IT-1075 re-measured with the same repro | the main queue does not grow; the number recorded beside the old one |

**What changes in Scape** (at `f63b5c5f6`) **[M]**:

| File | Change |
|---|---|
| `Package.swift:403`, `Package.resolved:243`, `Scape.xcodeproj/project.pbxproj:9679`, `Scape.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:153` | the four pin locations, to PR B's merge SHA |
| `docs/claude/headless-daemon.md:122` | the pin and the API list it names |
| `Scape/Terminal/ScapeTerminalView.swift:1374-1384` | the Option-click rectangular selection: removed (D1) |
| `Scape/Terminal/ScapeTerminalView.swift:1225-1267`; `ScapeTests/CodexDeliveryPolicyTests.swift:1851` | C1, below |
| `Headless/Tests/TerminalReplicationHarness.swift`, `SnapshotFormatT3Tests.swift`, `Headless/required-tests.tsv` | `.byteStream` and its test class removed; format v2; exclusion names |
| anything else the compiler names | fixed in the same PR and listed in its description |

**C1 (a P1 for this PR): `ScapeTerminalView.dataReceived(slice:)`.** Who calls the override today **[M]**:

- **Not the pty path.** At the current pin the process delegate is a private adapter inside SwiftTerm that parses on the IO thread; nothing in the fork calls the view's `open func dataReceived(slice:)` (`git grep` in `Sources/`: its only definition is `MacLocalTerminalView.swift:449`, no caller). Scape's own comment says so (`ScapeTerminalView.swift:1117-1125`: it "only sees DIRECT feeds — for a real tab its byte tallies stay 0").
- **In Scape, one caller: a test** (`CodexDeliveryPolicyTests.swift:1851`). `CursorDisplayTests` names it only in a comment.
- Live output is already accounted through `setProcessOutputHandler { tally.noteBatchApplied() }` (`ScapeTerminalView.swift:1157-1158`), which exists unchanged upstream (`MacLocalTerminalView.swift:304`).

So the merge takes nothing away: upstream turns an override the pty never reached into a compile error. The override becomes a Scape-named direct-feed method with the same body; the accounting stays on the output handler. **Test through the real process path:** a `ScapeTerminalView` runs a real child that prints a known string; the output epoch advances by the handler's tally, the text is on screen, and the direct-feed method was not called.

One fact for the daemon lead, **not introduced by this merge and out of its scope**: because the pty path does not pass that method, Scape's `SyncOutputFilter` and the dev-server log tee inside it do not see live pty bytes at the current pin either **[M]** (same evidence). If either is believed to be active on live tabs, that is a separate ticket.

## 9. Nash's part: about one hour, at the end

On a build of the pin-bump PR. Tick each; anything odd, say which step.

- [ ] **Paste:** a multi-line command into a shell; into Claude Code's prompt; something long (a few hundred lines).
- [ ] **Select and copy:** drag-select, copy, paste elsewhere. Double-click a word, a URL, a file path. Triple-click a long wrapped line (it now selects the whole logical line).
- [ ] **Block selection:** Option-drag a rectangle in a shell, copy it, check the paste. The same inside Claude Code. Then Option-click once in Claude Code's input: its cursor moves and no selection starts.
- [ ] **Resize and split:** drag the window edge while output streams; split a pane; close it. Switch tab, resize the window, switch back: the hidden tab is right.
- [ ] **Mouse in vim:** with `:set mouse=a`, click, drag-select, wheel and trackpad scroll. Then `less` on a long file: wheel and trackpad scroll it.
- [ ] **Scrollback while output streams:** scroll up and stay there, select text while it streams, return to the bottom.
- [ ] **A Claude Code or Codex session streaming a long answer: no flicker and no half-drawn frames.**
- [ ] **Many agents:** a dozen sessions working for a few minutes: typing stays responsive, titles keep updating.
- [ ] **Odds and ends:** Tab completion in a brand-new tab at once; find-in-terminal; accented or CJK input; move the window to another display, text stays sharp.

## 10. Effort

Revised after the two reviews: the proofs are more work than revision 1 allowed for (the canonical digest and its fixtures, the reply-site table, callback tests, image reset, the Linux baseline, the audit table).

| Step | Days |
|---|---:|
| PR A: prep | 1 |
| PR B: merge commit with compile repairs, D1 to D10 | 2.5 to 3 |
| PR B: audit table, format v2, census and fixtures, P1 to P3, C3's list | 3 to 4 |
| PR B: gate (macOS, Linux baseline and run, layout, benchmark A/B) | 1 |
| Scape pin-bump PR: changes, C1's test, its gate | 1.5 to 2 |
| IT-1075 re-measure; Nash's hour | 0.5 |
| **Total** | **9.5 to 11.5** (range 8 to 13) |

Estimates **[I]**. **The day-5 checkpoint stays** (section 2). On this estimate PR B is not through its gate by day 5, so unless #1289 is itself held longer, **the fallback is the likely outcome**: #1289 merges on the old pin, does not leave the building, and the bump lands before S2.4.

## 11. Out of scope

- Offering fork commits upstream: a later ticket. D9's fix is carried in the fork now regardless.
- Upstream commits after `d4f52faaa`.
- `LocalProcess.updateWindowSize` in the session host: a ticket after #1289 merges (section 2). Any other change to #1289 beyond its re-gate list.
- S2.4's replica view (P1 removes one obstacle; nothing else here builds it).
- Whether `SyncOutputFilter` and the dev-server log tee should see live pty bytes (section 8, C1).
- Linux CI on the fork and the weekly upstream canary: recommended, separate tickets.
- Replacing `getText(maxUTF8Bytes:)` with upstream's bounded snapshots.
- Compatibility between format versions: there is none; v2 refuses v1.
