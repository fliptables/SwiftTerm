#if !os(iOS) && !os(Windows)
import Foundation
import Testing
@_spi(Replication) @testable import SwiftTerm
#if os(macOS)
import AppKit
#endif

/// IT-2001 format v2: the behaviours the census alone does not prove. Each case exports
/// from an owner, imports into a replica, then feeds both the same bytes.
final class ReplicationFormatV2Tests {
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private static func make() -> Terminal {
        let terminal = Terminal(delegate: Sink(), options: TerminalOptions(cols: 30, rows: 8, scrollback: 50))
        terminal.synchronizedOutputTimeout = nil
        return terminal
    }

    private static func replicate(_ owner: Terminal, into replica: Terminal) throws {
        replica.respondsToQueries = false
        let snapshot = try #require(owner.exportState())
        replica.importState(try TerminalStateSnapshot(encoded: snapshot.encoded()))
    }

    private static func both(_ a: Terminal, _ b: Terminal, _ text: String) {
        a.feed(text: text)
        b.feed(text: text)
    }

    /// Plan §5: STSS and STSH share one version constant, 2, and each refuses version 1.
    @Test func versionOneIsRefusedForBothMagics() throws {
        #expect(TerminalStateSnapshot.formatVersion == 2)
        #expect(TerminalHistoryChunk.formatVersion == TerminalStateSnapshot.formatVersion)
        let owner = Self.make()
        owner.feed(text: (0..<20).map { "line \($0)\r\n" }.joined())
        var screen = try #require(owner.exportState()).encoded()
        screen.replaceSubrange(4..<8, with: [1, 0, 0, 0])
        #expect(throws: TerminalStateSnapshotError.unsupportedVersion(1)) { try TerminalStateSnapshot(encoded: screen) }
        let export = try #require(owner.exportForStreaming())
        var chunk = try #require(export.historyChunks(linesPerChunk: 5).first).encoded()
        chunk.replaceSubrange(4..<8, with: [1, 0, 0, 0])
        #expect(throws: TerminalStateSnapshotError.unsupportedVersion(1)) { try TerminalHistoryChunk(encoded: chunk) }
    }

    /// Plan §5: a pending-wrap cut on the ALTERNATE buffer continues as on the owner.
    @Test func aPendingWrapOnTheAlternateScreenContinues() throws {
        let owner = Self.make(), replica = Self.make()
        owner.feed(text: "\u{1b}[?1049h" + String(repeating: "x", count: 30))
        #expect(owner.buffer.pendingWrap)
        try Self.replicate(owner, into: replica)
        Self.both(owner, replica, "y")
        #expect(owner.replicationDigest() == replica.replicationDigest())
    }

    /// Plan §5: `savedPendingWrap` is its own field, proved by a DECRC fed after the import.
    @Test func aRestoreCursorAfterImportRestoresThePendingWrap() throws {
        let owner = Self.make(), replica = Self.make()
        owner.feed(text: String(repeating: "x", count: 30) + "\u{1b}7\u{1b}[3;3H")
        #expect(!owner.buffer.pendingWrap)
        try Self.replicate(owner, into: replica)
        Self.both(owner, replica, "\u{1b}8y")
        #expect(owner.buffer.y == 1, "the owner wrapped after DECRC")
        #expect(owner.replicationDigest() == replica.replicationDigest())
    }

    /// Plan §5: the OSC 10/11/12 colours travel without the host colour under them, so
    /// OSC 110/111/112 on each side restore that side's own colour.
    @Test func eachSideRestoresItsOwnHostColour() throws {
        let owner = Self.make(), replica = Self.make()
        let ownerHost = (fg: Color(red: 0x1000, green: 0x1000, blue: 0x1000), bg: Color(red: 0x2000, green: 0x2000, blue: 0x2000))
        let replicaHost = (fg: Color(red: 0xa000, green: 0xa000, blue: 0xa000), bg: Color(red: 0xb000, green: 0xb000, blue: 0xb000))
        owner.foregroundColor = ownerHost.fg; owner.backgroundColor = ownerHost.bg
        replica.foregroundColor = replicaHost.fg; replica.backgroundColor = replicaHost.bg
        owner.feed(text: "\u{1b}]10;rgb:11/22/33\u{7}\u{1b}]11;rgb:44/55/66\u{7}\u{1b}]12;rgb:77/88/99\u{7}")
        try Self.replicate(owner, into: replica)
        #expect(replica.foregroundColor == owner.foregroundColor)
        #expect(replica.backgroundColor == owner.backgroundColor)
        #expect(replica.cursorColor == owner.cursorColor && owner.cursorColor != nil)
        Self.both(owner, replica, "\u{1b}]110\u{7}\u{1b}]111\u{7}\u{1b}]112\u{7}")
        #expect(owner.foregroundColor == ownerHost.fg && owner.backgroundColor == ownerHost.bg)
        #expect(replica.foregroundColor == replicaHost.fg && replica.backgroundColor == replicaHost.bg)
        #expect(owner.cursorColor == nil && replica.cursorColor == nil)
    }

    /// A resync: an import over a replica that holds its own OSC colours leaves the owner's
    /// (none), so the replica shows its host colour again.
    @Test func aResyncDropsTheReplicasStaleOscColours() throws {
        let owner = Self.make(), replica = Self.make()
        let host = Color(red: 0xa000, green: 0xa000, blue: 0xa000)
        replica.foregroundColor = host
        replica.feed(text: "\u{1b}]10;rgb:11/22/33\u{7}\u{1b}]12;rgb:77/88/99\u{7}")
        try Self.replicate(owner, into: replica)
        #expect(replica.foregroundColor == host)
        #expect(replica.cursorColor == nil)
    }

    /// Plan §5: program status keeps its ordering and replacement: an update after the
    /// import replaces or appends exactly as on the owner.
    @Test func aProgramStatusUpdateAfterImportActsAsOnTheOwner() throws {
        let owner = Self.make(), replica = Self.make()
        owner.feed(text: "\u{1b}]7501;state=working:id=a\u{1b}\\\u{1b}]7501;state=blocked:kind=question:id=b\u{1b}\\")
        try Self.replicate(owner, into: replica)
        #expect(replica.programStatusRecords == owner.programStatusRecords)
        Self.both(owner, replica, "\u{1b}]7501;state=done:id=a\u{1b}\\\u{1b}]7501;state=idle:id=c\u{1b}\\")
        #expect(owner.programStatusRecords.map(\.id) == ["b", "a", "c"])
        #expect(replica.programStatusRecords == owner.programStatusRecords)
    }

    /// Plan §5 (X6): images are not in the format, so an import over a terminal that holds
    /// one clears it (upstream's own clear, as RIS does): nothing stale is drawn over the
    /// imported text, and no animation deadline is left to re-arm a timer.
    @Test func anImportOverAnImageLeavesNoImage() throws {
        let owner = Self.make(), replica = Self.make()
        let payload = Data([1, 2, 3]).base64EncodedString()
        replica.feed(text: "\u{1b}_Ga=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1;\(payload)\u{1b}\\")
        try #require(!replica.kittyGraphicsState.placementsByKey.isEmpty)
        try Self.replicate(owner, into: replica)
        #expect(replica.kittyGraphicsState.primary.imagesById.isEmpty)
        #expect(replica.kittyGraphicsState.alternate.imagesById.isEmpty)
        #expect(replica.kittyGraphicsState.placementsByKey.isEmpty)
        #expect(!replica.hasKittyPlacements)
        #expect(replica.kittyGraphicsAdvanceAnimations(monotonicNanoseconds: 1 << 62) == nil)
    }

    /// Lead 15 (03:17Z, Q1): a field no parsed byte writes carries nothing between owner and
    /// replica and is not in the format (each one's write sites are quoted in the commit that
    /// dropped it); the construction parameters stay.
    @Test func theFormatHoldsNoFieldThatNoByteWrites() throws {
        let snapshot = try #require(Self.make().exportState())
        let modes = Set(Mirror(reflecting: snapshot.modes).children.compactMap(\.label))
        let buffer = Set(Mirror(reflecting: snapshot.normal).children.compactMap(\.label))
        for dropped in ["gcharset", "tabStopWidth"] { #expect(!modes.contains(dropped), "modes still carries \(dropped)") }
        for dropped in ["xDisp", "xBase", "hasScrollback"] { #expect(!buffer.contains(dropped), "buffer still carries \(dropped)") }
        #expect(modes.isSuperset(of: ["lineFeedMode", "smoothScroll"]))
        #expect(buffer.contains("scrollback"))
    }

    /// Delegate notifications during import (program status, the three colours) see the
    /// imported buffers: each one comes after the buffers are replaced.
    @Test func importTellsTheDelegateAfterTheBuffersAreReplaced() throws {
        final class Recorder: TerminalDelegate {
            var firstLineAtCall: [String] = []
            func send(source: Terminal, data: ArraySlice<UInt8>) {}
            private func note(_ source: Terminal) {
                firstLineAtCall.append(source.buffer.lines[0].translateToString(trimRight: true))
            }
            func setForegroundColor(source: Terminal, color: Color) { note(source) }
            func setBackgroundColor(source: Terminal, color: Color) { note(source) }
            func setCursorColor(source: Terminal, color: Color?) { note(source) }
            func programStatusChanged(source: Terminal, records: [TerminalProgramStatus]) { note(source) }
        }
        let owner = Self.make()
        owner.feed(text: "owner\u{1b}]10;rgb:11/22/33\u{7}\u{1b}]11;rgb:44/55/66\u{7}\u{1b}]12;rgb:77/88/99\u{7}"
                   + "\u{1b}]7501;state=working:id=a\u{1b}\\")
        let recorder = Recorder()
        let replica = Terminal(delegate: recorder, options: TerminalOptions(cols: 30, rows: 8, scrollback: 50))
        replica.synchronizedOutputTimeout = nil
        replica.feed(text: "replica")
        recorder.firstLineAtCall.removeAll()
        try Self.replicate(owner, into: replica)
        #expect(recorder.firstLineAtCall.count >= 4, "calls: \(recorder.firstLineAtCall)")
        #expect(recorder.firstLineAtCall.allSatisfy { $0 == "owner" }, "a delegate call saw the old buffers: \(recorder.firstLineAtCall)")
    }

    // MARK: Decode validation (keystone 17's read, via Lloyd 16B314D0)

    /// A valid snapshot with a cell, a grapheme, history and the alternate screen in use.
    private static func validSnapshot() throws -> TerminalStateSnapshot {
        let owner = make()
        owner.feed(text: (0..<20).map { "line \($0)\r\n" }.joined() + "e\u{301} x")
        return try #require(owner.exportState())
    }

    /// Edits one field of a valid snapshot's image, re-encodes it, and expects decode to refuse it.
    private static func refuses(_ what: String, _ edit: (inout TerminalStateSnapshot) -> Void) throws {
        var snapshot = try validSnapshot()
        // The unedited image decodes, so a refusal below is the edit's.
        let unedited = snapshot.encoded()
        #expect(throws: Never.self, "\(what): the unedited snapshot") { _ = try TerminalStateSnapshot(encoded: unedited) }
        edit(&snapshot)
        let bytes = snapshot.encoded()
        #expect(throws: TerminalStateSnapshotError.self, "\(what) decoded") { try TerminalStateSnapshot(encoded: bytes) }
    }

    /// (a) Terminal keeps exactly four G0-G3 sets (Terminal.swift setup), and gLevel indexes them.
    @Test func decodeRefusesAWrongCharsetTable() throws {
        try Self.refuses("3 charsets") { $0.modes.gCharsets.removeLast() }
        try Self.refuses("5 charsets") { $0.modes.gCharsets.append(nil) }
        try Self.refuses("gLevel 4") { $0.modes.gLevel = 4 }
    }

    /// (b) A TAB reads tabStops[x] for every x < cols.
    @Test func decodeRefusesShortTabStops() throws {
        try Self.refuses("no tab stops") { $0.normal.tabStops = [] }
        // A fresh buffer holds cols + 1 stops (observed 31 at 30 cols), a resized one cols.
        try Self.refuses("tab stops short by one") { $0.normal.tabStops = Array($0.normal.tabStops.prefix(29)) }
    }

    /// (c) Every cell scalar and grapheme scalar must be one the arena stores.
    @Test func decodeRefusesAnInvalidScalar() throws {
        try Self.refuses("surrogate code") { $0.normal.lines[0].cells[0].code = 0xD800 }
        try Self.refuses("code above U+10FFFF") { $0.normal.lines[0].cells[0].code = 0x110000 }
        try Self.refuses("negative code") { $0.normal.lines[0].cells[0].code = -5 }
        try Self.refuses("surrogate grapheme") { snapshot in
            let row = snapshot.normal.lines.firstIndex { $0.cells.contains { $0.graphemes != nil } }!
            let column = snapshot.normal.lines[row].cells.firstIndex { $0.graphemes != nil }!
            snapshot.normal.lines[row].cells[column].graphemes = [0x65, 0xDC00]
        }
    }

    /// (d) Dimensions and positions import assigns unchecked.
    @Test func decodeRefusesAPositionOutsideTheGrid() throws {
        try Self.refuses("buffer cols != modes cols") { $0.normal.cols = 31 }
        // Only the ACTIVE buffer must match the modes' grid: a resize reaches only the active
        // buffer (observed: the hidden normal buffer under the alternate screen keeps its grid).
        try Self.refuses("active rows != modes rows") { $0.normal.rows = 9 }
        try Self.refuses("zero rows on the hidden buffer") { $0.alt.rows = 0 }
        // An alternate buffer never activated exports 0 lines (observed): 0 is allowed, 1..<rows is not.
        try Self.refuses("fewer lines than rows") { $0.normal.lines = Array($0.normal.lines.prefix(7)); $0.normal.yBase = 0; $0.normal.yDisp = 0 }
        try Self.refuses("no lines on the active buffer") { $0.normal.lines = []; $0.normal.yBase = 0; $0.normal.yDisp = 0 }
        // A line WIDER than the buffer is honest (a resize without reflow keeps it: observed);
        // a narrower one trips Buffer.resize's post-condition (fatalError).
        try Self.refuses("a line narrower than the buffer") { $0.normal.lines[0].cols = 29 }
        try Self.refuses("x past cols") { $0.normal.x = 31 }
        try Self.refuses("savedX past cols") { $0.normal.savedX = 31 }
        try Self.refuses("y at rows") { $0.normal.y = 8 }
        // savedY outside 0..<rows is honest after a resize smaller (observed -3); restore clamps it.
        try Self.refuses("linesTop near Int.max") { $0.normal.linesTop = Int.max }
        try Self.refuses("mark column Int.min") {
            $0.normal.lines[0].semanticMarks = [SemanticMark(kind: .initial, column: Int.min, group: 0)]
        }
        try Self.refuses("savedY Int.min") { $0.normal.savedY = Int.min }
        try Self.refuses("savedY Int.max") { $0.normal.savedY = Int.max }
        try Self.refuses("scrollTop after scrollBottom") { $0.normal.scrollTop = 5; $0.normal.scrollBottom = 4 }
        try Self.refuses("scrollBottom at rows") { $0.normal.scrollBottom = 8 }
        try Self.refuses("marginLeft after marginRight") { $0.normal.marginLeft = 10; $0.normal.marginRight = 9 }
        try Self.refuses("marginRight at cols") { $0.normal.marginRight = 30 }
        try Self.refuses("negative marginLeft") { $0.normal.marginLeft = -1 }
        // yBase past lines.count - rows is honest (observed on an alternate buffer grown by a
        // resize); past lines.count it is not.
        try Self.refuses("yBase past the lines") { $0.normal.yBase = $0.normal.lines.count + 1 }
        try Self.refuses("yDisp past the lines") { $0.normal.yDisp = $0.normal.lines.count + 1 }
        try Self.refuses("negative yDisp") { $0.normal.yDisp = -1 }
        try Self.refuses("negative linesTop") { $0.normal.linesTop = -1 }
        try Self.refuses("scrollback past upstream's clamp") { $0.normal.scrollback = Int(Int32.max) }
        try Self.refuses("line capacity below rows") { $0.normal.lineCapacity = 7 }
        try Self.refuses("line capacity below the lines held") { $0.normal.lineCapacity = $0.normal.lines.count - 1 }
    }

    /// The positive side: snapshots of live terminals in the states the invariants are most
    /// likely to get wrong still decode (pending wrap at the last column, a scrolled view, the
    /// alternate screen, a margin region, a resize smaller and back). The every-cut corpus
    /// (TerminalStateSnapshotTests.everyCutReplicates, everyParserClauseCutReplicates) and the
    /// streaming tests decode every export they make, so they are the wider positive check.
    @Test func liveExportsInEdgeStatesStillDecode() throws {
        let streams: [(String, (Terminal) -> Void)] = [
            ("pending wrap", { $0.feed(text: String(repeating: "x", count: 30)) }),
            ("saved at the last column", { $0.feed(text: String(repeating: "x", count: 30) + "\u{1b}7") }),
            ("scrolled history", { $0.feed(text: (0..<80).map { "l\($0)\r\n" }.joined()) }),
            ("alternate screen", { $0.feed(text: "a\r\n\u{1b}[?1049hb\u{1b}[3;5r\u{1b}[?69h\u{1b}[2;9s") }),
            ("resize smaller", { t in t.feed(text: (0..<60).map { "l\($0)\r\n" }.joined()); t.resize(cols: 20, rows: 5) }),
            ("resize smaller and back", { t in
                t.feed(text: (0..<60).map { "l\($0)\r\n" }.joined()); t.resize(cols: 12, rows: 4); t.resize(cols: 30, rows: 8)
            }),
            ("alt screen resized", { t in t.feed(text: "\u{1b}[?1049hxyz"); t.resize(cols: 40, rows: 10) }),
        ]
        for (name, setUp) in streams {
            let owner = Self.make()
            setUp(owner)
            let snapshot = try #require(owner.exportState(), "\(name): no export")
            #expect(throws: Never.self, "\(name): \(Self.summary(snapshot))") { _ = try TerminalStateSnapshot(encoded: snapshot.encoded()) }
            let streaming = try #require(owner.exportForStreaming(), "\(name): no streaming export")
            #expect(throws: Never.self, "\(name) (screen part): \(Self.summary(streaming.screen))") { _ = try TerminalStateSnapshot(encoded: streaming.screen.encoded()) }
            for chunk in streaming.historyChunks(linesPerChunk: 7) {
                #expect(throws: Never.self, "\(name) (chunk \(chunk.index))") { _ = try TerminalHistoryChunk(encoded: chunk.encoded()) }
            }
        }
    }

    /// The fields validate() reads, for a failure message.
    private static func summary(_ snapshot: TerminalStateSnapshot) -> String {
        func one(_ b: BufferImage) -> String {
            "\(b.cols)x\(b.rows) lines \(b.lines.count) widths \(Set(b.lines.map(\.cols)).sorted()) cap \(b.lineCapacity) "
                + "x \(b.x) y \(b.y) saved \(b.savedX),\(b.savedY) yBase \(b.yBase) yDisp \(b.yDisp) "
                + "region \(b.scrollTop)-\(b.scrollBottom) margins \(b.marginLeft)-\(b.marginRight) stops \(b.tabStops.count)"
        }
        return "grid \(snapshot.cols)x\(snapshot.rows) alt \(snapshot.alternateScreenActive) | normal \(one(snapshot.normal)) | alt \(one(snapshot.alt))"
    }

    /// Resize cuts in both directions on both buffers, each decoded whole and streamed.
    @Test func resizeCutsStillDecode() throws {
        let history = (0..<60).map { "line \($0) " + String(repeating: "w", count: $0 % 40) + "\r\n" }.joined()
        let sizes = [(20, 5), (12, 4), (45, 14), (30, 8), (80, 3), (3, 20)]
        for alternate in [false, true] {
            for (cols, rows) in sizes {
                let owner = Self.make()
                owner.feed(text: history + "\u{1b}[3;6H\u{1b}7\u{1b}[2;7r")
                if alternate { owner.feed(text: "\u{1b}[?1049h" + history + "\u{1b}[4;9H\u{1b}7") }
                owner.resize(cols: cols, rows: rows)
                owner.feed(text: "z")
                let name = "\(alternate ? "alt" : "normal") \(cols)x\(rows)"
                let snapshot = try #require(owner.exportState(), "\(name): no export")
                #expect(throws: Never.self, "\(name): \(Self.summary(snapshot))") { _ = try TerminalStateSnapshot(encoded: snapshot.encoded()) }
                let streaming = try #require(owner.exportForStreaming(), "\(name): no streaming export")
                #expect(throws: Never.self, "\(name) (screen part): \(Self.summary(streaming.screen))") { _ = try TerminalStateSnapshot(encoded: streaming.screen.encoded()) }
                for chunk in streaming.historyChunks(linesPerChunk: 9) {
                    #expect(throws: Never.self, "\(name) (chunk \(chunk.index))") { _ = try TerminalHistoryChunk(encoded: chunk.encoded()) }
                }
            }
        }
    }

    /// Over-tight byte bounds would refuse honest exports: wide lines (all written, all
    /// blank in a colour, all wide) and a long scrollback still decode, whole and streamed.
    @Test func wideLinesAndALongScrollbackStillDecode() throws {
        let sink = Sink()
        let owner = Terminal(delegate: sink, options: TerminalOptions(cols: 500, rows: 24, scrollback: 5000))
        owner.synchronizedOutputTimeout = nil
        owner.feed(text: String(repeating: "x", count: 500) + "\r\n")
        owner.feed(text: "\u{1b}[44m" + String(repeating: " ", count: 500) + "\u{1b}[0m\r\n")
        owner.feed(text: "\u{1b}[41m\u{1b}[K\u{1b}[0m\r\n")
        owner.feed(text: String(repeating: "\u{4e00}", count: 250) + "\r\n")
        owner.feed(text: (0..<6000).map { "history \($0) " + String(repeating: "h", count: $0 % 400) + "\r\n" }.joined())
        owner.feed(text: String(repeating: "e\u{301}", count: 500))
        let snapshot = try #require(owner.exportState())
        #expect(snapshot.normal.lines.count == 5024)
        #expect(try TerminalStateSnapshot(encoded: snapshot.encoded()) == snapshot)
        let streaming = try #require(owner.exportForStreaming())
        #expect(throws: Never.self) { _ = try TerminalStateSnapshot(encoded: streaming.screen.encoded()) }
        for chunk in streaming.historyChunks() {
            #expect(throws: Never.self, "chunk \(chunk.index)") { _ = try TerminalHistoryChunk(encoded: chunk.encoded()) }
        }
        withExtendedLifetime(sink) {}
    }

    /// Imports `snapshot` and drives every reader of the relaxed fields: DECRC on both buffers,
    /// a scroll, resizes both ways (savedY arithmetic in resize and reflow), an alternate
    /// screen round trip and an export. A trap here fails the whole run.
    /// `replicaExportDecodes` is false for a screen part imported without its chunks: that
    /// replica holds fewer lines than rows and exports them with no history pending (observed
    /// 40x12 holding 8 lines after the drive), a state no owner exports. Its export must still
    /// not trap.
    private static func survives(_ snapshot: TerminalStateSnapshot, replicaExportDecodes: Bool = true) throws {
        let decoded: TerminalStateSnapshot
        do { decoded = try TerminalStateSnapshot(encoded: snapshot.encoded()) } catch {
            Issue.record("the snapshot itself did not decode: \(error) \(summary(snapshot))"); return
        }
        let replica = make()
        replica.importState(decoded)
        replica.feed(text: "\u{1b}8x\r\n\u{1b}[2S\u{1b}[1T" + (0..<12).map { "after \($0)\r\n" }.joined())
        replica.resize(cols: 20, rows: 5)
        replica.feed(text: "\u{1b}8y\u{1b}[?1049h\u{1b}8z\u{1b}[?1049l\u{1b}8")
        replica.resize(cols: 40, rows: 12)
        replica.feed(text: "\u{1b}8w")
        let again = try #require(replica.exportState())
        if replicaExportDecodes {
            #expect(throws: Never.self, "the replica's export: \(summary(again))") { _ = try TerminalStateSnapshot(encoded: again.encoded()) }
        }
    }

    /// The relaxed savedY (no grid check) at its accepted extremes imports and survives.
    @Test func aSavedRowAtTheAcceptedExtremesSurvives() throws {
        for value in [Int(Int32.max), -Int(Int32.max), -3, 8, 1000] {
            var snapshot = try Self.validSnapshot()
            snapshot.normal.savedY = value
            try Self.survives(snapshot)
        }
    }

    /// The relaxed view (yBase, yDisp up to lines.count, past lines.count - rows) imports and survives.
    /// Upstream resizes the alternate buffer on every resize (Terminal.resizeBuffers); only the
    /// normal buffer is deferred, and only while the alternate screen is active. A hidden grid is
    /// FILLED at its next activation (fillViewportRows: rows lines of cols cells), and an active
    /// one fills its missing rows lazily, so the cap counts rows x cols as well as the lines held.
    /// Decode only; never imported.
    @Test func decodeRefusesAGridThatFillsPastTheCellCap() throws {
        try Self.refuses("a hidden alt grid past the cap, no lines") { snapshot in
            let side = 65535
            snapshot.modes.cols = side; snapshot.modes.rows = side
            for alternate in [false, true] {
                var buffer = alternate ? snapshot.alt : snapshot.normal
                buffer.cols = side; buffer.rows = side
                buffer.lineCapacity = side + (buffer.scrollback ?? 0)
                buffer.scrollBottom = side - 1; buffer.marginRight = side - 1
                buffer.tabStops = Array(repeating: false, count: side)
                if alternate {
                    buffer.lines = []
                } else {
                    // The normal buffer holds its grid in pending history, no lines decoded wide.
                    buffer.lines = [buffer.lines[buffer.lines.count - 1]]
                    buffer.lines[0].cols = side; buffer.lines[0].cells = []
                    buffer.pendingHistoryLines = side - 1
                    buffer.yBase = 0; buffer.yDisp = 0; buffer.y = 0; buffer.savedY = 0
                    buffer.semanticPromptStartRow = nil
                }
                if alternate { snapshot.alt = buffer } else { snapshot.normal = buffer }
            }
        }
        try Self.refuses("an active grid filled from pending history past the cap") { snapshot in
            let cols = 65535, rows = 2000
            snapshot.modes.cols = cols; snapshot.modes.rows = rows
            var buffer = snapshot.normal
            buffer.cols = cols; buffer.rows = rows
            buffer.lineCapacity = rows + (buffer.scrollback ?? 0)
            buffer.scrollBottom = rows - 1; buffer.marginRight = cols - 1
            buffer.tabStops = Array(repeating: false, count: cols)
            buffer.lines = [buffer.lines[buffer.lines.count - 1]]
            buffer.lines[0].cols = cols; buffer.lines[0].cells = []
            buffer.pendingHistoryLines = rows - 1
            buffer.yBase = 0; buffer.yDisp = 0; buffer.y = 0; buffer.savedY = 0
            buffer.semanticPromptStartRow = nil
            snapshot.normal = buffer
            snapshot.alt.cols = cols; snapshot.alt.rows = rows
            snapshot.alt.tabStops = Array(repeating: false, count: cols)
            snapshot.alt.scrollBottom = rows - 1; snapshot.alt.marginRight = cols - 1
            snapshot.alt.lineCapacity = rows
        }
    }

    /// The alternate buffer always has the modes' grid; only the normal buffer, hidden under
    /// the alternate screen, may keep an older one. Only the inactive alternate buffer may be empty.
    @Test func decodeRefusesAHiddenGridUpstreamNeverLeaves() throws {
        try Self.refuses("hidden alt cols != modes cols") { snapshot in
            snapshot.alt.cols = 31
            snapshot.alt.tabStops = Array(repeating: false, count: 31)
            snapshot.alt.marginRight = 30
        }
        let owner = Self.make()
        owner.feed(text: (0..<20).map { "line \($0)\r\n" }.joined() + "\u{1b}[?1049halt")
        let onAlt = try #require(owner.exportState())
        #expect(throws: Never.self) { _ = try TerminalStateSnapshot(encoded: onAlt.encoded()) }
        var emptyNormal = onAlt
        emptyNormal.normal.lines = []; emptyNormal.normal.yBase = 0; emptyNormal.normal.yDisp = 0
        emptyNormal.normal.semanticPromptStartRow = nil
        let bytes = emptyNormal.encoded()
        #expect(throws: TerminalStateSnapshotError.self, "a hidden normal buffer with no lines decoded") {
            try TerminalStateSnapshot(encoded: bytes)
        }
    }

    /// The relaxed "lines + pending history >= rows", driven: the honest screen part of an
    /// alternate buffer grown by a resize (8 lines for 14 rows), imported before any chunk, and
    /// the extreme, one line with rows - 1 still to come.
    @Test func aScreenPartWithHistoryStillToComeSurvives() throws {
        let owner = Self.make()
        let history = (0..<60).map { "line \($0)\r\n" }.joined()
        owner.feed(text: history + "\u{1b}[?1049h" + history + "\u{1b}[4;9H\u{1b}7")
        owner.resize(cols: 45, rows: 14)
        owner.feed(text: "z")
        let screen = try #require(owner.exportForStreaming()).screen
        #expect(screen.alt.lines.count < screen.alt.rows, "\(Self.summary(screen))")
        try Self.survives(screen, replicaExportDecodes: false)
        var extreme = try Self.validSnapshot()
        extreme.normal.pendingHistoryLines = extreme.normal.rows - 1
        extreme.normal.lines = [extreme.normal.lines[extreme.normal.lines.count - 1]]
        extreme.normal.yBase = 0; extreme.normal.yDisp = 0; extreme.normal.y = 0
        extreme.normal.semanticPromptStartRow = nil
        try Self.survives(extreme, replicaExportDecodes: false)
    }

    @Test func aViewAtTheLinesHeldSurvives() throws {
        var snapshot = try Self.validSnapshot()
        snapshot.normal.yBase = snapshot.normal.lines.count
        snapshot.normal.yDisp = snapshot.normal.lines.count
        try Self.survives(snapshot)
        var displayOnly = try Self.validSnapshot()
        displayOnly.normal.yDisp = displayOnly.normal.lines.count
        try Self.survives(displayOnly)
    }

    /// Upstream pushes titles without a cap (CSI 22 t), so decode bounds the stacks by the bytes left.
    @Test func aTitleStackDeeperThan4096Decodes() throws {
        let sink = Sink()  // Terminal holds its delegate weakly, and CSI 22 t goes through it.
        let owner = Terminal(delegate: sink, options: TerminalOptions(cols: 30, rows: 8, scrollback: 50))
        owner.feed(text: String(repeating: "\u{1b}[22;0t", count: 4097))
        let snapshot = try #require(owner.exportState())
        #expect(snapshot.modes.terminalTitleStack.count == 4097)
        let decoded = try TerminalStateSnapshot(encoded: snapshot.encoded())
        #expect(decoded == snapshot)
        withExtendedLifetime(sink) {}
    }

    /// A cell takes any number of combining marks, so decode bounds a grapheme by the bytes left.
    @Test func aCellWithAHundredCombiningMarksDecodes() throws {
        let owner = Self.make()
        owner.feed(text: "e" + String(repeating: "\u{301}", count: 100))
        let snapshot = try #require(owner.exportState())
        let decoded = try TerminalStateSnapshot(encoded: snapshot.encoded())
        #expect(decoded == snapshot)
    }

    /// A width state outside 0...3 makes import's arena.pack fail (a precondition trap).
    @Test func decodeRefusesAnInvalidWidthState() throws {
        try Self.refuses("width state 4") { $0.normal.lines[0].cells[0].widthState = 4 }
    }

    /// A small stream must not make import allocate cols x lines cells beyond the cap: a
    /// 65535 x 65535 grid of near-empty lines is under 1 MB encoded and ~34 GB imported.
    /// The check (maximumCells) runs in validate() at the end of init(encoded:), before import
    /// allocates anything. Asserts on decode only (decode keeps written prefixes and bounds every
    /// reserve by the bytes left, so it never allocates the grid); this test never imports.
    @Test func decodeRefusesAGridPastTheCellCap() throws {
        try Self.refuses("65535 x 65535") { snapshot in
            let side = 65535
            snapshot.modes.cols = side; snapshot.modes.rows = side
            var blank = snapshot.normal.lines[snapshot.normal.lines.count - 1]
            blank.cols = side; blank.cells = []
            for alternate in [false, true] {
                var buffer = alternate ? snapshot.alt : snapshot.normal
                buffer.cols = side; buffer.rows = side
                buffer.lines = alternate ? [] : Array(repeating: blank, count: side)
                buffer.lineCapacity = side + (buffer.scrollback ?? 0)
                buffer.yBase = 0; buffer.yDisp = 0; buffer.x = 0; buffer.y = 0; buffer.savedX = 0; buffer.savedY = 0
                buffer.scrollTop = 0; buffer.scrollBottom = side - 1; buffer.marginLeft = 0; buffer.marginRight = side - 1
                buffer.tabStops = Array(repeating: false, count: side)
                buffer.semanticPromptStartRow = nil
                if alternate { snapshot.alt = buffer } else { snapshot.normal = buffer }
            }
        }
    }

    /// The history chunk's decode: the same invariants for what it carries.
    @Test func historyChunkDecodeRefusesCorruptValues() throws {
        let owner = Self.make()
        owner.feed(text: (0..<20).map { "line \($0) e\u{301}\r\n" }.joined())
        let export = try #require(owner.exportForStreaming())
        let valid = try #require(export.historyChunks(linesPerChunk: 5).first)
        #expect(throws: Never.self) { _ = try TerminalHistoryChunk(encoded: valid.encoded()) }
        func refuses(_ what: String, _ edit: (inout TerminalHistoryChunk) -> Void) {
            var chunk = valid
            edit(&chunk)
            let bytes = chunk.encoded()
            #expect(throws: TerminalStateSnapshotError.self, "\(what) decoded") { try TerminalHistoryChunk(encoded: bytes) }
        }
        refuses("zero cols") { $0.bufferCols = 0 }
        refuses("zero rows") { $0.bufferRows = 0 }
        refuses("a line narrower than the buffer") { $0.lines[0].cols = 29 }
        // Import builds every line at its width before trimming: 1100 x 65535 > maximumCells.
        // Decode only; never imported.
        refuses("cells past the cap") { chunk in
            var wide = chunk.lines[0]
            wide.cols = 65535
            chunk.lines = Array(repeating: wide, count: 1100)
            chunk.semanticPromptStartRow = nil
        }
        refuses("no lines") { $0.lines = []; $0.semanticPromptStartRow = nil }
        refuses("surrogate code") { $0.lines[0].cells[0].code = 0xD800 }
        refuses("surrogate grapheme") { chunk in
            let column = chunk.lines[0].cells.firstIndex { $0.graphemes != nil }!
            chunk.lines[0].cells[column].graphemes = [0x65, 0xDC00]
        }
        refuses("width state 4") { $0.lines[0].cells[0].widthState = 4 }
    }

    #if os(macOS)
    @MainActor private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Lead (Q1): on a VIEW-backed replica, after a resync import the drawn caret and
    /// background colours are the owner's. Import tells the delegate, as OSC 11/12 do.
    @MainActor @Test func aViewBackedReplicaDrawsTheOwnersColoursAfterAResync() async throws {
        let view = TerminalView(frame: .zero, font: nil, options: TerminalOptions(cols: 30, rows: 8, scrollback: 50))
        await drainMainQueue()
        view.feed(text: "\u{1b}]12;#ff0000\u{07}\u{1b}]11;#00ff00\u{07}")
        await drainMainQueue()
        let owner = Self.make()
        owner.feed(text: "\u{1b}]12;#123456\u{07}\u{1b}]11;#654321\u{07}")
        let snapshot = try TerminalStateSnapshot(encoded: try #require(owner.exportState()).encoded())
        view.withLockedTerminal { terminal in
            terminal.respondsToQueries = false
            terminal.importState(snapshot)
        }
        await drainMainQueue()
        await drainMainQueue()
        #expect(view.caretView.caretColor == TTColor.make(color: Color(red: 0x1212, green: 0x3434, blue: 0x5656)))
        #expect(view.nativeBackgroundColor == TTColor.make(color: Color(red: 0x6565, green: 0x4343, blue: 0x2121)))
        view.frameDriver.shutdown()
    }
    #endif
}
#endif
