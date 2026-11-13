# IT-2001: should we pull in the latest SwiftTerm, and how hard is it now?

Date: 2026-11-13. Read-only scoping. Nothing was merged; this branch contains only this document.

Every claim is tagged **[M]** (measured; the command or file is named) or **[I]** (inferred from reading code or commit text, not run). "Fork" is `fliptables/SwiftTerm` branch `scape-selection-api`; "upstream" is `migueldeicaza/SwiftTerm` `main`; "Scape" is `/Users/nash/dev/scape` read at `origin/main` `f63b5c5f6`.

## For Nash, in plain words

SwiftTerm is the terminal engine inside Scape. We keep our own copy (the fork) with our changes on top. The original author keeps improving his copy quickly: 163 changes in the ten weeks since we last synced. Yesterday we added a big new piece to our copy: the code that lets the background helper process (the daemon) own a terminal and send an exact picture of it to the app. That code reaches deep into the engine's private insides, which is exactly where the author has been rebuilding things for speed.

**Recommendation: sync now, as its own piece of work, before the daemon's session host and the app's "replica" terminal view are built on top. About 6 working days (range 5 to 8) for one agent lane, plus about an hour of your hands-on testing.** Confidence: medium-high.

The two reasons that decide it:

1. **The picture format has to change anyway, and today nobody uses it.** The author changed how the engine remembers "the cursor is waiting at the end of the line" and added new per-terminal state. Our picture format (version 1) does not carry those, so a synced engine needs a revised format. Today no shipped daemon reads version 1, so changing it is free. After the daemon ships, the same change needs compatibility work.
2. **The work only gets bigger.** The next daemon steps (the session host, then rebuilding the app's terminal view as a replica) will add more code against these same insides, and the author adds roughly 2.4 changes a day. Syncing later means re-fitting more of our code against more of his. My estimate for "after the daemon release" is 8 to 12 days and higher risk.

What you would notice as a user after the sync:

- **Gained:** fixes for screen corruption on resize; links that stop working in very long sessions (after about 65,000 printed links); hidden tabs that show stale content when shown again; emoji in window titles getting garbled when a read splits them; sharper text and correct grid when moving between displays; non-Latin keyboard fixes; less memory for glyphs; and about 25% faster output for programs that redraw in "synchronized" frames, which is what Claude Code does.
- **Changed:** Option-drag block selection becomes the author's version (the same as Terminal.app). A plain Option-click inside Claude Code now reaches Claude Code and moves its input cursor, instead of starting a selection.
- **Risk:** a short period where terminal behaviour needs careful checking (scrolling, selection, resize, many agents streaming at once). Nothing ships until the daemon is complete, so there is time to soak it.

One thing to know: the author's own Linux test run has been failing since 4 November (a test crashes on the older Swift version that our Linux build also uses). The engine still builds on Linux and the crash is in a test, not in the code path the daemon uses, but we should fix that one line in our copy and send him the fix.

If you do not want to spend the 6 days now, the fallback is: sync after the session host (S2.3) but **before** the app's replica terminal view (S2.4). Do not leave it until after the daemon release.

## 1. What was measured

| Fact | Value | How |
|---|---|---|
| Fork tip | `1b21b1bf32c0fafec91d0ba1d72afc3d58ef0d32` | **[M]** `git rev-parse HEAD origin/scape-selection-api` |
| Upstream tip | `d4f52faaae413b2e69c728ad79cd225cdbebc042` (2026-11-12) | **[M]** `git fetch upstream; git rev-parse upstream/main` |
| Merge base | `5cb37e865de9a86dd7344f772c40633339fd2880` (2026-09-04) | **[M]** `git merge-base HEAD upstream/main` |
| Ahead / behind | 33 / 163 | **[M]** `git rev-list --left-right --count HEAD...upstream/main` |
| Size of upstream's changes | 387 files, +48,434 / −4,536 | **[M]** `git diff --shortstat 5cb37e865..upstream/main` |
| Upstream rate | 163 commits in 69 days, about 2.4 a day | **[M]** dates of the first and last commit in `git log 5cb37e865..upstream/main` |
| Scape's pin | `7e495649be344bfeba3356cc576126b4f9a4237c` | **[M]** `git show f63b5c5f6:Package.swift` line 403 |

The local Scape checkout is at `b370c6af0`, behind `f63b5c5f6`; everything below reads Scape through `git show` / `git grep` at `f63b5c5f6`.

Throwaway work is under `~/Library/Caches/scape-build/it2001/` (`trial`, `trial-theirs`, `picks`: local clones with the push URL disabled). Nothing there was pushed.

## 2. What upstream changed

163 commits **[M]** (`git log 5cb37e865..upstream/main`). Grouped by theme, with what matters to a macOS app that hosts coding-agent CLIs. The "worth having soon" judgements are **[I]** from commit messages unless a line says otherwise.

| Theme | Commits | Matters to Scape? |
|---|---|---|
| **Performance: parse and scroll path** | `be5c0a8` (#806), `1a64da4` (#802), `a1aa912` (#804), `53bb506` (#805), `309adcc` (#809), `9655a1c` (#796), `922657f` (#798), `58553a6` (#810), `91f6bda`, `63f135d`, `911092a` (#788), `768c4f0` (#694), `233c6ba`, `11f173c` | Yes: many agents streaming at once is CPU on exactly this path. These also rewrite the internals the replication code reads (section 4). |
| **Performance: main thread** | `56ffb52` (#766), `a329fc7`, `7eb906e`, `aa4dfd6` (#793), `73b27f5` (#714) | Yes, strongly. `a329fc7`: main-queue hops per benchmark repetition 343,486 → 1,467, elapsed about −25% **[M]** (upstream `PERFORMANCE.md`, "Main-queue hops under the parse lock"). Same problem our IT-1075 work solved (section 5b). |
| **Memory** | `3e6c694` (#816) glyph atlas CPU copy dropped; `41502dc` (#792) link atoms reused and collected | Yes. |
| **Correctness fixes in the buffer** | `b5338ba` (resize pulls scrollback over the cursor), `12de993` (out-of-range read in `reflowNarrower`), `4d5eeea` (#727, reflow drops a character), `cd2f6c7` (#707, insert/delete line corrupts the screen in margin mode), `65cbcca` (#745), `ba89378` (#819), `210eccd` (#814), `17b0276` (#815), `a2706d2` (#718) | Yes: **worth having soon**. Agents resize constantly (split panes, window drags). `12de993` is a memory-safety class fix. |
| **Parser fixes** | `36639b8` (#743), `8230eb7` (#758), `fb1f1dd` (#799): a UTF-8 character split across reads inside an OSC or APC; `723af94` (#834), `a4a469c` (#818) OSC 8; `cb4ce94` DECRQSS size limit; `15fed4f` (#734) Kitty shared-memory name validation | Yes: **worth having soon**. Agent CLIs put Unicode spinners in the window title (OSC 0/2) on every frame. `cb4ce94` and `15fed4f` are hardening against hostile output. |
| **Links** | `41502dc` (#780/#792): before it, OSC 8 links stop resolving after 65,534 link prints **[M]** (upstream `PERFORMANCE.md`, "Run out of link codes"); `4b21963`, `7a26889` (#807), `d709dd7` (#702), `e0be0f2`, `fb77523` | Yes: **worth having soon**. Long agent sessions print many links. |
| **xterm conformance** | pending wrap as an explicit flag (`91f6bda`, `eaaede8`, `1b1d50a` #782), character protection (`6e5a344` #781), DECBKM/KAM/SRM (`79f89f2` #787), reverse wraparound 45/1045 (`9eccf35` #785), origin/margins (`368a82d` #784), `1ef9443`, `7f82ad2` (#791), SL/SR (`c4458cb`), OSC 110/111 and DECSET 41 (`958bcfc`, `c86e1d8`), `5b7cf01`, `ca8cf23`, `63621ed` | Mild benefit for TUIs. **Large effect on the snapshot format** (section 4). |
| **Rendering** | `5d6b3bf` (#775) device-pixel alignment, `37cc25e` (#710) re-snap on backing scale change, `2f573f7` (#769) hidden terminal shown again draws current content, `c3caadf` (#712), `8a03f55` (#774), `c7fc79c` (#728), `282c3c3` (#822), `06194d6` (#820), `1c07f3c` (#773), `11a4c77` (#759), `4dcf527` (#747), `43ba813` (#749), `95a8b00` (#739), `c1817d4`, `f55d5d1` (#771), `367958a` (#778), `8543190` (#823) | Yes: `2f573f7` and `37cc25e` are **worth having soon** (Scape hides and shows terminals all the time; users move windows between displays). |
| **Selection and search** | `10043e7` (block selection with Option-drag, URL/path double-click, logical-line triple-click), `19a94b5`, `ca5dbee` (#776, long wrapped output stalls search/selection/links) | Yes, and it overlaps the fork's own rectangular selection (section 5a). |
| **Input** | Kitty keyboard `4456bee`, `46e8a24`, `2b682d0`, `963d1a6`; non-Latin layouts `9fc2d2f`, `57973ad`; `faf7ce8` (held keys repeat), `c563232` (#760), `d129365` (#706), `288a3ec` (#700); mouse `126e28c`, `1716d2b` (#730), `a7b8b94`, `caa1bdd` (#765), `3d6f1d4` (#681) | Yes: Claude Code and Codex use the Kitty keyboard protocol. |
| **Process and PTY** | `eb710ea` (#719) private PTY descriptor no longer leaks into children; `a183c15` (#742) `LocalProcessTerminalView.dataReceived(slice:)` made unavailable; `c81d357` | `eb710ea` complements our own fd fix. `a183c15` breaks a Scape override (section 7). |
| **New host API** | content snapshots `00f5a63` (#673), `55cfa8f` (#763), `b7f9ea4` (#753); `7bf4fac` (#711) `visibleRowsText`; `7f74c55` (#690) `observeOscEvents`; `364cdc9` (#693); `e19de35` (#685); `fe4fb45` (#715); program status OSC 7501 (`2dad6a1`, `c87e81a`); progress (`976ee91`, `27fe36a`); external render `be13b66` (#832) | Optional. `TerminalContentSnapshot` is a text/colour copy for inspection; it is not a state export and does not replace ours **[I]** (its doc comment: "does not include images or hyperlinks"). |
| **iOS** | `a2702ab`, `277ea14`, `ba62617`, `96fd032`, `eae4122`, `301ed05`, `d298d60`, `aec009a`, `5e4d2a7` | No. |
| **Portable builds: Embedded, WASM, Web, Android** | `e84a016`, `ec1a0ca` (#691), `839d4fa` (#733), the `sirfergy` WASI series, `c4fda93` | Indirectly yes: this is the work that keeps the non-Apple core building, which is what the Linux daemon uses (section 6.1). |
| **Build, CI, benchmarks, docs** | `e213ebb`, `fccb899` (fixed-layout check), `7666e62`, `d54daf4`, `d4f52fa`, esctest series (`9a12573`, `300aa75`, `2930f58`, `846b3a4`), `36be5ae`, `28c6d1d` | The fixed-layout check and `PERFORMANCE.md` tell us how to add fields without slowing the hot path (section 9). |

### API that upstream removed, renamed or made private, and that the fork or Scape uses

All **[M]** by reading both sides (`git show upstream/main:<file>`), except where marked.

| Change | Who uses it |
|---|---|
| `LocalProcessTerminalView.dataReceived(slice:)` is `@available(*, unavailable)` (`a183c15`) | Scape overrides it and calls `super`: `Scape/Terminal/ScapeTerminalView.swift:1225,1267`; called in `ScapeTests/CodexDeliveryPolicyTests.swift` and `CursorDisplayTests.swift`. Compile error after the bump. |
| `Terminal.curAttr` and `Terminal.activeHyperlink` are `private` again; `payloadCodes` is gone (replaced by `payloads`, a private class) | fork `TerminalStateSnapshot.swift:275,317-324`, `TerminalReplicationDigest.swift` |
| `Buffer.savedWraparound` and `Buffer.savedReverseWraparound` removed (`1b1d50a`: DECSC no longer saves DECAWM) | fork `TerminalStateSnapshot.swift:351-352,520-521`, `TerminalStateSnapshotCoding.swift:537,578` |
| `BufferLine.noteWritten(upTo:)` is now `noteWritten(from:upTo:)`; new `usedStart` | fork `BufferLine.swift:190` (`replicationWritePacked`) |
| `Terminal.expireSynchronizedOutput()` now exists upstream too, returning `Void` (`e84a016`) | the fork's own `expireSynchronizedOutput() -> Bool`; Scape's harness calls it |
| Four new typed `sendResponse` overloads that write to the delegate directly | bypass the fork's `respondsToQueries` gate (section 4, item 1) |
| `TerminalEvent.programStatusChanged = 3` | collides with the fork's `synchronizedOutputEnded = 3` |
| Fork-only `SelectionMode.rectangular`: upstream expresses a block as `SelectionService.isBlock` + `startBlockSelection(bufferPosition:)` | Scape `ScapeTerminalView.swift:1380-1381` |

## 3. The overlap, file by file

Fork column: `git diff --stat 5cb37e865..1b21b1bf3` **[M]**. Upstream column: `git diff --stat 5cb37e865 upstream/main -- <same files>` **[M]**. "Trial merge" is section 4.

| File | Fork changed | Upstream changed | Trial merge |
|---|---:|---:|---|
| `Terminal.swift` | 206 | 2,299 | 6 conflict hunks |
| `Mac/MacTerminalView.swift` | 100 | 1,770 | 7 conflict hunks |
| `Apple/AppleTerminalView.swift` | 51 | 1,131 | 1 conflict hunk |
| `iOS/iOSTerminalView.swift` | 15 | 837 | 1 conflict hunk |
| `SelectionService.swift` | 67 | 647 | 5 conflict hunks |
| `EscapeSequenceParser.swift` | 92 | 558 | 1 conflict hunk (the parse loop's tail) |
| `Buffer.swift` | 14 | 468 | 1 conflict hunk |
| `BufferLine.swift` | 26 | 254 | auto-merged; will not compile (section 4) |
| `SearchEngine.swift` | 10 | 233 | auto-merged |
| `CharData.swift` | 37 | 201 | auto-merged |
| `Mac/MacLocalTerminalView.swift` | 7 | 92 | 1 conflict hunk |
| `Apple/FrameDriver.swift` | 7 | 81 | 1 conflict hunk |
| `CellStorage.swift` | 68 | 80 | auto-merged |
| `HeadlessTerminal.swift` | 11 | 41 | auto-merged; `onOutput` landed in the right place **[M]** (`trial/Sources/SwiftTerm/HeadlessTerminal.swift:94-97`) |
| `Pty.swift` | 48 | 37 | 1 conflict hunk |
| `SearchService.swift` | 15 | 28 | 1 conflict hunk |
| `KittyClipboardProtocol.swift` | 2 | 18 | auto-merged |
| `Apple/TerminalEventQueue.swift` | 79 | 7 | 1 conflict hunk |
| `README.md` | 13 | 59 | auto-merged |
| Tests: `CellStorageTests`, `SelectionTests`, `TerminalSnapshotTests` | 124 / 212 / 30 | 35 / 23 / 150 | auto-merged |
| The five new replication files (2,025 lines) | new | not present upstream | no conflict; all of the semantic risk |

The fork's other changed files (`AlternateScrollModeTests`, `MainHopCoalescingTests`, the replication tests, `TerminalEventQueueTests`, the three docs) were not touched upstream **[M]** (absent from the upstream diff stat above).

## 4. The trial merge

`git clone` of this repository into `~/Library/Caches/scape-build/it2001/trial`, detached at `1b21b1bf3`, then `git merge --no-commit --no-ff upstream-main` **[M]**. Result: **12 conflicted files, 27 hunks** (`grep -c '^<<<<<<< '` per file).

| File | Hunks | What collides | Mechanical or decision |
|---|---:|---|---|
| `Terminal.swift` | 6 | (1) the fork's DEC 2026 valve API against upstream's `TimeInterval` → `Double`; (2) `curAttr` made `private`; (3) `activeHyperlink` made `private` and `payloadCodes` replaced; (4, 5) mouse report encoding rewritten to return bytes, against the fork's `sendUserReport` rename; (6) `getRectangularText` at the end of the class | 1: mechanical, plus a duplicate-function clean-up. 2, 3: **decision** (5c). 4, 5: take upstream, then re-check the replica gate. 6: **decision** (5f) |
| `Mac/MacTerminalView.swift` | 7 | `public` on `search` and `cellDimension` (2); the fork's Option-bypass at mouse down, up and drag against upstream's held-Option block selection (3); an upstream-only insertion (1); the coalesced-event `case` (1) | 2 mechanical; 3 **decision** (5a); 1 take upstream; 1 follows 5b |
| `SelectionService.swift` | 5 | the fork's `.rectangular` branches against upstream's `isBlock` at the same five sites | **decision** (5a) |
| `Apple/AppleTerminalView.swift` | 1 | the fork's coalesced sync-end against upstream's frame-tick sync-end | **decision** (5b) |
| `Apple/FrameDriver.swift` | 1 | a fork test hook against upstream's `setLinkRunning` | keep both; follows 5b |
| `Apple/TerminalEventQueue.swift` | 1 | event numbers 3 and 4 against upstream's 3 | follows 5b |
| `iOS/iOSTerminalView.swift` | 1 | the same event `case` | follows 5b |
| `EscapeSequenceParser.swift` | 1 | the fork's sequence-boundary tracking at the tail of the parse loop upstream rewrote | **decision** (5d) |
| `Buffer.swift` | 1 | `private(set)` on three mode flags against upstream's new protection fields | mechanical (keep both); better as 5c |
| `Pty.swift` | 1 | the fork's `fdLimit` sample sits where upstream rewrote the lines before `forkpty` | mechanical: keep the fork's lines (5e) |
| `Mac/MacLocalTerminalView.swift` | 1 | the fork's degenerate-size guard against upstream's `syncProcessWindowSizeIfNeeded()` | small **decision** (5g) |
| `SearchService.swift` | 1 | `public` on `lastResult` against an upstream debug counter | mechanical: keep both |

### Step 5: it does not compile with mechanical resolutions, so no tests were run

Stopped at the list, as instructed. The merged tree needs real decisions before it can build, for three independent reasons, each read in the trial tree **[M]**:

- `Terminal.expireSynchronizedOutput()` is declared twice (`trial/Sources/SwiftTerm/Terminal.swift:646` from the fork, `:9298` from upstream).
- `BufferLine.replicationWritePacked` calls `noteWritten(upTo:)`, which no longer exists (auto-merged, no conflict marker).
- `TerminalStateSnapshot.swift` reads `buffer.savedWraparound` and `savedReverseWraparound`, which no longer exist.

One build attempt was spent, on a diagnostic variant and not on a merge candidate: the same merge with every conflict hunk taken from upstream (`git merge -X theirs`, in `trial-theirs`), `swift build --target SwiftTerm` behind the shared lock **[M]**. It failed with `Pty.swift:156: cannot find 'fdLimit' in scope` (log: `~/Library/Caches/scape-build/it2001/build-theirs.log`). The build stopped at that batch, so it is **not** a complete error list, and I did not run a second build. **No test of the merged tree was run; there are no test counts to report.**

### Semantic risk: what the replication code depends on that upstream changed

Read from `git show upstream/main:Sources/SwiftTerm/<file>` against the fork's five files. Line numbers are upstream's at `d4f52fa` unless they say "trial".

**Things that merge cleanly and are wrong** (the lesson both earlier findings docs headline):

1. **A replica would answer queries.** The fork routes every query response through `sendQueryResponse`, which a replica switches off (`respondsToQueries = false`). Upstream added four typed overloads, `sendResponse(_ bytes:)`, `(_ prefix:, _ text:)`, `(_ prefix:, _ bytes:)`, `(_ prefix:, _ text:, _ suffix:)`, that call `tdel?.send` directly (trial `Terminal.swift:7984-7999`) **[M]**. Git merged them beside the fork's gated variadic version with no conflict. Swift prefers a non-variadic overload **[I]**, so calls such as `sendResponse(cc.CSI, "…")` would go to the ungated ones: the daemon and the replica would both answer the child. This compiles. The fork's `ReplicationPrimitivesTests` (12 parameterised queries) and T3's "the replica sent nothing" rule should catch it **[I]**, but only for the queries they exercise; upstream also added new reports (`7f82ad2`, DECRQSS).
2. **The reflective digest cannot see into upstream's new state holders.** Upstream moved rarely used state behind single references to keep hot fields at fixed offsets: `Terminal.cold` (`ColdState`: DECSET 41 `moreFix`, the OSC 10/11 colour overrides; `Terminal.swift:3913-3927`), `reportedOnly` (DEC modes 18, 19, 35, 42), `payloads`, `programStatusStore`. `DigestDescriber.describe` falls to `String(describing:)` for a class instance (`TerminalReplicationDigest.swift:207-231`) **[M]**, which prints the type name **[I]**. So the digest's promise, "a stored property added later is compared automatically", silently stops holding for anything upstream puts in such a holder.
3. **State that changes with no byte behind it.** `HeadlessTerminal.processTerminated` now calls `terminal.programStatusProcessExited()` under the lock (trial `HeadlessTerminal.swift:73-76`) **[M]**. It is the same class of event as the DEC 2026 valve: the owner's state changes and no output batch tells the replica. Whether the program-status store is state a replica needs is a question for the S2 lead **[I]**.

**Things the snapshot must carry that it does not** (each is a stored property upstream added; found with a diff of stored-property names per class, base against upstream tip **[M]**):

| New state | Where (upstream) | Why the replication cares |
|---|---|---|
| `Buffer.pendingWrap`, `Buffer.savedPendingWrap` | `Buffer.swift:371`, `:210` | Before, "waiting to wrap" was `x == cols`, and the snapshot carried it for free in `x`. Now `x` is always a valid column and the flag is separate; **the `x` and `y` setters clear it** (`Buffer.swift:129,148`; commit `91f6bda`). The importer does `buffer.x = image.x` (fork `TerminalStateSnapshot.swift:504`). A replica imported at a pending wrap would print the next character over the last column instead of wrapping. T3's `hard-cuts` stream has a pending-wrap cut, so the tests would catch it **[I]**. |
| `Buffer.characterProtection`, `savedCharacterProtection`, `bulkInsertBlocked`; `Terminal.characterProtection`, `characterProtectionMode` | `Buffer.swift:207,342-345`, `Terminal.swift:717-720` | DECSCA/SPA state for the next printed cell. The per-cell `isProtected` bit is already carried. |
| `Terminal.keyboardActionMode`, `sendReceiveMode`, `backarrowKeyMode`, `reverseWraparoundExtended`, `noClearOnColumnChange` | `Terminal.swift:701-805` | modes; each needs a field or an exclusion with a reason |
| `Terminal.cursorStartsNewGrapheme` | `Terminal.swift:1940` | print-path state between feeds: it decides whether the next scalar joins the previous cell |
| `cold.moreFix`, `cold.foregroundOverride`, `cold.backgroundOverride` | `Terminal.swift:3913-3927` | DECSET 41; and OSC 10/11 colours are now **distinguishable from the host's theme**, which the snapshot findings named as an open problem for S2.4. Upstream solved it. |
| `BufferLine.usedStart` | `BufferLine.swift:128-147` | The invariant is now "every cell outside `usedStart ..< usedLength` equals the tail blank". The fork exports the prefix `0 ..< usedLength` by value, which stays correct **[I]**; the importer must call `noteWritten(from: 0, upTo:)`; the digest must exclude `usedStart` as it does `usedLength`. |
| removed: `Buffer.savedWraparound`, `savedReverseWraparound` | | two fields leave the format |

**The parser.** The fork records the open sequence at the single tail of the loop (`currentState = transition & 15`). Upstream kept that single tail (`EscapeSequenceParser.swift:1570`) **[M]**, removed the `input` variable the fork's hunk mentions, and added paths around the per-byte loop:

- a whole CSI sequence dispatched in one step (`simpleCsiLength` / `dispatchWholeCsi`, `:934-1007`, called at `:1448`): it sets the transition to ground and falls through the tail, so the hook sees a closed sequence. Safe **[I]**.
- continuation bytes of an OSC or APC consumed before the loop starts (`:1281-1291`): they continue a sequence from an earlier batch, which the hook's "start = 0" case covers **[I]**.
- `finishProgramStatusSt` writes `self.currentState` directly (`:1176-1188`), outside the loop's local variable. This is the one new place where the state the hook reads can change without passing the tail. It needs a targeted test **[I]**.
- `Terminal.readingBuffer.putbackBuffer` (the partial UTF-8 character) still exists (`Terminal.swift:1914-1931`) **[M]**, so `hasPendingSequence` keeps its meaning.

So the property the replication needs (a cut is taken between feeds; `pendingParserBytes` puts a fresh parser in the same state) survives in upstream's design, but it must be re-proved, not assumed. The fork's every-byte corpus is the proof.

**The DEC 2026 valve.** Upstream restructured the watchdog into `applySynchronizedOutputWatchdog` and added a delegate method, `scheduleSynchronizedOutputTimeout(source:afterMilliseconds:)`, so that an Embedded host runs the timer itself (`Terminal.swift:104`, `:9138-9190`) **[M]**. The fork's `guard !synchronizedOutputTimeoutDisabled` landed inside the new function (trial `:9260`) **[M]**; whether that is the right spot relative to the cancel branch must be read during the merge.

## 5. A recommendation for each decision

Judged by what the daemon work needs: the daemon owns each terminal with no view, on macOS and headless Linux; the app is a replica built by import plus a stream; selection, scrolling and rendering live only in the app.

### 5a. Block selection: take upstream's. Confidence: high

- **Keep:** upstream's `isBlock`, `startBlockSelection(bufferPosition:)`, `selectedColumns`, `blockText()` and the held-Option press in `MacTerminalView` (`10043e7`). **Drop:** the fork's `SelectionMode.rectangular`, its branches in `SelectionService`, `optionBypassesMouseReporting`, and (5f) `getRectangularText`.
- **Why:** upstream's is a superset. With mouse reporting on, it holds an Option press: a drag selects a block and the application gets nothing; a release in place sends the application the click it would have had. Its commit message says why: "Claude Code moves its input cursor on one." The fork's version swallows that click. Both renderers and upstream's snapshot code share one column rule that knows blocks. Dropping the fork's version removes 9 of today's 27 conflict hunks (5 in `SelectionService`, 3 in `MacTerminalView`, 1 in `Terminal`) and stops them recurring **[M]** (the hunk counts in section 4).
- **Daemon fit:** selection is view state. `SelectionService` reads `terminal.displayBuffer`, so it works on a `Terminal` filled by `importState` exactly as on one fed by a PTY **[I]**. The snapshot deliberately does not carry selection.
- **Scape call sites:** one. `Scape/Terminal/ScapeTerminalView.swift:1374-1384` starts a rectangular selection on Option + single click (`selection.setSelection(start:end:)` then `selection.selectionMode = .rectangular`). After the merge, delete that block and let the view handle Option-drag, or replace the two lines with `selection.startBlockSelection(bufferPosition: pos)`. `selection.setSelection` at `:1414` (Scape's own word expansion) is unchanged: the method is still public **[M]**.
- **Behaviour lost:** Option + click no longer starts a zero-size selection at once; the block starts when the pointer moves past the drag threshold. I found no Scape code that depends on the old behaviour **[M]** (`git grep` for `.rectangular`, `selectionMode`: one site).
- **Cost:** 0.5 day in the merge; the fork's 9 `testRectangular*` tests **[M]** (`grep -c` in `SelectionTests.swift`) are replaced by upstream's block tests.
- **Re-test:** Option-drag in a plain shell and inside Claude Code and vim; Option-click in Claude Code moves its cursor; copy of a block with wide characters; Shift-click extends.
- **Would change my mind:** a Scape feature that needs to start a block selection programmatically with no drag. `startBlockSelection` covers that, so I do not expect one.

### 5b. Sync-end and main-thread hops: upstream's mechanism, and move the fork's title coalescing onto it. Confidence: medium-high

- **Keep:** upstream's `a329fc7` (the latest scroll position, cursor style and cursor colour are recorded under a lock and applied once at the next frame tick) and `56ffb52` (a dirty mark posts no main-actor task while the display link runs). **Drop:** the fork's `synchronizedOutputEnded` event and `applyCoalescedPayloadEvent`'s sync branch. **Keep, re-expressed:** the fork's **title** coalescing. Upstream still posts one main-queue block per title change (`MacTerminalView.swift:3947-3951`) **[M]**, and an agent CLI animates a spinner in the title every frame; the IT-1075 freeze had both halves (fork commit `44c2c5d`). Put the latest title in upstream's `crossThreadState` and apply it in `applyPendingViewUpdates`, which is the shape upstream would accept as a PR.
- **Which is better for many agents streaming at once:** upstream's, for the sync-end half. The fork allows one outstanding main block per terminal; upstream allows none while the frame driver runs. Upstream measured 343,486 → 1,467 hops and about −25% elapsed on its PTY benchmark **[M]** (their numbers, their machine).
- **Do the fork's measurements still hold?** Not established. The IT-1075 numbers (about 140,000 enqueues a second, a dozen agent terminals) were taken on the fork's mechanism. They must be re-taken on the merged base with the same repro. `MainHopCoalescingTests` (222 lines) must be re-fitted to the new mechanism.
- **Daemon fit:** both mechanisms are view code (`Apple/`, `Mac/`, `iOS/`), which Linux excludes and `HeadlessTerminal` never touches **[M]** (the files in each commit's stat). The frame tick decides when the **view** updates its scroller and calls `scrolled`; the terminal's own `synchronizedOutputActive` flag is still flipped by the parser under the terminal lock (`Terminal.swift:9104-9126`) **[M]**. So the ruling "the DEC 2026 valve opening is an ordered host event in the daemon's session ring" is untouched: a daemon terminal with no view has no frame driver and needs none. In the app, a replica view fed by import plus a stream gets the same frame-tick behaviour as a PTY-fed one **[I]**.
- **Cost:** 0.5 to 1 day including the re-fitted tests. **Re-test:** the IT-1075 repro (a dozen agents in tight frame loops), the scroller position after a burst, title updates landing, `FrameDriverTests`.
- **Would change my mind:** a re-measurement showing the main queue still grows under the IT-1075 repro on upstream's mechanism.

### 5c. `curAttr` / `activeHyperlink` private: one accessor block per class, and the fork's new fields behind `cold`. Confidence: high

- Upstream made these private on purpose: it now checks in CI that hot-path types keep a fixed layout, and documents that a new stored property in `Terminal` costs 4 to 8% cycles because it moves the hot fields after it **[M]** (`fccb899`; `PERFORMANCE.md`, "New stored properties in `Terminal`").
- **Smallest accessor that keeps upstream's intent:**
  - `curAttr`: use the existing public `currentAttribute` getter to read, and the already-internal `setCurrentAttribute(_:)` to write. No change to the declaration.
  - `activeHyperlink`: add two internal members beside it in `Terminal.swift`: `var replicationActiveHyperlinkTarget: String??` (nil / open / unavailable) and `func replicationSetActiveHyperlink(_:)`. Leave the enum and the property private.
  - The same for every other widening the replication commits made (about 30 declarations changed from `private` or `private(set)` to internal in `Terminal.swift`, 7 in `Buffer.swift`) **[M]** (`git diff ee7c4a3..HEAD`): revert them and add one contiguous, marked block of internal accessors per class. Each widened declaration is a line upstream also edits; three of today's hunks (Terminal 2 and 3, Buffer 1) are exactly that.
  - Move the fork's new stored fields on `Terminal` (`respondsToQueries`, `synchronizedOutputTimeoutDisabled`) into upstream's `cold` holder, as its own guidance says.
- **Cost:** 0.5 day, and it can be done **before** the merge on the current base with zero behaviour change, proved by the existing T3 run. **Re-test:** fork replication tests, Scape T3, `scripts/check-fixed-layout.sh` after the merge.
- **Would change my mind:** nothing I can see; this is cheaper than the alternative at every future merge.

### 5d. The parser's sequence-boundary tracking: same place, one function, proved by the every-byte corpus. Confidence: medium

- **Where it hooks now:** still at the loop's single tail (`EscapeSequenceParser.swift:1570`), plus one explicit note where `finishProgramStatusSt` changes state outside the loop. Rewrite the fork's 20 inline lines as one `@inline(__always)` function called from the tail, so the conflict surface is one line.
- **Perf risk:** the hook adds a compare and a branch per table transition, not per printable byte (printable runs and CSI digits `continue` before the tail; whole CSI sequences reach it once) **[M]** (reading the loop). Upstream's rule is that a parser change must stay within about 1.5% on its headless suite **[M]** (`PERFORMANCE.md`). Run `Tools/SwiftTermBenchmarks` A/B once after the merge. The parser's two new stored fields (`pendingSequenceBytes`, `pendingSequenceOverflowed`) sit in the parser, not in `Terminal`; the fixed-layout check does not list the parser **[M]**.
- **Longer term:** offer it upstream as an opt-in (a `pendingInput` API is useful to any host that snapshots a terminal). Until then it is the single most fragile line in the fork.
- **Cost:** 0.5 day. **Re-test:** fork `TerminalStateSnapshotTests` (12 synthetic streams cut at every byte), `ReplicationPrimitivesTests`, Scape T3 full sweep; add cuts inside an OSC 7501 and inside a CSI that the whole-CSI path would have taken had it been complete.
- **Would change my mind:** a benchmark regression above 1.5%, in which case record the boundary only when a host asks (a flag read once per `parse` call).

### 5e. Pty: keep the fork's close loop, and take upstream's fix too. Confidence: high

- They are different fixes. Upstream's `eb710ea` only changes `LocalProcess.swift` so its own private duplicate descriptor is close-on-exec **[M]** (`git show eb710ea`). The fork closes every descriptor ≥ 3 in the child before exec, which protects against descriptors leaked by **any** thread of a large app (the IT-301 wedge). Upstream's `Pty.swift` has no such loop **[M]**.
- The conflict is only adjacency: upstream rewrote the lines before `forkpty`. Keep the fork's `fdLimit` block. Mechanical.
- **Daemon fit:** the daemon becomes the parent of every session and is itself multithreaded, so the close loop matters more there, and on Linux too. `getdtablesize()` exists on Glibc **[I]**; the comment's Darwin-specific reasoning should gain a Linux line.
- **Re-test:** `ScapeTests/PipeFDInheritanceTests`, upstream's new `LocalProcessLifecycleTests`. **Offer upstream:** yes, first (section 8).

### 5f. `getRectangularText`: delete it. Confidence: high

Follows 5a. Upstream's `blockText()` does the same job and copies a wide character cut by the edge whole. The fork's function has one caller, the `.rectangular` branch at `SelectionService.swift:950`, and none in Scape **[M]** (`git grep getRectangularText` in both). It is also the function that landed inside the wrong class in the September merge.

### 5g. The degenerate-size guard: keep it, inside upstream's function. Confidence: high

Upstream's `syncProcessWindowSizeIfNeeded()` skips an unchanged size but has no minimum (`MacLocalTerminalView.swift:337-347`) **[M]**. Put `guard size.ws_col >= 2, size.ws_row >= 1 else { return }` inside it, so both of its callers are covered (the fork's guard covered one). Offer it upstream as a bug fix. The daemon needs the same rule on its own resize path, which is Scape code, not this file. **Re-test:** open a tab, Tab-complete at once; the IT-304 QA script.

### Other hunks

- **The valve API (Terminal hunk 1):** keep the fork's `synchronizedOutputTimeout: TimeInterval?` (store it as `Double`, in `cold`), delete upstream's `Void`-returning `expireSynchronizedOutput()` in favour of the fork's `Bool`-returning one, or better, offer the `Bool` version upstream so there is one. Confidence: high.
- **Mouse report encoding (Terminal hunks 4, 5):** take upstream. Its functions return bytes; the caller that sends them is user input and must not be gated by `respondsToQueries`. Check that single call site. Confidence: high.
- **The `sendResponse` overloads (no conflict; section 4, item 1):** route all four through `sendQueryResponse`, and replace the "wrapper" approach with a rule a test can pin: outside two named functions, no source line in `Sources/SwiftTerm` calls `tdel?.send`. Confidence: high.

## 6. The daemon questions

### 6.1 Linux

- Upstream's manifest still excludes `Apple`, `Mac` and `iOS` on Linux, and no shared source imports an Apple framework without a guard **[M]** (`git grep -E '^import (AppKit|UIKit|CoreText|…)' upstream/main -- Sources/SwiftTerm` outside those three directories: no hits). The 18 new shared files are portable (`Portable/…`, `ByteRunScanner`, `TerminalRowStore`, …).
- Upstream runs a Linux job, `linux-headless`, in `swift:6.2-jammy`, the same Swift line as Scape's `swift:6.2-noble` **[M]** (`.github/workflows/xcode.yml`; the T2 findings doc). At the tip its two build steps pass and its test step **fails**, and has on every push since `58553a6` on 2026-11-04 **[M]** (`gh api …/actions/workflows/xcode.yml/runs`; the failed step is "Run headless tests").
- The failure is `ByteRunScanner.swift:208: Fatal error: Unexpectedly found nil` in the test `wordAndVectorScansAgreeWithScalarSearches` **[M]** (the job log). Line 208 force-unwraps `buffer.baseAddress` in the code path compiled for Swift older than 6.4; the test calls the vector scan directly with an empty span. The parser's own callers only reach it when at least 16 bytes remain (`ByteRunScanner.swift:49-53`) **[M]**, so the daemon's path should not hit it **[I]**. Because the run aborts there, upstream has **not** verified any later Linux test for nine days.
- **What this means for the merge:** build risk on Linux is low; test confidence on Linux must come from us. Fix the unwrap in the fork (one guard), offer it upstream, and run the fork's own tests in the 6.2 container once. Scape's Linux CI runs Scape's tests against SwiftTerm, not SwiftTerm's own test target **[I]**, so it would not have caught this.
- **Helps:** the Embedded/WASM/Android series forces upstream to keep the core free of Apple-only code and of Foundation types in hot classes. **Threatens:** code that differs by compiler version (`#if compiler(>=6.4)`), where macOS and Linux run different branches; it appears in `ByteRunScanner` today.
- I did not build on Linux. Everything here about Linux is from upstream's CI and from reading code.

### 6.2 The daemon owns the terminal

| Conflict | Which side fits "daemon owns, app replicates" |
|---|---|
| Block selection | upstream; selection is app-side and works on an imported terminal (5a) |
| Sync-end | either; both are view code and neither touches the daemon's terminal (5b). Upstream's is better for the app. |
| Private state | upstream's layout discipline is in the daemon's interest: the daemon is the process that parses every session's output (5c) |
| Parser hook | fork's hook, kept small; the property it needs survives (5d) |
| Pty | fork's loop; the daemon is the parent of every session (5e) |
| Valve | fork's API. Upstream's Embedded path already asks the **host** to run the DEC 2026 timer through a delegate method, which is the same idea as the ruling. A daemon could use that shape on all platforms if upstream accepted it. |

### 6.3 The snapshot format

**A merge forces a format revision before S2.2/S2.3 use it.** The screen part (`STSS`) must gain `pendingWrap` and `savedPendingWrap` per buffer, the protection flags, the new modes and `cursorStartsNewGrapheme`, and lose `savedWraparound` and `savedReverseWraparound` (section 4). History chunks (`STSH`) carry lines and cells only; nothing upstream did adds per-cell or per-line state that the cell image lacks (`isProtected`, the hyperlink target and semantic content are already there; `usedStart` is derivable; images are still declared lost) **[I]**, so `STSH` v1 probably stands.

**It is cheaper now.** The encoded form is defined as "for two processes of the same build" and the decoder refuses any other version (fork `TerminalStateSnapshot.swift` header) **[M]**. Today no installed daemon writes or reads it, so the revision costs the code change and nothing else. Once a daemon outlives an app update, a version change needs a rule for a mismatched pair. Recommendation: call the revised format version 2 at the merge, with no version 1 reader kept.

### 6.4 Timing against the daemon queue

S2.2 (data frames and bounded queues on the bus) does not touch SwiftTerm **[I]** (from the S2 plan's row for S2.2: "bus lane"). S2.3 (the session host on `HeadlessTerminal`) calls the public replication API. S2.4 rebuilds `ScapeTerminalView` (1,541 lines on `LocalProcessTerminalView`) as a passive replica view; upstream changed `MacTerminalView.swift` by 1,770 lines and `AppleTerminalView.swift` by 1,131 in this window **[M]**.

| | Merge **before** S2.3 goes deep (now, beside S2.2) | Merge **after** S2.2/S2.3, before S2.4 | Merge after the daemon release |
|---|---|---|---|
| Effort | about 6 days (5 to 8) | about 6 to 8 days | about 8 to 12 days |
| Upstream commits to absorb | 163 | about 200 to 230 at the current rate | 300 or more |
| Replication code to re-fit | 2,025 lines, 0 callers in the app | the same, plus S2.3's uses | plus S2.4's view |
| Format change | free | free if nothing has shipped | needs a mismatch rule |
| Risk | medium: one large merge, with soak time before any release | medium | high: two moving targets, and the view surgery done twice |
| Cost | delays the SwiftTerm-dependent part of S2.3 by about a week; S2.2 is unaffected | S2.3 is built once on fields that then change | |

All effort figures are **[I]** estimates. **Recommended: the first column.** Reason: S2.4 is the step the plan itself calls risky AppKit surgery, and doing it on a view base that is about to change by thousands of lines is the expensive mistake to avoid; the format argument (6.3) makes "now" better than "just before S2.4".

### 6.5 Performance the daemon needs

- The daemon's cost per session is the parse and scroll path (no rendering). Upstream's gains there since the base, by its own benchmarks **[M]** (`PERFORMANCE.md`; commit messages): OSC 9 progress parsing about −26% feed time; short whole OSC sequences 20 to 27% faster; OSC 8 redraws about −12% and no more link exhaustion; the scroll path's retain/release pairs removed (`1a64da4`, `a1aa912`, `53bb506`), only written cells cleared (`be5c0a8`), whole CSI sequences and lone scalars without the per-byte path (`9655a1c`), a faster UTF-8 print path (`309adcc`). I found no single headline number for the whole window and did not run the benchmarks.
- For the **app**, the main-thread work (5b) is the material one: about −25% elapsed and 99.6% fewer main-queue hops on a synchronized-output workload.
- **Interaction with the fork's lazy cell arena (IT-1016):** `CellStorage.swift` auto-merged (fork 68 lines, upstream 80, mostly `768c4f0`'s attribute cache in front of the intern dictionary) **[M]**. Whether the cache and the lazily grown attribute table compose correctly was not tested; the fork's `CellStorageTests` (124 added lines, including the full-growth test) are the check. **[I]** medium risk, cheap to verify.
- **Interaction with the event-queue coalescing (IT-1075):** direct; see 5b.

### 6.6 What to design differently now, so every later merge is cheap

| # | Change | Who | When |
|---|---|---|---|
| 1 | **One accessor block per class** for everything the replication reads or writes; revert the `private` → internal widenings (5c). | the S2.1 builder (loom), or whoever holds the fork lane | before the merge |
| 2 | **A field census test**: `Mirror` labels of `Terminal`, `Buffer`, `BufferLine`, **and of every reference-typed holder they contain** (`cold`, `reportedOnly`, `payloads`, …) must equal "carried by the snapshot" ∪ "excluded with a reason". A new upstream field then fails the build of the tests at merge time, whether or not a corpus stream happens to set it. Today a new field is caught only if a stream exercises it, and not at all inside a class holder (section 4, item 2). | the S2.1 builder | with the merge |
| 3 | **One choke point for output to the child**: exactly two functions may call `tdel?.send` (a query response, gated; user input, not gated), pinned by a source-scan test in the style of Scape's `SnapshotFormatT3ClockPinTests`. | the S2.1 builder | with the merge |
| 4 | **The parser hook as one function** at one line, with the upstream offer in section 8. | the fork lane | with the merge |
| 5 | **New fork state on `Terminal` goes in `cold`**, never as a new stored property (upstream's 4 to 8% rule). | the fork lane | with the merge |
| 6 | **A list of "state changes with no byte"** (the valve, `programStatusProcessExited`, any timer): each one is either an ordered host event in the daemon's ring or excluded with a reason. S2.3 should own this list. | the S2 lead | S2.3 design |
| 7 | **Delete `TerminalReplayStream.swift`** (283 lines). T3 dropped the byte-stream format; it reads the same internals and must be re-fitted at every merge for a format nobody uses. Scape references it once, in a measured-not-required test (`TerminalReplicationHarness.swift`) **[M]**. | the S2 lead decides; the S2.1 builder deletes | before the merge |
| 8 | **Linux CI on the fork** (`swift build` and the replication tests in `swift:6.2-noble`). The fork has none **[M]** (T2 findings). | the fork lane | with the merge |
| 9 | **A weekly canary**: a scheduled job that trial-merges `upstream/main`, reports the conflict count and runs the replication tests when it compiles. Drift then shows up as a number, not as a surprise. | the fork lane | after the merge |

## 7. What Scape would need

**Source changes** (`git grep` at `f63b5c5f6`) **[M]**:

| Scape file | Why |
|---|---|
| `Scape/Terminal/ScapeTerminalView.swift:1225-1267` | overrides `dataReceived(slice:)`, now unavailable. Its own comment (`:1117-1125`) already says the override only sees direct feeds. Rename it to a Scape method that calls `feed(byteArray:)`, and move the live path to `setProcessOutputHandler(_:)`. |
| `ScapeTests/CodexDeliveryPolicyTests.swift`, `CursorDisplayTests.swift` | call that method |
| `Scape/Terminal/ScapeTerminalView.swift:1374-1384` | the Option-click rectangular selection (5a) |
| `Headless/Tests/TerminalReplicationHarness.swift`, `SnapshotFormatT3Tests.swift` | `expireSynchronizedOutput`, `exportReplayStream` (if item 7 is taken), the format version, any new exclusion names |
| `Package.swift:403` and `Scape.xcodeproj/…/Package.resolved` | the pin; `scripts/check-headless-core.py` compares the two |

Names I checked and found unaffected: `withTerminal` (25 uses), `userScrolling` (15), `resizeSuspended` (5), `calculateMouseHit` (5), `getText(maxUTF8Bytes:)` (5), `setTerminalTitle`, `scrolled(source:)`, `func scrollWheel` override, `HeadlessTerminal`, `LocalProcess`. "Unaffected" means the declaration still exists with the same shape upstream or is fork-owned and merged cleanly; it is **[I]** until Scape compiles against the merged fork. One left to check at compile time: Scape's single use of `setCursorColor`/`caretColor`, since `8543190` changed how the view applies cursor colour.

**The safety net, in the order to run it after a pin bump:**

1. Fork: `swift test` (all), then `swift test -c release -Xswiftc -enable-testing --filter ReplicationSizeTimeTests`; `scripts/check-fixed-layout.sh`; the same in the Linux container.
2. Scape headless: `scripts/run-headless-tests.sh` (the 16 `SnapshotFormatT3*` classes and `SwiftTermHeadlessTests` are in `Headless/required-tests.tsv`), then the full sweep `SCAPE_T3_FULL=1 swift test --filter SnapshotFormatT3`: 1,238 of 1,238 cuts whole and streamed, 8 resyncs, comparator 2,440 of 2,440 are the numbers to reproduce (the snapshot findings doc).
3. Scape Linux CI, amd64 and arm64.
4. Xcode: the 15 `ScapeTests` files that import SwiftTerm, especially `PipeFDInheritanceTests`, `CodexDeliveryPolicyTests`, `CursorDisplayTests`, `ComposerDeliveryGateTests`, `ShellTerminalSpectatorTests`, `TerminalRedrawGateTransitionTests`, `SwiftTermViewFocusGuardTests`, `KimiStatusAndScreenTests`.
5. By hand (Nash, about an hour): Option-drag and Option-click in a shell and in Claude Code; wheel and trackpad in a shell, `less` and vim; resize while a tab is hidden, then show it; a dozen agents streaming with title spinners (the IT-1075 repro); find-in-terminal; IME input; a window moved between displays.

## 8. The fork's size: what could go upstream

From commit subjects, the two earlier findings docs and the diffs read above; the "odds" column is my judgement **[I]**. Three of the 33 are PR merge commits and two are upstream merges.

| Fork commits | What | Offer upstream? | Order |
|---|---|---|---|
| `bde965d`, `6b064a3`, `25371d2` | close every fd ≥ 3 in the child before exec | **Yes.** Upstream just fixed a narrower fd leak (#719), so the topic is live. Good odds. | 1 |
| (new, one line) | guard the empty span in `ByteRunScanner` on Swift < 6.4; turns upstream's Linux CI green | **Yes.** Very good odds; buys goodwill. | 1 |
| part of `1dd10ec` | the degenerate-size guard before TIOCSWINSZ | **Yes**, as a bug fix. Good odds. | 2 |
| `7e49564` | `synchronizedOutputTimeout: nil` and a `Bool`-returning `expireSynchronizedOutput()` | **Yes.** Upstream already has the function name and a host-run timer for Embedded. Good odds. | 2 |
| half of `44c2c5d`, `7686209` | title changes coalesced, re-expressed on `crossThreadState` | **Yes**, after the merge. Good odds: it completes `a329fc7`. | 3 |
| `9500a26`, `f821547` | attribute table grown lazily | **Yes**, with a memory number. Medium odds. | 3 |
| `e52bf9d` (parts) | `HeadlessTerminal.onOutput`; `respondsToQueries` | **Yes**, as two small PRs. Medium odds; useful to any multiplexer or replica. | 4 |
| `e52bf9d` (part) | `pendingParserBytes` | **Yes**, as an opt-in. Medium-low odds: it touches the hot loop. | 5 |
| `c04d656`, `4f6bcc5`, parts of `1dd10ec` | `public`/`open` grants (`userScrolling`, `scrollWheel`, `selection`, `search`, `cellDimension`, `lastResult`) | **Ask first.** Upstream documented its access boundaries on purpose (`a1ec089`). Medium odds each. | 5 |
| part of `c137ddb` | selection auto-scroll made atomic under the terminal lock | **Yes** if upstream still has the race (not checked). | 5 |
| part of `c137ddb` | wheel → arrow keys on the alternate screen without DECSET 1007 | Only as an option; upstream chose the gated behaviour. Low odds. | later |
| `d837d66` | `getText(maxUTF8Bytes:)` | Probably **replace** with upstream's bounded snapshots (#673) or `visibleRowsText` (#711) rather than offer. Needs a look at Scape's 5 uses. | later |
| `16887ed`, `b97855a` | rectangular selection | **No: delete** (5a). | at the merge |
| `1f1e997`, `1cbf180`, `4008276` | wheel forwarding; SyncDebug stub | already dropped in earlier merges | |
| `ba15b70`, `36d4061`, `b93104d`, `f259cfd`, `a3dab0d`, `a6edbca` | state export/import, coding, history streaming, the digest, the replay stream | **Scape-specific for now.** 2,025 lines against private internals; upstream is going a different way (content and render snapshots). Delete the replay stream (6.6 item 7). Revisit once the daemon has shipped and the format is stable. Low odds today. | not now |
| `d0d66e9`, `a1ed466`, `175d386`, `4b12f40`, `57bbd81`, `ee7c4a3`, `1e629f2`, `1b21b1b` | fork notes, findings docs, merges | never | |

If the first three rows and the deletions land, the fork's permanent surface outside the replication files drops to the access grants, the alt-screen wheel rule, `resizeSuspended` and the parser hook **[I]**.

## 9. Options, and the recommendation

| Option | Effort | Risk | What it buys |
|---|---|---|---|
| **A. Merge now, beside S2.2, before S2.3 uses the replication code in earnest (recommended)** | about 6 days (5 to 8) + 1 hour of Nash | Medium | Every fix in section 2; the format revised while free; S2.3 and S2.4 built once on the current base; the fork made cheaper to keep (6.6) |
| B. Merge after S2.2/S2.3, before S2.4 | about 6 to 8 days | Medium | The same, a few weeks later; S2.3 re-fitted once |
| C. Merge after the daemon release | about 8 to 12 days | High | Nothing extra; avoids a delay now |
| D. Cherry-pick named fixes only | 1 to 2 days per batch | Low now, rising | A few fixes. Of 21 valuable commits tried one by one on the fork tip, **8 apply cleanly and 13 conflict** **[M]** (`git cherry-pick -n` in `picks`). Clean: `b5338ba`, `4d5eeea`, `cd2f6c7`, `65cbcca`, `36639b8`, `2f573f7`, `3e6c694`, `ba89378`. Conflicting: `12de993`, `fb1f1dd`, `41502dc`, `ca5dbee`, `37cc25e`, `a2706d2`, `eb710ea`, `9fc2d2f`, `46e8a24`, `56ffb52`, `a329fc7`, `15fed4f`, `cb4ce94`. Each pick also makes the eventual merge slightly harder. The link-exhaustion fix, the performance work and the memory-safety fix are all in the conflicting set. |
| E. Stay put | 0 | Grows about 2.4 commits a day | Nothing |

**Recommendation: A.** Confidence medium-high. What would change my mind: (1) the S2 lead says S2.3 must start on SwiftTerm internals this week and cannot wait five days, in which case take B and hold S2.4 behind the merge; (2) the merge lane finds a correctness regression in the merged engine that upstream has not fixed, in which case merge to the last upstream commit before it; (3) the IT-1075 repro regresses on upstream's main-thread mechanism (5b).

### Order of work for option A

| Step | What | Days |
|---|---|---:|
| 0 | Decisions confirmed by the S2 lead: 5a to 5g, the format becomes version 2, the replay stream is deleted | 0 |
| 1 | **Fork PR, on today's base:** the accessor blocks, fork fields behind a holder, delete `TerminalReplayStream.swift`, the parser hook as one function. No behaviour change; proved by the existing fork tests and Scape's T3 on the current pin | 0.5 to 1 |
| 2 | **Fork PR, the merge:** resolve the 27 hunks as section 5 says; audit every auto-merged file against both sides (the items in section 4 are the known ones: the `sendResponse` overloads, the duplicate `expireSynchronizedOutput`, the event numbers, the valve guard's position, `noteWritten`); the `ByteRunScanner` guard | 2 |
| 3 | **Same PR or the next:** the format revision (pending wrap, protection, new modes, `cold`), the field census test, the choke-point test, the title coalescing on upstream's mechanism | 1 to 1.5 |
| 4 | Fork tests on macOS and in the Linux container; the fixed-layout check; one benchmark A/B for the parser hook | 0.5 |
| 5 | **Scape PR, the pin bump:** the two source changes in section 7, the harness updates, the full T3 sweep, Xcode tests, Linux CI | 1 to 1.5 |
| 6 | Nash's hands-on check (section 7, item 5); IT-1075 re-measured | 1 hour + 0.5 |
| 7 | Upstream PRs, order 1 and 2 of section 8 (can trail) | 0.5 |

Steps 1 and 7 can be separate fork PRs. Steps 2 and 3 should be reviewed together, because the merged tree is not correct until the format revision lands.

### Cadence afterwards

Merge every two to three weeks, or when the canary (6.6 item 9) reports more than about 60 upstream commits or a first conflict in a replication-adjacent file, whichever comes first. Pick a target commit whose `linux-headless` job is green, or whose failure is understood. At 2.4 commits a day, three weeks is about 50 commits, which with the accessor blocks and the deletions in place should be a half-day job **[I]**.

## Limits of this document

- No merged tree was built to completion and no test was run on one. Every statement about what the tests "would catch" is inferred.
- Nothing was built or run on Linux; the Linux findings come from upstream's CI results and from reading code.
- Upstream's performance numbers are upstream's, on its machines.
- The effort figures are estimates from the size and nature of the conflicts, not from a timed attempt.
- The theme table is built from commit subjects and bodies; I read the diffs only for the commits that section 4 and section 5 cite.
