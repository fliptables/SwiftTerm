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
