# IT-2001 upstream merge (PR B): findings record

Branch `2001-upstream-merge-b`, fork PR #6. Merge of upstream `d4f52faaa` into the fork's
`scape-selection-api` at `7ec59163a`; merge commit `e768bfa77`. The plan (rev 3) asks for this
record in section 6, item 6. Line numbers are at the head unless a line says otherwise.

Sections are added as the work lands. Format v2, the census and the Pty close_range path are in
the last two sections ("Format v2 and the census", "Pty: close_range on Linux").

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

Decided once, on this measurement: the lazy table is deleted and upstream's fixed table is back
(+1.44% instructions per cell read, against a resident saving of about 29 KB per terminal; see "The
fork only adds"). A render snapshot's arena does not touch the fixed table's untouched pages either:
CellStorage.swift:375-387 allocates the capacity but initialises only `attributeCountValue` entries.

## Inventory at the head: every file under Sources/SwiftTerm that differs from d4f52faaa

Sources as of builder #7's diagnostics deletion (the D7 gate as at `25d06b6`). Every fork line is an
addition, except the 23 allow-listed lines ("The fork only adds"). The path is the most frequent
one the fork code sits on.

| File (+/-) | Path | What the fork adds |
|---|---|---|
| Terminal.swift (+315/-9) | per event; per feed: upstream's count | D8 reply gate (`sendQueryResponse`, added `guard respondsToQueries` lines) and `sendUserInputBytes`, per reply or user event. D7: one added block in `reconcileSynchronizedOutputWatchdog` after the dirty exit, calling the `@inline(never)` helper; the not-dirty feed path is upstream's 47 instructions. The `synchronizedOutputTimeout` setter. `hasPendingSequence`. The `isUserScrolling` forwarder (upstream's `userScrolling` untouched). `cold.respondsToQueries`, `cold.synchronizedOutputTimeoutDisabled`. `replication*` accessors (cold) |
| ByteRunScanner.swift (+12) | per long run, Linux only | D9: one added `guard buffer.baseAddress != nil else { return start }` per vector scan; upstream's lines kept. Compiled only under `#else` of `#if compiler(>=6.4)` (see D9 below) |
| Apple/AppleTerminalView.swift (+9/-7 changed-line form) | per frame (one optional) | D2: `pendingTitle` taken in `applyPendingViewUpdates` under the existing lock; `resizeSuspended` checks per resize |
| Apple/TerminalViewScapeAccess.swift (+38, new) | cold | Scape's view API as forwarders (`withLockedTerminal`, `selectionService`, `mouseHit(with:)`) |
| Apple/SynchronizedOutputWatchdog.swift (+7) | cold | `armedGeneration`, read by the D7 pins |
| Mac/MacTerminalView.swift (+40/-13 changed-line form) | per event | `resizeSuspended`; the autoscroll hit test and extension under one lock (allow-listed); `scrollWheel` `open` (allow-listed); `alternateScreenWheelSendsCursorKeys` (default true); D2 titles |
| iOS/iOSTerminalView.swift (+5/-5) | per event | D2 titles (allow-listed). Never built (see iOS below) |
| Mac/MacLocalTerminalView.swift (+17) | per resize | D6: `windowSizeIsSendable` (0x0 and 1x1 send nothing) |
| HeadlessTerminal.swift (+11) | per fed batch (headless only) | `onOutput?(slice)` under the lock |
| KittyClipboardProtocol.swift (+2) | per event | D8 gate lines |
| Pty.swift (+49) | per process launch (in the child) | close fds 3 ..< max(getdtablesize(), 10240) before exec (see Pty below) |
| CharData.swift (+37) | per call (host) | `getText(maxUTF8Bytes:)` (IT-824); SwiftTerm does not call it |
| Buffer.swift (+64), BufferLine.swift (+49) | cold | `replication*` accessors and constructors |
| TerminalStateSnapshot (+605), …Coding (+720), TerminalHistoryStreaming (+202), TerminalReplicationDigest (+232) | cold (and ~4 M instructions once at launch) | export, import, codec, history chunks, test digest |

TerminalEventQueue.swift, FrameDriver.swift, CellStorage.swift, SearchEngine.swift and
SearchService.swift are upstream's byte for byte.

## Inventory (SUPERSEDED, at 01c422a: CellStorage, Terminal, TerminalEventQueue and ByteRunScanner rows no longer hold)

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
one per render snapshot. Scape's production heap held 176 of them ("about 160 MB" is VIRTUAL
size, not measured resident memory), and almost none were touched. Live arenas now start at 256 slots and double. Snapshot arenas copy the source's
slot count and never grow. An outgrown table is retired, not freed, because a `PackedCellView`
holds the arena `unowned(unsafe)`.

No feature depends on it. It was deleted on measurement (see "CellArena (per cell)" above).

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

**D2: a title when the view is not drawing (lead 14's questions).** With no running tick source
(no window, hidden, occluded, minimised), `FrameDriverSignal.publish` (Apple/FrameDriver.swift:162-176)
schedules one main-actor task. `consumeSignalOnMain` (:396-398) then applies view updates whether
or not it draws. Tests: `MainHopCoalescingTests.aViewInNoWindowDeliversItsTitle` and
`.aViewInAHiddenWindowDeliversItsTitle`.

A title recorded while the link RUNS publishes nothing and waits for the next tick (:170). If the
view is hidden or detached before that tick, the suspension path delivers it:
`applyVisibilityPolicyOnMain` sets `running = false` (:550-552). `running`'s `didSet` calls
`signal.setLinkRunning(false)` (:323-331), and that schedules one delivery when anything is pending
(:129-140). Test: `FrameDriverTests.aViewUpdateRecordedWhileRunningIsDeliveredWhenTheLinkStopsBeforeItsTick`
(hidden and detached). It is green and has no hand-called tick. Its premises are asserted: the
link runs when the title is set, the update is deferred, the driver is suspended after.

The test drives the driver through its existing `ManualTickSource`. A real `CADisplayLink` was not
observed, but the path from suspension to `setLinkRunning` does not depend on the backend. The
shipped pin (`7ec59163a`) delivers titles through `TerminalEventQueue.postTitle`'s main drain,
independent of frames, so it has neither question.

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

## Whole-fork A/B after the sweep (X = `ad15bc0`, U = `d4f52faaa` + D9; builder #6, 2026-11-13)

**Headless, 22 cases, both orders, 2 rounds, load 10-17** (`ab3/xu6`). 15 cases are inside their A/A
floor by instructions, the six scrolling cases among them. Seven are above it in both orders, all
small: osc_short_chunked +0.42/+0.43%, osc_bounded_over_limit +0.32/+0.33, osc_bounded_normal
+0.26/+0.27, sync_medium_cells +0.19/+0.20, ascii_seam_noop +0.11/+0.10, wide_seam_overwrite
+0.09/+0.09, dense_cells +0.07/+0.08 (floors 0.04-0.14). Against `baa70de`, osc_bounded, ascii,
wide and dense are new. Back then X carried the lazy attribute table and U the fixed one, which
likely hid them. Allocations, block_color_cells: X − U = 0..+2 calls in ~1.077 M, the same at 20
and 60 iterations. That is setup-level, and settled.

**Variants (scratch copies under the cache dir; the worktree was not touched):**

| Variant | What | Result on the seven |
|---|---|---|
| Xb | X with U's ByteRunScanner.swift (D9's earlier `guard let` form) | worse: osc_bounded +0.5%; D9's form is not the cost |
| XR | X minus the four replication files, Buffer/BufferLine/CharData = upstream's | 6 of 7 back inside the floor; osc_short_chunked stays +0.42/+0.42 |
| UL | U plus one file of 250 public functions never called (__TEXT +246 KB; X is +147 KB over U, XR = U) | all 7 inside the floor |

**What the variants show.** Adding inert code of the same size moves nothing, so the five-case cost
is NOT layout or code size. It comes from what the replication code adds to the hot types. The
fork's additions to Buffer, BufferLine and CharData are extensions and methods only, with no stored
field. The open hypothesis: a type-level or optimiser effect, e.g. new cold call sites changing the
optimiser's inlining or specialisation of hot functions they share. It is not yet bisected (the
lead asked to hear of it first).

osc_short_chunked's +0.42% is independent of the replication code. It is a per-feed residual in the
remaining fork code (#5 saw the same number at `baa70de`).

**RenderBench, one round (X U U X; load 32.8, 28.8, 22.7, 25.0: indicative only).** Every
non-scrolling case is inside run-to-run spread. Main-queue hops are about half in X where titles
occur (medium_cells 9258/9378 against 18468/18048; sync_medium_cells 8382/8208 against
16704/16548), which is D2 working.

The scroll family is 0.9-2.7% slower in MB/s in X: scrolling_fullscreen 590/587 against 605/605,
also in the low-load pair (587 against 605). Frame pacing does not differ: frames, ticks and renders
are 569-600 for both, coalesced 0-2, idle 0, main hops 0. So any cost is in feed throughput under a
view, not in drawing. Headless scrolling_fullscreen is inside its floor (+0.2/-0.2%), and it is
not settled by one round.

**RenderBench steals keyboard focus at every launch.** Tools/RenderBench main.swift:297-298 calls
`window.makeKeyAndOrderFront(nil)` and `NSApp.activate(ignoringOtherApps: true)`; that is 4 times
per round. Each further round needs Nash's yes.

## The five small cases are launch; osc_short_chunked was the D7 gate (builder #7, 2026-11-13)

**The five-case cost (osc_bounded ×2, sync_medium, ascii_seam, wide_seam, dense) is a fixed
per-process launch cost, not a hot-path cost.** X − U is +2.4 to +7.2 M instructions in 20 of the
22 cases of `ab3/xu6`, whatever the case's size (1.2 G to 118 G instructions). The five cases above
the floor are just the smallest, so the same ~5 M shows as a larger percentage. Two facts prove it
(`ab3/fixed2-results.tsv`, X/XR/U interleaved, 3 reps):

- **No arguments** (process launch plus usage(), which builds the workload list and never makes a
  Terminal): X − U = **+4.04 M** (U's spread 0.77 M); XR − U = −1.3 M.
- **The delta does not grow with work.** light_cells at 1, 50 and 200 iterations: +3.2, +4.5 and
  +3.2 M. osc_bounded_normal: +4.1, +4.7 and +3.2 M. dense_cells: +5.8, +4.6 and −4.3 M.

The code agrees. Function by function (otool -tV, addresses normalised), X and XR differ in 47 of
10,319 functions, all cold (view and renderer init, Kitty clipboard, sort helpers). Every parser,
Buffer and BufferLine function is the same, and swift_beginAccess call sites are 1790 in both. No
coroutine accessor, second caller or conformance changed any hot function's code. The ~4 M
instructions (~1 ms, once per process) are launch work for the replication types (their metadata
and conformance records), so they are accepted as launch (lead 14).

**THE METHOD, corrected for every A/B in this ticket:** judge by the slope between two iteration
counts, or subtract the no-argument launch delta. A difference that does not grow with work is
launch, reported once as launch. Script: `ab2-tools/run-slope.sh` + `sum_slope.py`. The old outputs
are kept.

**osc_short_chunked's +0.42% was the D7 gate: 7.0 instructions per feed call.** One iteration is
1,048,580 one-byte feeds; 52 iterations (with warmup) is 54.5 M feeds; (389 − 5 M launch) / 54.5 M
= 7.0. In release, the gate's inline second apply call made `reconcileSynchronizedOutputWatchdog()`
too big to inline into parse's `defer`. It became a tail-called function that built a stack frame
before testing the dirty flag, and `feed(byteArray:)` stopped being merged with `parse`.

Fix (`25d06b6`, red `f9dfcfb`): the gate stays after upstream's dirty exit and before upstream's
apply call, in the one caller of apply. Its body is one call to the `@inline(never)` helper
`reconcileDisabledSynchronizedOutputWatchdog()`.

The not-dirty path of a one-byte feed, counted from `Tools/feed-path-disasm.py`'s listing of a
release SwiftTermProfile (it needs a release binary, so it is a script plus these numbers, not a
test):

| build | instructions | calls out of parse on the path |
|---|---|---|
| U (`d4f52faaa` + D9) | 47 | swift_retain, EscapeSequenceParser.parseBorrowed, swift_release, merged `$defer` (reconcile inlined) |
| `ad15bc0` | 54 | the same, then a tail call to reconcileSynchronizedOutputWatchdog (own frame); feed(byteArray:) → parse(buffer:) unmerged |
| `25d06b6` | 47 | the same as U; feed(byteArray:) merged with parse again |

No call out of parse on the not-dirty path that upstream's does not have. Instructions vs U, both
orders, 2 rounds (`ab3/v1bu7-summary.txt`):

| case | `25d06b6` | gate deleted (reference only) |
|---|---|---|
| osc_short_chunked | −0.014 / −0.003% | +0.010 / +0.006% |
| osc_bounded_chunked | −0.125 / +0.015% | |
| osc_short_normal | +0.011 / +0.011% | |
| scrolling | +0.017 / +0.031% | |

All are inside the A/A floor.

**Per feed under a view (reading, `25d06b6`).** TerminalRenderOwner.swift has no fork lines; its
feed transaction is upstream's. The fork code reached per feed call is the D7 gate (above, now
upstream's instruction count) and nothing else. ViewTerminal's only fork line is a blank. There is
no added lock per feed and no title work per feed (the title is recorded only on OSC 0/2).

Per frame: `applyPendingViewUpdates` carries one more `String?` in the tuple, under the lock
upstream already takes, and one `if let`. Per event only: TerminalEventQueue's `scheduledHops`
counter, `resizeSuspended`, the gated reply guards, and the autoscroll lock. Headless only (the
daemon): `onOutput?(slice)` per batch.

The round-1 RenderBench binaries compared function by function: `preparePlainRow` differs only in
scheduling and one merged thunk (X is 4 instructions smaller). `feedTransaction` differs only by the
parse call. No other per-feed or per-frame function differs.

**RenderBench, no focus (`--metal --no-activate --vtebench all --samples N`; 8 launches RX RU RU RX at
N = 60 and 240; load 15.7-21.3; the frontmost app was unchanged in all 8).** RX = `25d06b6` Sources,
RU = `d4f52faaa` + D9, each with the same tool edit. Instructions per sample are the slope
(I240 - I60) / 180 of the tool's per-case counter (proc_pid_rusage ri_instructions over the measured
feeds, the render thread included). RX - RU %, slot pair 1v2 / pair 4v3, then RU's own A/A (s2 v s3):

| case | 1v2 | 4v3 | RU A/A |
|---|---|---|---|
| scrolling | -0.029 | -0.085 | -0.068 |
| scrolling_bottom_region | -0.021 | -0.056 | -0.025 |
| scrolling_bottom_small_region | +0.010 | -0.021 | -0.018 |
| scrolling_fullscreen | -0.182 | -0.121 | -0.012 |
| scrolling_top_region | -0.043 | +0.037 | -0.016 |
| scrolling_top_small_region | -0.032 | +0.038 | +0.035 |
| medium_cells | -0.049 | -0.234 | +0.021 |
| unicode | +0.087 | -0.137 | +0.108 |
| cursor_motion | -0.048 | -0.098 | -0.003 |
| light_cells | -0.067 | -0.539 | -0.427 |
| sync_medium_cells | +0.063 | -0.150 | -0.237 |
| dense_cells | +0.117 | +0.101 | -0.016 |

The scroll family is equal, or X is cheaper, so round 1's -0.9 to -2.7% MB/s (wall clock, load 23-33,
focus taken) is closed as noise. dense_cells is above in both orders (+0.12/+0.10%), but X drew more
frames per sample in both pairs (0.300 against 0.294), and frames follow wall time at 60 Hz. Its
render instructions are inside the number. Headless dense_cells is launch only.

**The rule that closes it, and round 2.** Lloyd's rule: one extra round. If the feed side is equal
X against U within the A/A spread, it is closed as frame coupling. If the feed side is above in both
orders, it goes to the lead with its count.

Round 2 (the same 8 launches, load 16-29, frontmost app unchanged in all 8): dense_cells is
**+0.176 / -0.100%** (A/A -0.163). It is not above in both orders, so it is closed. Across the two
rounds, no case is above in both orders twice.

The frame-coupling fit (instructions = a·samples + b·frames + c, `ab2-tools/fit_rb3.py`) is
ill-conditioned: frames per sample vary by under 4% between runs (its A/A spread is ±5-24%), so it
is not used. A per-thread split (feed thread against render thread) was not built, under the one-round
time box.

## Open facts at the head (builder #7, lead 15's read)

**D9 is not measured against pure upstream.** Both A/B baselines are "U = `d4f52faaa` + D9", so D9
sits on both sides. The facts:

- Its three `guard buffer.baseAddress != nil` lines are compiled only under the `#else` of
  `#if compiler(>=6.4)` in ByteRunScanner.swift ("Swift 6.3 has no checked RawSpan.load").
- This Mac's toolchain is Apple Swift 6.4 (swiftlang-6.4.0.34.1), so on macOS the D9 lines are not
  compiled: 0 instructions.
- On Linux's Swift 6.2 container they are compiled: one nil compare and a branch per vector-scan
  call, which is per long run (16 or more bytes past the scalar prefix), not per byte.
- No production caller passes an empty span. firstC0Byte (:52), firstNonASCIIByte (:99) and
  firstC0OrByte (:137) each `guard start < bytes.count` first, and call the vector scan only
  `if bytes.count - index >= vectorWidth`.
- What reached upstream's :208 trap in Linux L0 was upstream's own test:
  ByteRunScannerTests.wordAndVectorScansAgreeWithScalarSearches :147 calls `vectorScanC0` directly,
  and its iteration 0 has length 0.
- Lead 15 ruled KEEP. The guard is reached only by upstream's direct test with length 0, and
  production callers never pass fewer than 16 bytes. It goes away when the Linux toolchain
  reaches 6.4. It is offered upstream on IT-2023 (upstream's force unwrap on an empty span is
  their bug). No new pin.

**Pty's close loop (D5).** The comment's own figure is "~32 ms at a 245k bound". On this Mac:

- A shell-launched process sees getdtablesize = min(soft limit 1048576, kern.maxfilesperproc 245760)
  = 245760. That is the ~32 ms case: a dev build launched from a terminal pays it in the child, per
  session spawn.
- A launchd-launched app with default limits (maxfiles 256) gets the 10240 floor.
- Linux: measured at ~20.0 ms per session start; fixed with close_range (last section).

**iOS is never built.** AppleTerminalView.swift's `queueSizeChange` / `processSizeChange` read
`resizeSuspended` inside `#if os(macOS) || os(iOS) || os(visionOS)`, but only MacTerminalView.swift
declares it. So by reading, the file does not compile for iOS. This is pre-existing, at least since
`7ec59163a` (its :1746/:1765).

The only workflow with an iOS step (.github/workflows/xcode.yml) runs on pushes and PRs to `main`,
and the fork's line targets `scape-selection-api`. The 5 iOS allow-list lines are therefore unproven
by any build.

**The only-adds pin's known limit.** It compares per-line 32-bit hashes as a subsequence. A deleted
common line ("}" or a blank) is caught, unless the fork adds the same text later in the file. The
pin proves that the upstream lines' ORDER survives, not where they are.

**The D7 count's toolchain.** The count is 47 (U) / 54 (`ad15bc0`) / 47 (`25d06b6`) for the
not-dirty path of a one-byte feed. It was taken with Apple Swift 6.4 (swiftlang-6.4.0.34.1),
arm64-apple-macosx27.0, `swift build -c release --product SwiftTermProfile -Xswiftc -Xllvm -Xswiftc
-align-all-functions=6`, counted from `Tools/feed-path-disasm.py`. A script guards it, not a test.
The pin-bump PR and every later upstream merge re-run it and quote U against X.

**Diagnostics nothing read: deleted (lead 15's rule: keep only what RenderBench or a test reads).**

- Deleted: TerminalEventQueue's `scheduledHops` (field, getter, increment, reset), its `hopName`
  extension and the `ProfilingHopCounter.record(event.hopName)` call; AppleTerminalView's
  `Diagnostics.coalescedMainHops`, its assignment and the added `eventQueue.resetCounters()` in
  `resetDiagnostics`; FrameDriver's `takePendingDirtyForTesting`.
- RenderBench's `main_hops` column is upstream's `Diagnostics.mainHops` (counted in upstream's
  `onMain`, AppleTerminalView.swift:1974), and its `coalesced=` column is upstream's
  `renderLoopCoalesced`. Neither reads what was deleted.
- Kept: `SynchronizedOutputWatchdog.armedGeneration` (read by SynchronizedOutputValveTests).
- TerminalEventQueue.swift and FrameDriver.swift are upstream's again, byte for byte.

## Format v2 and the census (builders #8 and #9; red `8c3e1e7`, `b373aa1`; leftovers red `bee4f64`, `bfdcfc2`)

**One version, 2**, for both magics (STSS, STSH); version 1 is refused. The pending-parser-bytes
field, its import-side feed, its coding and its doc line are gone (export happens only at ground).

**The criterion.** A field is in the format if a reader of the replica can observe it: what is
drawn, what the next byte does, what a query answers, or what a key at the viewer sends. A field
that no parsed byte can change carries nothing between owner and replica, so it is not in the
format. A field that import BUILDS the replica from is a construction parameter: it is carried
and named as one. The census enforces this by reflection, in both directions
(`ReplicationCensusTests.theCensusClassifiesEveryStoredPropertyBothWays`). Every stored property
of `Terminal`, of the named holders `cold` and `reportedOnly`, of `Buffer` and of `BufferLine` is in
exactly one of three classes: carried, construction parameter, or excluded with a sentence. A
name in any class must also be a real stored property.

**Carried (105 census paths), grouped by what a reader observes:**

- **Drawn:**
  - Buffers: cursor x/y, yBase/yDisp, linesTop.
  - Lines: isWrapped, bidiState, renderMode, semantic marks, hard-continuation group.
  - Cells: compared one by one, to full width.
  - Terminal: curAttr, currentEraseAttribute, reverseColors, cursorHidden, cursorBlink,
    ansiColors, foreground/background/cursor colours and the cold OSC 10/11 overrides,
    terminalTitle/iconTitle and both title stacks, programStatusStore, _currentBidiState,
    defaultBidiState.
- **What the next byte does:**
  - Charsets: charset, gCharsets, gLevel.
  - Margins and wrap: margins and scroll region; origin, margin, insert, wraparound and
    reverseWraparound(+Extended) modes; pendingWrap (restored last); cursorStartsNewGrapheme.
  - Saved cursor: saved cursor, attr, charset, origin/margin/protection, pendingWrap.
  - Other modes: tabStops; savedPrivateModes; lineFeedMode (LNM); characterProtection(Mode);
    bulkInsertBlocked; noClearOnColumnChange; allow80To132; conformance; cc (S7C1T/S8C1T);
    synchronizedOutputActive; the semantic prompt state.
- **What a query answers:**
  - Reported modes: reportedOnly.decModes, attributeChangeExtent, smoothScroll (DECSCLM is
    reported by DECRQM), colorScheme and its updates flag.
  - Title modes: the xterm title set/query modes.
  - Host state: hostCurrentDirectory, hostCurrentDocument.
  - Report flags: visibility, in-band size and kitty paste-event reports.
- **What a key at the viewer sends:**
  - Key modes: applicationCursor, applicationKeypad, both kitty keyboard modes,
    backarrowKeyMode, keyboardActionMode, sendReceiveMode.
  - Mouse and focus: mouseMode, mouseProtocol, mouseShiftCapture, sendFocus.
  - Paste and scroll: bracketedPasteMode, alternateScrollMode, bidiArrowKeySwap, cold.moreFix.

The authoritative sets are in `Tests/SwiftTermTests/ReplicationCensusTests.swift`
(`carriedTerminal`, `carriedHolder`, `carriedBuffer`, `carriedLine`).

**Construction parameter (1):** `Buffer.scrollback`. Import builds each buffer with the
exporter's scrollback. The app's viewer replica is built with app options, and a smaller
scrollback would silently drop history. Pinned by `aConstructionParameterIsTheOwnersAfterImport`:
a replica made with scrollback 10 gets the owner's 50.

**Excluded, with their sentences:** the three `digestExcluded*` tables in
TerminalReplicationDigest.swift. Every entry has one sentence. These are the exclusions decided
for v2 (builder #9 corrected the ones marked *):

| Field | Why it is excluded |
|---|---|
| `_options` | The host's configuration. The cursor style an application changes is carried. |
| `defaultCursorStyle` | The host's configuration. |
| `installedColors`, `defaultAnsiColors` | The host's palette. |
| `semanticPromptClickBehavior` | The host's choice of click routing. |
| `settingFg/Bg/CursorColor` | Re-entrancy guards. They are false between feeds. |
| `portableRender*`, `lineChanges` | Render caches. |
| `payloads` | Atom identity. Payloads are compared by target. |
| `cold.respondsToQueries` | The replica's role, not emulator state. |
| `cold.synchronizedOutputTimeoutDisabled` | The host's choice of valve. |
| `userScrolling` | View scroll state (lead ruling 20:01Z). |
| `gcharset`* | No parsed byte writes it: it is 0 at init and at reset, and nothing reads it. |
| `tabStopWidth`* | Always 8. Upstream never reads `TerminalOptions.tabStopWidth` (IT-2023). Reset and resize rebuild tab stops from it, so the day upstream honours the option it becomes a construction parameter. Pin `tabStopWidthIgnoresTheOptionSoItCarriesNothing` fails that day. |
| `Buffer.xDisp`*, `Buffer.xBase`* | No parsed byte writes them (0 at init, and `xBase` 0 in `clear()`). SwiftTerm has no horizontal scroll. |
| `Buffer.hasScrollback` | Derived from scrollback, which is carried. It was never encoded. |

Builder #8's sentences for two fields were wrong. "smoothScroll: never set" and "lineFeedMode:
only from convertEol" are false: CSI ? 4 h/l and CSI 20 h/l write them (Terminal.swift :7163,
:7388, :7148, :7365), and DECRQM answers both. So the two are now CARRIED, each with a byte row.
`gcharset`, `tabStopWidth`, `xDisp` and `xBase` left the format. Each commit quotes the field's
write sites (`bfdcfc2`).

**Three kinds reflection cannot see** (a hand audit, one line each):

- **Static tables.** For example `Terminal.reportedOnlyDECModes` and the charset tables. They are
  the same on both sides because they are code, not state.
- **Unsafe-pointer storage.** Cell storage behind `BufferLine.storage` and the arena. Reflection
  sees a pointer, so the digest compares cells by value, each line to its full width.
- **Lazy caches.** For example the semantic prompt row cache and the render identity. They are
  rebuilt on demand and are excluded by name as caches.

**Coverage.** `everyCarriedFieldIsCoveredByTheCorpusOrOneHandRow` computes the set of hand rows
it needs. The every-cut corpus covers 56 carried paths: at some cut the field differs from a fresh
terminal's, and after export and import the digests are equal. The other 49 each have one hand
row: 18 new in v2, 29 v1 strays, and lineFeedMode and smoothScroll. Every row now sets its state
BY BYTES. Builder #8 thought three rows had to be written directly (hostCurrentDocument,
savedPrivateModes, terminalIconStack), and it was wrong. The test's `fresh()` passed an inline
`Sink()`, and Terminal holds its delegate weakly. So OSC 6 (`tdel?.isProcessTrusted ?? false`)
and XTWINOPS (`guard let tdel`) did nothing. With the sink retained, OSC 6, `CSI ? 2004 h CSI ? 2004 s`
(XTSAVE) and `OSC 1 ; icon BEL CSI 22 ; 1 t` each write their field. Upstream has no bug here.
Tab stops a program sets (HTS/TBC) are corpus-covered, by the stream "modes, tabs, charsets,
insert" (TerminalStateSnapshotTests.swift:168).

**Field count and code size.**

- Fields: 153 image-type fields plus 8 reused TerminalProgramStatus fields = 161 at `b373aa1`,
  then 4 fewer at `bfdcfc2` = 157. v1 had 137; the lead's limit is 274.
- Coding: 720 lines → 779 at `b373aa1`, with 6 lines changed at `bfdcfc2`.
- Snapshot: 605 → 672 lines.

**Sizes and times** (DEBUG build, 200×60 + 10,000 history lines, ReplicationSizeTime):

| | v1 | `b373aa1` | `bfdcfc2` |
|---|---|---|---|
| screen part | 13,742 B | 13,760 B | 13,754 B |
| unsplit | 2,293,818 B | 2,293,836 B | 2,293,830 B |
| export under the lock (screen + history copy) | 19.0 ms | 19.5 ms | 19.4 ms |
| screen decode + import | 7.3 ms | 7.3 ms | 7.6 ms |

Every attach or resync holds the owner's feed for the export time. Scape #1289's gate records the
RELEASE figure beside its wait counter. A release figure over one frame (about 16 ms) goes to the
lead.

**Import and the delegate.**

- Delegate notifications during import see the new modes and buffers: the program status and the
  three colours are set after the buffers are replaced (TerminalStateSnapshot.swift). The screen
  is refreshed after them. Pin: `importTellsTheDelegateAfterTheBuffersAreReplaced`, which passed
  at its red commit, so no reordering was needed.
- `cursorColor` is carried as set. A host that writes it directly, not through the view's caret
  colour, loses that value at import. Scape themes the view's caret and never writes it.

## Pty: close_range on Linux (builder #9; red `692b0b5`, fix `3935ba0`)

**Measured on Linux CI** (kernel 7.0, RLIMIT_NOFILE 65536). The child's close loop (close() for
every fd from 3 up to `fdLimit = max(getdtablesize(), 10240)`) costs about **20.0 ms per session
start**. `close_range(3, ~0U, 0)` costs **193 µs**, against a fork baseline of 185 µs. The loop's
cost grows with the soft limit. At 1M it would be about 320 ms, but that figure is an
extrapolation, not a measurement. A systemd-launched daemon's soft limit is commonly 1024, where
the loop is cheap; the CI runner's limit is 65536.

**The fix** (Pty.swift, 28 lines added, 0 removed, all inside `#if os(Linux)`; Darwin unchanged):

- Swift cannot call the variadic `syscall()`, and the Glibc module declares `close_range` only
  under `_GNU_SOURCE`. So `PseudoTerminalHelpers.closeRangeFunction` resolves it with
  `dlopen(nil, RTLD_NOW)` + `dlsym`, once, as `@convention(c) (UInt32, UInt32, Int32) -> Int32`.
  The precedent is Scape's ScapedLaunchContextProof.swift:370-372.
- The parent reads that static into a local before `forkpty`, which forces its initialisation
  there.
- The child runs `if let closeRange, closeRange(3, UInt32.max, 0) == 0 { leakedFd = fdLimit }`
  just before the existing loop, whose lines are unchanged. Nothing is looked up, allocated or
  locked between fork and exec.
- Any non-zero return (ENOSYS, EINVAL, or EPERM under seccomp), and a nil pointer (glibc older
  than 2.34, or musl), leave the loop to run. No flags are passed.

**The test** (`PtyInheritedDescriptorTests`):

- A pipe end leaked at fd 200 without CLOEXEC is closed in the child, on both platforms and both
  paths. fd 0 is the probe's control and must read open.
- On Linux the child reports which path ran, and the product writes no byte for it. The test
  leaks fd 20000 and lowers the soft limit to 10240 for one fork. The loop stops at fdLimit and
  close_range does not, so the child's shell sees fd 20000 closed (close_range) or open (loop).
- The test restores the limit on every exit path.
- Every run prints `IT-2001 Pty close path: …` with the in-process close_range rc and errno.
- The test fails only if close_range is present and works in-process but the child ran the loop.
- The Mac run exercises the loop. Linux CI is the real test of the close_range path.

## Whole-fork headless A/B after v2 (X = `bfdcfc2`, U = `d4f52faaa` + D9; builder #9)

**Method** (lead 14, 02:20Z): judge by the per-iteration slope between 50 and 200 iterations, which
cancels the launch cost. Both orders. Apple Swift 6.4 (swiftlang-6.4.0.34.1), arm64-apple-macosx27.0,
release, `-align-all-functions=6`. Files: `ab3/b9-slope.tsv`, `b9r-`, `b9aa-`, `b9x7-`, `b9v1-slope.tsv`
in the builder cache.

**Launch** (no-argument run), X − U: +4.01 M (XY) / +4.42 M (YX). The earlier figure was +4.04 M, so
v2's type metadata adds about 0 to +0.4 M instructions, once per process.

**Feed path** (`Tools/feed-path-disasm.py`): the not-dirty one-byte feed is **47 = 47**.

- `feed(byteArray:)` is identical to U's.
- On the not-dirty path, parse's `$defer` runs 20 instructions in both, with the same branch targets.
- The D7 gate sits only on the DIRTY path: 4 added instructions (a load of `cold`, a load of the
  flag, a compare, a branch) before upstream's apply call. U has 11 instructions from the dirty
  test to the call; X has 15.

**Slope, 22 cases.** 20 cases are within ±0.31% in both orders, and their signs flip between orders.
The scroll family runs from −0.31% to +0.005%, and osc_short_chunked is +0.007 / −0.012%.

**medium_cells** first read +0.258 / −0.462. A 4-round recheck gave −0.011 / −0.003: inside.

**sync_medium_cells** (4 rounds unless marked), slope as % of U's ~99.05 M instructions per
iteration:

| Tree vs U | XY | YX |
|---|---|---|
| X `bfdcfc2` (2 rounds) | +0.625 | +0.016 |
| X `bfdcfc2` | +0.117 | +0.291 |
| X7 `e4cc3ac`, before v2 | +0.022 | +0.111 |
| V1 = X minus the D7 gate | +0.186 | −0.070 |
| A/A: U vs U2 | −0.120 | −0.010 |

One iteration is ONE feed call: the whole 1.11 MB sample, with no chunking. The sample holds 2,772
DEC 2026 transitions, but begin and end only set the dirty flag while inside parse, so reconcile
runs once. That is N = 1 dirty feed per iteration, and N × 4 = 4 instructions, against an excess
of 100 to 300 K. Three findings follow:

- The gate is not the cause: removing it (V1) leaves the same excess.
- v2 is not the cause: X7, from before v2, shows the same order of excess.
- The remainder sits at this method's resolution. A single 200-iteration run of U alone scatters
  ±0.3% (20.836 to 21.097 G instructions), and the variants differ from each other by as much as
  X differs from U.

On this count, the lead's unruled alternative for D7 ("nil stored as a timeout that never comes
due") would save at most 4 instructions per dirty feed, about 4 per iteration here. It is not
reopened.

The dirty path in parse's `$defer`, from the dirty test (`ldrb w8, [x20, #0x150]; cmp w8, #0x1;
b.ne`) to upstream's apply call:

    U (11)                                X (15)
    strb wzr, [x20, #0x150]               strb wzr, [x20, #0x150]
                                          ldr  x8, [x20, #0x3e0]    ; cold
                                          ldrb w8, [x8, #0x39]      ; synchronizedOutputTimeoutDisabled
                                          cmp  w8, #0x1
                                          b.ne -> apply              ; else bl reconcileDisabled…; b exit
    add  x0, x20, #0x140                  add  x0, x20, #0x140
    add  x1, sp, #0x8                     add  x1, sp, #0x8
    mov  x2, #0x0                         mov  x2, #0x0
    mov  x3, #0x0                         mov  x3, #0x0
    bl   swift_beginAccess                bl   swift_beginAccess
    ldrb w0, [x20, #0x140]                ldrb w0, [x20, #0x140]
    ldr  x1, [x20, #0x148]                ldr  x1, [x20, #0x148]
    ldr  x8, [x20]                        ldr  x8, [x20]
    ldr  x8, [x8, #0x17d0]                ldr  x8, [x8, #0x1850]
    blr  x8                               blr  x8

So the gate adds 4 instructions per DIRTY feed; the not-dirty path is 47 = 47.

**The 8-round closing run** (X, U, U2; sync_medium_cells only; both orders). Its verdict rule was
set before the run. The case is closed as "at the method's resolution, no attributable fork line"
if X − U is inside the U − U2 spread in at least one order, or if its mean excess is under 0.1%. If
it is above the A/A spread in both orders by more than 0.1%, the next step is a per-function
instruction diff of the two binaries. Result:

- X − U: +0.151% (XY) / +0.121% (YX).
- A/A U − U2: −0.054% (XY) / +0.163% (YX).
- In the YX order, X − U is inside the A/A spread. **Closed: at the method's resolution, no
  attributable fork line.** (Files: `ab3/b9r8-slope.tsv`, `b9aa8-slope.tsv`.)

**tabStopWidth after the drop.** Import reads it only through the read-only accessor
`replicationTabStopWidth`, to BUILD the replica's buffers (construction). It is not carried. Fix
`53a1884`, found by the full suite's ReplicationSourceScanTests at `bfdcfc2`.
