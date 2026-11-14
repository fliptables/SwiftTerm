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
