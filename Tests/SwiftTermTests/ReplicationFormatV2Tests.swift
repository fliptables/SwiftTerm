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
        try Self.refuses("tab stops short by one") { $0.normal.tabStops.removeLast() }
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
        try Self.refuses("alt rows != modes rows") { $0.alt.rows = 7 }
        // An alternate buffer never activated exports 0 lines (observed): 0 is allowed, 1..<rows is not.
        try Self.refuses("fewer lines than rows") { $0.normal.lines = Array($0.normal.lines.prefix(7)); $0.normal.yBase = 0; $0.normal.yDisp = 0 }
        try Self.refuses("a line wider than the buffer") { $0.normal.lines[0].cols = 31 }
        try Self.refuses("x past cols") { $0.normal.x = 31 }
        try Self.refuses("savedX past cols") { $0.normal.savedX = 31 }
        try Self.refuses("y at rows") { $0.normal.y = 8 }
        try Self.refuses("savedY at rows") { $0.normal.savedY = 8 }
        try Self.refuses("negative savedY") { $0.normal.savedY = -1 }
        try Self.refuses("scrollTop after scrollBottom") { $0.normal.scrollTop = 5; $0.normal.scrollBottom = 4 }
        try Self.refuses("scrollBottom at rows") { $0.normal.scrollBottom = 8 }
        try Self.refuses("marginLeft after marginRight") { $0.normal.marginLeft = 10; $0.normal.marginRight = 9 }
        try Self.refuses("marginRight at cols") { $0.normal.marginRight = 30 }
        try Self.refuses("negative marginLeft") { $0.normal.marginLeft = -1 }
        try Self.refuses("yBase past the lines") { $0.normal.yBase = $0.normal.lines.count - 7 }
        try Self.refuses("yDisp past the lines") { $0.normal.yDisp = $0.normal.lines.count - 7 }
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
            #expect(throws: Never.self, "\(name)") { _ = try TerminalStateSnapshot(encoded: snapshot.encoded()) }
            let streaming = try #require(owner.exportForStreaming(), "\(name): no streaming export")
            #expect(throws: Never.self, "\(name) (screen part)") { _ = try TerminalStateSnapshot(encoded: streaming.screen.encoded()) }
        }
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
