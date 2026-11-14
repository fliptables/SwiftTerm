#if !os(iOS) && !os(Windows)
import Foundation
import Testing
@_spi(Replication) @testable import SwiftTerm

/// IT-2001 D4 (lead 14, the export's refusal; ruling (B), export only at
/// ground): while ``Terminal/hasPendingSequence`` is true a snapshot would tell
/// a replica the parser is in ground while the owner is mid-sequence. Both
/// export entry points then return nil ("wait"), from one guard, and change
/// nothing; the next feed that returns the parser to ground ends the wait. An
/// over-large open sequence is one more wait (before this PR it exported an
/// empty pending field: a defect).
final class ExportRefusalTests {
    private final class Capture: TerminalDelegate {
        var sent: [UInt8] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    }

    private static func make(responds: Bool = true) -> Terminal {
        let terminal = Terminal(delegate: Capture(), options: TerminalOptions(cols: 30, rows: 8, scrollback: 50))
        terminal.respondsToQueries = responds
        terminal.synchronizedOutputTimeout = nil
        return terminal
    }

    /// An OSC 52 body of 300 KiB, still open.
    private static let overLarge: [UInt8] = Array("x\u{1b}]52;c;".utf8)
        + [UInt8](repeating: 0x41, count: 300 * 1024)

    // MARK: the over-large open sequence (a defect before this PR: exported empty)

    @Test func anOverLargeOpenSequenceIsNotExported() {
        let owner = Self.make()
        owner.feed(byteArray: Self.overLarge)
        #expect(owner.hasPendingSequence)
        #expect(owner.exportState() == nil, "exportState must wait while a sequence is open")
        #expect(owner.exportForStreaming() == nil, "exportForStreaming must wait while a sequence is open")
    }

    @Test func theSequenceEndingEndsTheWait() throws {
        let owner = Self.make()
        owner.feed(byteArray: Self.overLarge)
        owner.feed(byteArray: [0x07] + Array("after".utf8))
        let snapshot = try #require(owner.exportState())
        #expect(snapshot.pendingParserBytes == [])
        let replica = Self.make(responds: false)
        replica.importState(try TerminalStateSnapshot(encoded: snapshot.encoded()))
        #expect(owner.replicationDigest() == replica.replicationDigest())

        let streamed = try #require(owner.exportForStreaming())
        let viewer = Self.make(responds: false)
        viewer.importState(try TerminalStateSnapshot(encoded: streamed.screen.encoded()))
        for chunk in streamed.historyChunks(linesPerChunk: 7) {
            #expect(viewer.importHistoryChunk(try TerminalHistoryChunk(encoded: chunk.encoded())))
        }
        #expect(owner.replicationDigest() == viewer.replicationDigest())
    }

    /// A refused export reads and copies nothing that it leaves changed: the
    /// digest is the same before and after, and the next feed plus export gives
    /// the snapshot of a twin that was never asked.
    @Test func aRefusedExportChangesNothing() throws {
        let owner = Self.make()
        let twin = Self.make()
        owner.feed(byteArray: Self.overLarge)
        twin.feed(byteArray: Self.overLarge)
        let before = owner.replicationDigest()
        _ = owner.exportState()
        _ = owner.exportForStreaming()
        #expect(owner.replicationDigest() == before)
        #expect(owner.replicationDigest() == twin.replicationDigest())
        let tail: [UInt8] = [0x07] + Array("\u{1b}[2;3Hdone".utf8)
        owner.feed(byteArray: tail)
        twin.feed(byteArray: tail)
        #expect(try #require(owner.exportState()) == (try #require(twin.exportState())))
    }

    // MARK: source pins

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SwiftTerm")

    private static func source(_ name: String) throws -> [String] {
        try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            .components(separatedBy: "\n")
    }

    /// The first non-blank line after `signature`'s line.
    private static func firstStatement(in file: String, after signature: String) throws -> String? {
        let lines = try source(file)
        guard let at = lines.firstIndex(where: { $0.contains(signature) }) else { return nil }
        return lines[(at + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces)
    }

    /// The `///` lines directly above `signature`'s line, joined.
    private static func docComment(in file: String, above signature: String) throws -> String {
        let lines = try source(file)
        guard let at = lines.firstIndex(where: { $0.contains(signature) }) else { return "" }
        var doc: [String] = []
        var i = at - 1
        while i >= 0, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("///") {
            doc.insert(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces), at: 0)
            i -= 1
        }
        return doc.joined(separator: " ")
    }

    @Test func theGuardIsTheFirstStatementOfTheOneExport() throws {
        #expect(try Self.firstStatement(in: "TerminalStateSnapshot.swift",
                                        after: "func exportState(skippingHistory: Bool) -> TerminalStateSnapshot? {")
                == "guard !hasPendingSequence else { return nil }")
        #expect(try Self.firstStatement(in: "TerminalStateSnapshot.swift",
                                        after: "public func exportState() -> TerminalStateSnapshot? {")
                == "exportState(skippingHistory: false)")
        #expect(try Self.firstStatement(in: "TerminalHistoryStreaming.swift",
                                        after: "public func exportForStreaming() -> TerminalStreamingExport? {")
                == "guard let screen = exportState(skippingHistory: true) else { return nil }")
    }

    /// The doc comments use the one word "wait" and say what ends it.
    @Test func theDocCommentsSayWaitAndWhatEndsIt() throws {
        let docs = [
            ("exportState", try Self.docComment(in: "TerminalStateSnapshot.swift",
                                                above: "public func exportState() -> TerminalStateSnapshot? {")),
            ("exportForStreaming", try Self.docComment(in: "TerminalHistoryStreaming.swift",
                                                       above: "public func exportForStreaming() -> TerminalStreamingExport? {")),
            ("hasPendingSequence", try Self.docComment(in: "Terminal.swift", above: "public var hasPendingSequence: Bool {")),
        ]
        for (name, doc) in docs {
            #expect(doc.contains("wait"), "\(name): \(doc)")
            #expect(doc.contains("returns the parser to ground"), "\(name) does not say what ends the wait: \(doc)")
        }
    }
}
#endif
