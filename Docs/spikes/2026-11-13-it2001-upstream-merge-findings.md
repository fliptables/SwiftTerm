# IT-2001 upstream merge (PR B): findings record

Branch `2001-upstream-merge-b`, fork PR #6. Merge of upstream `d4f52faaa` into the fork's
`scape-selection-api` at `7ec59163a`; merge commit `e768bfa77`. The plan (rev 3) asks for this
record in section 6, item 6. Line numbers are at `5450d92` unless a line says otherwise.

Sections are added as the work lands. Still to come: the whole-fork performance comparison against
upstream, the inventory of fork code by path, format v2 and the census, C3's list of state changes
with no byte, and the Linux baseline.

## D4: export only at ground (lead 14's ruling (B))

**What is built.** `Sources/SwiftTerm/EscapeSequenceParser.swift` is upstream `d4f52faaa`'s file, byte
for byte. It was restored with `git checkout d4f52faaa -- <path>`, and
`git diff d4f52faaa -- <path>` is empty. `ExportAtGroundTests.theParserFileIsUpstreams` pins the
file's SHA-256 (`986e60d2…6045`).

`exportState()` and `exportForStreaming()` return nil ("wait") whenever `hasPendingSequence` is
true, meaning the parser is not at ground or a cut UTF-8 character is held. There is one guard. It
has no size bound, scans nothing and retains nothing. At ground, the snapshot's pending field is
empty.

These were removed:
- the sequence-boundary hook, its locals and its record
- the flag `Terminal.recordsPendingParserBytes`
- `Terminal.pendingParserBytes` (public, fork-only)

`TerminalStateSnapshot.pendingParserBytes` stays as a format v1 field. It is always empty, and it
is dropped in v2.

**Why.** The hook failed the 1.5% bar even with the flag off. Measured by instructions against
upstream's loop, in both orders:

- `hardening_osc_short_chunked`: +14.8%
- `hardening_osc_bounded_chunked`: +5.8%
- every other case: +0.3 to +1.2%

A one-change-at-a-time test located the cost in the in-loop call site, even though that call is
never taken. Removing only that call left +0.4%. Making it `@inline(never)` still cost +14.6%; making
both calls `@inline(never)` cost +2.6%.

Nash ruled that the parse loop carries no fork code.

**The cost, stated.** An attach or resync waits while a sequence is open. That covers an image
transfer, a stalled link, or binary output that leaves the parser inside a string. Before this PR,
the export with an over-large open sequence exported an empty pending field: a defect in fork-only
code (`ba15b70`, `a3dab0d`). Now that case is just one more wait.

**Designs not taken.** The lead withdrew (C); (S) is the recorded upgrade over (B).
- (C) was to retain the raw bytes and re-scan them at export. It is struck.
- (S) is to serialize the parser's fields at export, with a parser census and an every-cut oracle.
  It lands in format v2, and only if #1289's measured waits show that export mid-sequence is needed
  and the engine stays.
- For IT-2015's record: if (B)'s wait is ever measured bad, the FIRST upgrade to consider is
  libghostty's continuation design:
  - one check per feed call, at the wrapper;
  - a search of that one feed for the last ESC;
  - canonicalising only at export;
  - off by default.

  (S) is second.

**Plan §2 corrected.** `exportState` and `exportForStreaming` are fork-only (`ba15b70`, `a3dab0d`),
and they now return an optional. The plan's "same shape" table is wrong on both counts.

**Owed in Scape (#1289, session host `tether-1149-s23` @ 46faf0eff), not in this PR.** Two product
sites read the removed symbol:

    Headless/Runtime/Sessions/HostSession.swift:394
        guard terminal.pendingParserBytes != nil else { throw SessionAttachError.snapshotUnavailable }
    Headless/Runtime/Sessions/HostSession.swift:437
        guard terminal.pendingParserBytes != nil else { throw SessionAttachError.snapshotUnavailable }

Both switch to `exportState() == nil` (or `hasPendingSequence`) at the pin bump. #1289's gate also
owes three things:
- a counter of export waits, and the longest wait;
- one test that an attach during an open sequence shows a waiting state;
- that the same attach blocks nothing and is served at the next ground.

## Whole-fork headless A/B against upstream (macOS, instructions, 2026-11-13)

The compared trees were:

- **X**: the head.
- **U**: upstream `d4f52faaa` plus D9.
- **U2**: a second copy of U, for the A/A run.

The tool is `SwiftTermProfile`, 22 cases, run in both orders with 2 rounds of 50 iterations. The
A/A floor (U against U2) is below 0.1% of instructions in most cases, and 0.72% at most.

**At `baa70de`, X was slower than the floor in 11 of 22 cases:**

- every scrolling case: +9.6% to +10.1% of instructions, and cycles agree
- unicode +1.6%, medium_cells +0.9% to +1.5%, sync_medium_cells +1.0%, ghostty_osc +0.5%,
  hardening_osc_short_chunked +0.4%

A bisect found the cause in one word. The fork had declared `public var userScrolling`, and upstream
declares `var userScrolling`. Upstream reads it five times on the scroll path. A public stored
property of an open class keeps a dynamic exclusivity check on every read.

The bisect ruled out the other suspects:

- The cost was already present in the merge commit `e768bfa77`.
- It was not CellArena: X with upstream's CellStorage.swift still measured +10%.
- It was not the replication code: with that code removed, X still measured +9.8%.

**Fix (`4ce3952`, lead 14's ruling (a)).** The declaration is upstream's again, and Scape reads
`public var isUserScrolling`, a forwarder. Afterwards, all six scrolling cases, unicode and
medium_cells are within the floor:

- scrolling +0.02/+0.00
- scrolling_fullscreen −0.20/−0.16
- unicode +0.07/+0.14

**The shipped pin, `7ec59163a`, pays the same kind of cost today.** As shipped, against the same
tree with only `public` removed, by instructions in the two orders:

| case | instructions |
|---|---|
| scrolling | +5.43% / +5.46% |
| scrolling_bottom_region | +6.33% / +6.33% |
| scrolling_bottom_small_region | +5.90% / +5.90% |
| scrolling_fullscreen | +4.63% / +4.23% |
| scrolling_top_region | +6.40% / +5.84% |
| scrolling_top_small_region | +5.92% / +5.88% |
| unicode | +1.29% / +1.32% |

**Allocations.** X against U, 3 runs each: the counts differ by 1 to 11 calls in about 1.08 M. These
differences are at setup level, not per iteration.

**CellArena (per cell).** No headless case reads attributes cell by cell, so a scratch driver did
it. The driver is not in the repo. It fills a 200x60 grid with 1024 distinct attributes, then reads
every cell's attribute through `getLine` and the subscript, 300 times. With setup subtracted:

- **Read cost:** X costs +1.44% of instructions per cell read against U (1075.7 M against
  1060.4 M for 3.59 M cells).
- **Memory, measured:** `phys_footprint` of 50 terminals at 200x60 with 1000 lines of scrollback,
  each fed 1200 coloured lines. X uses 2.240 MB per terminal and U 2.269 MB, a saving of about
  29 KB per terminal.
- **Memory, computed:** the 896 KB of upstream's table (from `9500a26`) is virtual allocation. Pages
  that are never touched do not count toward the footprint.

The trade-off between this read cost and this memory goes to Nash.

## Inventory: every file under Sources/SwiftTerm that differs from d4f52faaa (at 01c422a)

This answers the lead's question. Each file gets one line with the most frequent path its fork code
sits on: **per byte**, **per cell**, **per frame**, **per event** (per reply, per post, per user
action, per resize), or **cold** (export or import, setup, API surface, compiled-out code).
`EscapeSequenceParser.swift` is not on the list: it is upstream's, byte for byte.

| File (+/-) | Path | What the fork does there |
|---|---|---|
| CellStorage.swift (+60/-8) | **per cell** | `9500a26` (IT-1016) grows the attribute table lazily. It starts at 256 slots and doubles. `attribute(for:)` gains a bounds guard (`index < attributeSlots`, returning the default attribute) and reads through a `var` pointer that was a `let`. Interning checks for growth. Retired tables are kept until the arena deinits. This is on render reads and on attribute reads during writes |
| ByteRunScanner.swift (+12/-3) | per print or OSC run (not per byte) | D9 `5e72f28`: `guard let baseAddress` in the three Swift < 6.4 vector scans. This fixes upstream's crash on an empty span (Linux L0). On a Swift 6.4 toolchain the other branch is compiled |
| Terminal.swift (+354/-33) | per event; per feed (O(1)) | `sendQueryResponse` gates replies on `respondsToQueries` (a `cold` read), per reply. `sendUserInputBytes` sends user input. The D7 watchdog: a pure decision function in `reconcileSynchronizedOutputWatchdog` (per outermost feed, as upstream) and the `synchronizedOutputTimeout` setter. `hasPendingSequence`. `public userScrolling`. `cold.respondsToQueries` and `cold.synchronizedOutputTimeoutDisabled`. The rest is `replication*` accessors (cold) |
| Apple/TerminalEventQueue.swift (+12/-2) | per event post | `post(_:caller:)` takes a `StaticString` and, under the existing lock, counts `scheduledHops` and checks `ProfilingStats.enabled` (D2 diagnostics) |
| Apple/AppleTerminalView.swift (+27/-4) | per frame (one optional) | D2: `pendingTitle` is read and cleared in `applyPendingViewUpdates` under the existing lock. This replaced a main-thread hop per title. Also `public` grants, a `resizeSuspended` check per resize, and `coalescedMainHops` diagnostics |
| Mac/MacTerminalView.swift (+50/-19) | per event | `resizeSuspended` per resize. The selection autoscroll does its hit test and extension inside one terminal lock, per autoscroll tick, only while dragging. `scrollWheel` is `open`, and on the alternate screen the wheel always sends cursor keys (a behaviour choice, not a cost). Titles go through `crossThreadState` (D2). Also `public` grants and the view-level `userScrolling` |
| iOS/iOSTerminalView.swift (+5/-5) | per event | the title goes through `crossThreadState` (D2) |
| Mac/MacLocalTerminalView.swift (+18/-2) | per resize | D6: `windowSizeShouldBeSent` (0x0 and 1x1 send nothing) |
| Apple/FrameDriver.swift (+7) | cold | `takePendingDirtyForTesting` (tests) |
| Apple/SynchronizedOutputWatchdog.swift (+7) | cold | `armedGeneration` read for the D7 pins |
| HeadlessTerminal.swift (+11) | per feed (one optional call) | `onOutput?(slice)` under the lock after each fed batch (the daemon's observer) |
| KittyClipboardProtocol.swift (+2/-2) | per event | paste uses `sendUserInputBytes`; replies use `sendQueryResponse` (D8) |
| Pty.swift (+50/-1) | per process launch | the child closes fds 3 up to max(getdtablesize(), 10240) before exec, so leaked descriptors are not inherited |
| SearchEngine.swift, SearchService.swift (+13/-12) | cold | `public` grants; `findAll`'s default limit is spelled 1000 |
| CharData.swift (+37) | per call (host) | `getText(maxUTF8Bytes:)`: a bounded text read for the host. SwiftTerm itself does not call it |
| Buffer.swift (+64), BufferLine.swift (+49) | cold | `replication*` accessors and constructors, used at export and import |
| TerminalStateSnapshot.swift (+605), TerminalStateSnapshotCoding.swift (+720), TerminalHistoryStreaming.swift (+202), TerminalReplicationDigest.swift (+232) | cold | export, import, the codec, history chunks, and the test digest. Nothing runs during a feed |

**What needed the lazy attribute table (CellArena).** Commit `9500a26` (IT-1016, 2026-09-23),
"perf(CellArena): IT-1016 grow the attribute table lazily". Its stated case is memory. Every
CellArena allocated its full 65,536-slot attribute table (896 KB) up front: one per terminal, plus
one per render snapshot. Scape's production heap held 176 of them (about 160 MB), and almost none
were touched. Live arenas now start at 256 slots and double. Snapshot arenas copy the source's
slot count and never grow. An outgrown table is retired, not freed, because a `PackedCellView`
holds the arena `unowned(unsafe)`.

No feature depends on it. It is a memory optimisation for Scape's many terminals and render
snapshots. If it measures above the floor on the per-cell path, the alternative is upstream's
fixed table, which brings back about 896 KB per arena. The case to make for keeping it is that
memory figure, and the decision belongs to Nash.

## Assertion audit (plan section 8, last row)

The check: every assertion line in a test file at the base (`7ec59163a`) that is missing at the
head is named by a commit. The tool is `assert_audit.py`. It normalises each assertion line
(`#expect`, `#require`, `XCTAssert*`, `XCTUnwrap`) in every test file the branch changed, lists
the base lines that are absent at the head, and runs `git log -S` on each one to find the commit
that removed it.

Result for `7ec59163a..5450d92`: 147 test files changed, and 62 base assertion lines are absent.
Each of them is accounted for.

| Removed by | Lines | Where | Why |
|---|---|---|---|
| upstream `2dad6a1` Osc 7501 (#746) | 4 | EscapeSequenceParserHardeningTests:184, TerminfoCompatibilityTests:46, XtgettcapTests:353, :360 | upstream rewrote the test (state count, terminfo fixture, capability counts) |
| upstream `c3caadf` (#712) | 1 | GlyphFallbackTests:186 | upstream changed how shaped glyphs map to cells |
| upstream `73b27f5` (#714) | 3 + 1 | MouseTrackingTests:47, :240, :247; TerminalTapPolicyTests:22 | upstream changed how semantic clicks are deferred (see the note below) |
| upstream `91f6bda` | 1 | OscTests:1408 | the pending wrap is now an explicit flag, so `x == width` no longer marks it |
| upstream `8a03f55` (#774) | 18 | PowerlineRendererTests:8-24, :30 | upstream moved extended Powerline separators to another path |
| upstream `9a12573` (#783) | 4 | SwiftTermTests:325, :330, :351, :352 | esctest2 now runs from an anchored allow-list |
| upstream `28c6d1d` | 3 | UnicodeTests:1127, :1337, :1354 | upstream updated the Unicode table |
| `0f6fe1d` IT-2001 D2 (red) | 13 | MainHopCoalescingTests | the queue-based asserts were replaced by frame-tick ones; the commit message names this |
| `c52fb8f` IT-2001 D1 | 13 | SelectionTests (testRectangular*) | the fork's rectangular mode is gone; see "Block selection" below |
| `f69bc6a` IT-2001 D7 (follow-up) | 1 | ReplicationPrimitivesTests.settingNilCancelsAnArmedValve | `cancelled == 0` became `== 1` after the setter and after 2026l, because setting `nil` now cancels the armed valve (decision 3); the commit message names this |

That makes 35 lines removed by upstream-only commits (ancestors of `d4f52faaa` that are not
ancestors of `7ec59163a`; the merge took upstream's file) and 27 removed by IT-2001 commits, each
named in its commit message.

**TerminalTapPolicyTests:22.** `git log -S` finds no commit for this line, because the line moved
into a new test with a different expectation. Upstream `73b27f5` changed the behaviour: a single
tap with a selection active and no mouse reporting now returns `.localSingleTap`, where the fork
returned `.dismissSelection`. The head's test file is identical to `d4f52faaa`'s. This is a visible
change on iOS (the tap path), it comes from upstream, and it goes on the Scape pin-bump list.

The tool is under `~/Library/Caches/scape-build/it2001-b/ab2-tools/assert_audit.py`, and its full
output is in `it2001-b/assert-audit.txt`. It is re-run at the head before the gate.

## Block selection (lead condition C6, ruling F)

D1 (`c52fb8f`) deleted the fork's nine `testRectangular*` tests. Its message has the C6 table,
which names the upstream test (in `BlockSelectionTests` unless stated) beside each one:

| Fork test | Upstream test |
|---|---|
| testRectangularBasic | covered by blockCopiesTheSameColumnsFromEveryRow |
| testRectangularReverseDrag | covered by blockDraggedUpAndLeftCoversTheSameColumns |
| testRectangularDiagonalDrag | not covered: no upstream test reverses only one axis. The case is gone because the fork's own min/max code is gone. Upstream's `selectedColumns` takes the min and max per axis, and blockDraggedUpAndLeftCoversTheSameColumns exercises it with both axes reversed |
| testRectangularZeroWidthIsEmpty | covered by zeroWidthBlockSelectsNothing |
| testRectangularPreservesBlankLine | covered by blockTrimsTrailingSpacesAndKeepsEmptyRows |
| testRectangularRstripsPerRow | covered by blockTrimsTrailingSpacesAndKeepsEmptyRows |
| testRectangularDragExtendNoWordExpansion | covered by blockCopiesTheSameColumnsFromEveryRow |
| testRectangularShiftExtendNoWordExpansion | covered, with a deliberate change, by shiftExtendMovesTheBlockEdgesNearestTheClick (upstream moves the edges nearest the click; the fork moved only `end`) |
| testRectangularWideGlyph | covered by blockCopiesWideCharactersCutByAnEdgeWhole |

Four of these tests (Basic, ReverseDrag, DiagonalDrag, ZeroWidthIsEmpty) also ran on Linux at L2a.
Their upstream replacements ran and passed on Linux at L3 (run 43508512845, `393ba79` plus the
probe). The run's `xunit-swift-testing.xml` lists 10 `BlockSelectionTests` cases, and each is a
self-closing `<testcase>` with no `<failure>`:
blockCopiesTheSameColumnsFromEveryRow, blockDraggedUpAndLeftCoversTheSameColumns,
zeroWidthBlockSelectsNothing, blockTrimsTrailingSpacesAndKeepsEmptyRows,
shiftExtendMovesTheBlockEdgesNearestTheClick, blockCopiesWideCharactersCutByAnEdgeWhole,
blockReachingTheLastColumnIncludesIt, otherSelectionsEndTheBlock,
blockCapturedContentFollowsItsColumns, streamDragStillReadsInOrder.
For example: `<testcase classname="SwiftTermTests.BlockSelectionTests"
name="zeroWidthBlockSelectsNothing()" time="12.572213504" />`.

The three mode-reset tests stay, and they passed on Linux at L3: testStartSelectionResetsRectangularMode,
testSetSelectionResetsRectangularMode and testWordSelectionAfterRectangularResetsMode. Under ruling F,
each one first puts the selection in block mode, then makes the other selection, then asserts
`isBlock == false`.

## TerminalDelegate: every method classified (ruling C, invariant 3)

The merged tree's `TerminalDelegate` (Terminal.swift) has 39 requirements; six of them, the Kitty
clipboard methods, exist only under `!SWIFTTERM_EMBEDDED`. Each one is in exactly one class:

- **reply**: bytes answering parsed input.
- **user input**: bytes from the host's user.
- **notification**: tells the host something and carries no bytes toward the child.
- **read**: the terminal asks the host for a value.

Bytes reach the child through two sinks:

```swift
// Terminal.swift:957-961: replies, gated on a replica
func sendQueryResponse(_ data: ArraySlice<UInt8>) {
    guard respondsToQueries else { return }        // :959, the module's only check of respondsToQueries
    tdel?.send(source: self, data: data)           // :960
}
// Terminal.swift:968-971: user input, never gated
func sendUserInputBytes(_ data: ArraySlice<UInt8>) {
    tdel?.send(source: self, data: data)           // :970
}
```

Every `sendResponse` overload (Terminal.swift:8082-8115) and the Kitty clipboard's `send(_:to:)`
(KittyClipboardProtocol.swift:1598) go through `sendQueryResponse`. `sendUserInputBytes` is called
from `setTerminalFocus` (:1181), `sendUserInput` (:3253), the semantic-prompt click (:3684, :3705),
mouse reports (:9574, :9592), and the Kitty text paste (KittyClipboardProtocol.swift:988). The
focus report sent when DECSET 1004 is enabled is a reply (:7477). A later focus change through
`setTerminalFocus` is user input.

| Method | Class | Reached from parsed input | On a replica |
|---|---|---|---|
| showCursor | notification | DECSTR, CSI ?25h | called |
| hideCursor | notification | CSI ?25l | called |
| setTerminalTitle | notification | OSC 0/2, CSI 23t | called |
| setTerminalIconTitle | notification | OSC 1, CSI 23t | called |
| windowCommand | read (a notification for the action commands) | CSI t, DECSNLS | called; the actions run on the host, and report replies are dropped at :959 |
| sizeChanged | notification | DECCOLM | called |
| send | the transport under both sinks | (only :960 and :970 call it) | :960 is gated, :970 is not |
| bufferActivated | notification | CSI ?47/1047/1049, RIS; also replicationNotifyBufferActivated after an import | called |
| synchronizedOutputChanged | notification | CSI ?2026 h/l | called |
| scheduleSynchronizedOutputTimeout | notification (Embedded builds only) | mode 2026 | called (through the D7 gate) |
| bell | notification | BEL | called |
| selectionChanged | notification | an in-place scroll caused by output (SelectionService.swift:147); otherwise the user's selection | called |
| isProcessTrusted | read | OSC 6/7, DECRQCRA | called; the DECRQCRA reply is dropped at :959 |
| cellSizeInPixels | read | CSI 14/15/16 t, mode 2048, resize, Kitty APC placement | called; replies are dropped at :959. It also fills the `pixelGeometry` cache (:9188) |
| mouseModeChanged | notification | CSI ?9/1000/1002/1003 | called |
| cursorStyleChanged | notification | DECSCUSR | called |
| hostCurrentDirectoryUpdated | notification | OSC 7 | called |
| hostCurrentDocumentUpdated | notification | OSC 6 | called |
| colorChanged | notification | OSC 4/104, DECSCNM, DECSTR | called |
| setForegroundColor | notification | OSC 10 set | called |
| setBackgroundColor | notification | OSC 11 set | called |
| setCursorColor | notification | OSC 12 | called |
| getColors | read | OSC 10/11/12, including sets (:4517 runs before the query check) | called; the reply is dropped at :959 |
| iTermContent | notification | OSC 1337 (unhandled keys) | called |
| clipboardCopy | notification | OSC 52 write | called: **a replica also writes the host clipboard** |
| clipboardRead | read | OSC 52 `?` | called; the reply is dropped at :959 |
| clipboardReadRequest | read | OSC 52 `?` | called; the host starts its asynchronous read, and the completion's bytes (TerminalWebInput.completeClipboardRead, through sendResponse) are dropped at :959 |
| terminalControlBytesForPaste | read | no: only the user paste APIs reach it | called; its result feeds user-input bytes |
| kittyClipboardCapabilities | read | OSC 5522, mode 5522 | called |
| kittyClipboardSendPasteEvent | **user input** | no (callers below) | called, not gated |
| kittyClipboardAvailableMimeTypes | read | OSC 5522 read | called; the final packet is dropped at :959 |
| kittyClipboardRead | read | OSC 5522 read | called; the reply is dropped at :959 |
| kittyClipboardWrite | read (it returns a status), with a host clipboard write as a side effect | OSC 5522 write | called: **a replica writes the host clipboard**; the status reply is dropped at :959 |
| kittyClipboardRequestPermission | read | OSC 5522 read and write | called: **a replica can show a permission prompt**; the reply is dropped at :959 |
| notify | notification | OSC 777 | called |
| progressReport | notification | OSC 9;4 | called |
| programStatusChanged | notification | OSC 7501 | called |
| createImageFromBitmap | notification | DCS sixel | called |
| createImage | notification | OSC 1337 File= | called |

**kittyClipboardSendPasteEvent: every caller (ruling C(2)).** It is called from one site,
KittyClipboardProtocol.swift:1005, inside `private func sendPasteEvent` (:993). The only caller of
`sendPasteEvent` is `KittyClipboardProtocol.paste(_:allowUnsafe:)` (:967, call at :972), and the
only caller of that is `public func Terminal.paste(_:allowUnsafe:)` (Terminal.swift:4215/4219).
`Terminal.paste` is called from these host paste APIs:

- Apple/AppleKittyClipboard.swift:123, :139 and :141
- TerminalWebInput.swift:38 (`sendHostTextPaste`: a text request with no snapshot, so it cannot
  reach the event path)
- SwiftTermWebWasm/InputExports.swift:104 (the WebAssembly host's paste export)

Parsed input enters the protocol through `oscKittyClipboard` → `handle` (:1085), and that path goes
only to read, write, wdata and walias. It never reaches `paste`. So only a user paste reaches this
method. It is user input and is not gated. `ReplicaSinkTests` pins its call-site count (one site,
quoted). The method writes to the child without going through `send`, so the two sinks are not the
only writers: it is a third path, and it carries user input only.

**What this costs on a replica (not changed in PR B; for the host).** Every delegate call except
`send` is still made on a replica. Only the reply bytes are dropped, at :959. So a replica that has
a delegate also does these things:

- Host reads: OSC 52 `?`, OSC 5522 read, CSI t reports, and OSC 10/11/12.
- Host writes: OSC 52 write, OSC 5522 write, and the CSI t actions.
- Permission prompts: OSC 5522.

A host that gives its replica a live delegate must make these no-ops itself, or each one happens
twice. This goes on the Scape pin-bump list.

**Dead code noted while reading.** `oscSetTextBackground` (Terminal.swift:4558) has no caller in
`Sources/`.

How the table was checked: a read-only pass drafted it from the tree at `5450d92`. The claims it
rests on were then re-checked by hand with `git grep`: `respondsToQueries` is read only at :959;
`kittyClipboardSendPasteEvent` has one call site; every `paste(` caller is the list above (the
WebAssembly export was missing from the draft); and the protocol has 39 requirements (the draft
said 41).

## The fork only adds (lead 14, 00:46Z): sweep, pin, allow-list (commits `12a9e35`..., 2026-11-13)

The rule: the fork never changes or removes a line of a file that exists upstream; what Scape needs
is added beside it. Before the sweep, 90 upstream lines in 12 files under `Sources/SwiftTerm` were
changed or removed. After it, 23 are, and each is on a closed allow-list the lead ruled on.

**The pin.** `UpstreamOnlyAddsTests.everyUpstreamLineIsAtHead` reads
`Tests/UpstreamManifest/d4f52faaa.lines` (one FNV-1a 32 hash per line of every upstream file under
`Sources/SwiftTerm`: 153 files, 79,588 lines), written by `Tools/upstream-manifest.py` (`write`, or
`check` against git). Per file, upstream's hash sequence less the allow-list must be a
subsequence of HEAD's lines. A missing file fails; a stale entry (hash no longer upstream's) or an
unneeded one (HEAD keeps the line) fails; the manifest header's SHA-256 must be the generator's.
No git, no network, no Apple-only API. A failure prints `file:upstream_line hash`. Red at `12a9e35`
(90 lines, 12 files: the sweep's list line for line); green at the allow-list commit. The sweep
script (`sweep.py`, builder scratch) agrees independently: 23 lines.

Not covered by the pin: lines the fork ADDS inside upstream's hot functions. The inventory by path
heat and the whole-fork A/B stay the guard for those.

**Reverted to upstream's text, need met by an addition (54 lines + 12 whitespace/comment):**

| Lines | Now |
|---|---|
| CellStorage :317 :358 :380-382 :384 :431 :606 | upstream's fixed attribute table; 9500a26's lazy table and its tests deleted (+1.44% instructions per cell read for ~29 KB per terminal; nothing depends on it) |
| ByteRunScanner :208 :227 :249 (D9) | upstream's force unwrap; `guard buffer.baseAddress != nil else { return start }` added before it |
| MacLocalTerminalView :341-342 (D6) | upstream's guard; `guard windowSizeIsSendable(size) else { return }` added before it |
| TerminalEventQueue :48 :85 | upstream's `post(_:)`; the profiling hop is counted under the event's name |
| Terminal D8 :1038 :1042-1044 :3111 :3561 :7324-7325 :7932 :7940 :7945 :7951 :7974, Kitty :988 :1598 | upstream's `tdel?.send` sites; replies get an added `guard respondsToQueries else` line |
| Terminal D7 :9132 :9135 :9142 :9146-9151 :9154 :9192 | see "D7 after the sweep" |
| SearchEngine (5), SearchService (7), Apple :1567 :1756, Mac :289 :478 :502 :2786 :2792 | upstream's access levels; Scape's uses get forwarders in `Apple/TerminalViewScapeAccess.swift` |
| Mac :3628 :3634-3635 | upstream's alternate-screen route; the fork's always-cursor-keys route is an added line behind `alternateScreenWheelSendsCursorKeys` (default `true`: no change on screen) |
| Pty :136, Terminal :105, Mac :1877 :2914 | upstream's whitespace |

**THE ALLOW-LIST (23 lines; the lead read each).** None is per byte or per cell; the only per-frame
entries are D2's two Apple lines.

| File:upstream line | Reason |
|---|---|
| Terminal :3540 | D8: the semantic-prompt click is user input; it leaves the gated `sendResponse` family for `sendUserInputBytes` |
| Terminal :7936 | D8: `sendResponse(_ bytes:)` is one line, so no guard line fits; it calls the gated `sendQueryResponse` |
| Terminal :9370-9371 | D8: `sendEvent`'s mouse packet is user input (to `sendUserInputBytes`) |
| Terminal :9388-9390 | D8: `sendMousePacket`'s packet is user input (to `sendUserInputBytes`) |
| Apple :2602 :2604 | D2: `applyPendingViewUpdates`' one existing lock also takes the pending title (per frame) |
| Mac :3948-3952, iOS :3833-3837 | D2: `setTerminalTitle` records the latest title for the next frame instead of a main-queue hop per title |
| Mac :3606 | `scrollWheel` is `open`: Scape overrides it; no addition can make a member overridable |
| Mac :2908-2910 | autoscroll: active check, hit test and `dragExtend` under one terminal lock; upstream's unlocked `dragExtend` races the IO thread |

Every reason ends "offered upstream: IT-2023" (D8, D2, wheel, autoscroll); nothing was posted to
the upstream project. D2's per-frame cost, quoted from `applyPendingViewUpdates`: the title is a
`String?` taken inside the same `crossThreadState.withLock` upstream already takes once per frame;
with no title pending it is `nil`: no lock and no allocation are added. Upstream's
`setTerminalTitle` does hop: `onMain { … }`, and upstream's `onMain` (AppleTerminalView:1951-1966)
ends `DispatchQueue.main.async`. IT-1075's measurement is re-done for D2 as the plan requires, and
RenderBench covers it.

**D7 after the sweep (reverses the plan's pin 7 and the 17:55Z condition b).** Upstream's
`reconcileSynchronizedOutputWatchdog` and `applySynchronizedOutputWatchdog` are back byte for byte.
The gate is ONE block added in reconcile, before upstream's call:
`if synchronizedOutputTimeoutDisabled { applySynchronizedOutputWatchdog(active: false, …); return }`.
Reconcile is apply's only caller, so the gate sits before every receiver, the Embedded branch's
request included (upstream's `if active { tdel?.scheduleSynchronizedOutputTimeout(…) }`). The pure
decision function, the switch and `final` are deleted. Pin 7 (the decision table) is gone; pin 6 is
a behaviour test plus the source pin on the gate's position; pins 1 and 3 now read "active before
the call, not after; a second call changes nothing".

`expireSynchronizedOutput()` is upstream's (`Void`) again; the fork adds nothing. The host reads
`synchronizedOutputActive` just before calling it, both under the terminal lock. #1289 changes one
guard: HostSession.swift:333 `guard !ended, terminal.expireSynchronizedOutput() else { return }`.

- **Does upstream's expiry cancel the terminal's own timer?** Yes. `endSynchronizedOutput()` sets
  the watchdog dirty and, at `parseDepth == 0`, reconciles; that reaches upstream's
  `guard active else { synchronizedOutputTimeoutItem.cancel(); … }`. A callback already past the
  cancel is stopped by `synchronizedOutputWatchdogFired`'s active and generation checks. Pin:
  `SynchronizedOutputValveTests.aLateTimerAfterAHostExpiryChangesNothing`. It pins behaviour that
  was already correct, so its red (3 issues) was observed through a TEMPORARY EDIT IN THE WORKTREE:
  the generation check in `synchronizedOutputWatchdogFired` replaced by `generation == generation`.
  The edit was removed before the commit (`18c6526`; `git status` showed only the test changed).
  Lloyd's correction: such mutants belong only in a scratch copy under the cache dir, unless Nash
  says yes.
- **`fired == 1` became `fired == 0`** in `ReplicationPrimitivesTests.expiringTheValve…`: upstream's
  valve is not the timer. The test still asserts the outcome beside the counter (active before,
  not after, and still not after a second call). The test with a view (pin 3) asserts that the view
  is released and redraws. No code outside tests reads `fired`: in the fork it is only written
  (Terminal.swift:9361, SynchronizedOutputWatchdog.swift:118); `git grep` for
  `WatchdogCounters|watchdogCounters|\.fired\b` finds nothing in Scape `origin/main` or in #1289
  (`46faf0eff`).

**D8's source pin, reshaped.** `ReplicaSinkSourceTests` now checks that every `tdel?.send(` in the
shared sources is either preceded in its function by `guard [terminal.]respondsToQueries else`, or
in a closed list of user-input functions with reasons (`sendUserInputBytes`, `sendUserInput`,
`sendRepeatedSemanticSequence`, `sendFocusReport`, `paste`). It also checks that the DECSET 1004
`sendFocusReport()` call has the guard on the line before. So `respondsToQueries` is now read at
those guard lines and in `sendQueryResponse`, not at one place only: this supersedes "read only at
:959" in the delegate table above.
