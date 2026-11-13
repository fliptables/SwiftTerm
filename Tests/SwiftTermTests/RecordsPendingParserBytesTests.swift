#if !os(iOS) && !os(Windows)
import Foundation
import Testing
@_spi(Replication) @testable import SwiftTerm

/// IT-2001 D4, lead 14's opt-in record (21:05Z): `Terminal.recordsPendingParserBytes`,
/// default false, stored on the parser and read once per parse call.
/// - At ground, pendingParserBytes is [] (plus putback) with the flag on or off.
/// - Inside a sequence the record does not cover it is nil ("wait"): the flag off at the
///   read; the flag turned on while the sequence is open (until a ground or a new
///   sequence start). Turning it off empties the bytes.
/// - hasPendingSequence does not depend on the flag.
/// Pins P-a..P-f. No wall clock.
final class RecordsPendingParserBytesTests {
    private final class Capture: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private static func make(records: Bool) -> Terminal {
        let terminal = Terminal(delegate: Capture(), options: TerminalOptions(cols: 30, rows: 8, scrollback: 50))
        terminal.synchronizedOutputTimeout = nil
        if records { terminal.recordsPendingParserBytes = true }
        return terminal
    }

    private static func parserInGround(_ terminal: Terminal) -> Bool {
        terminal.replicationParserState.first == "state = ground"
    }

    private static func u(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// The streams: every parser clause and the every-byte corpus, resizes left out.
    static let streams: [(String, [UInt8])] = ParserBoundaryTests.clauses
        + TerminalStateSnapshotTests.corpus.map { name, steps in
            ("corpus: \(name)", steps.flatMap { step -> [UInt8] in
                if case .bytes(let b) = step { return b }
                return []
            })
        }

    // MARK: P-f

    @Test func theFlagIsOffByDefault() {
        #expect(Terminal(delegate: Capture()).recordsPendingParserBytes == false)
        #expect(Terminal(delegate: Capture(), options: TerminalOptions(cols: 30, rows: 8)).recordsPendingParserBytes == false)
    }

    // MARK: P-a, P-b over every stream: flag off, cut at every byte

    /// At a cut where the parser is in ground: the same pending bytes (putback) and the
    /// same snapshot as an always-on twin, and the snapshot round-trips. Inside a
    /// sequence: nil, both exports nil. hasPendingSequence equal to the twin's at every cut.
    @Test(arguments: streams.map(\.0))
    func flagOffGroundExportsAndOpenWaits(_ name: String) throws {
        let bytes = Self.streams.first { $0.0 == name }!.1
        let off = Self.make(records: false)
        let on = Self.make(records: true)
        var groundCuts = 0, openCuts = 0
        for cut in 0...bytes.count {
            if cut > 0 {
                off.feed(byteArray: [bytes[cut - 1]])
                on.feed(byteArray: [bytes[cut - 1]])
            }
            #expect(off.hasPendingSequence == on.hasPendingSequence, "\(name) cut \(cut): hasPendingSequence depends on the flag")
            if Self.parserInGround(on) {
                groundCuts += 1
                #expect(off.pendingParserBytes == on.pendingParserBytes, "\(name) cut \(cut)")
                let snapshot = try #require(off.exportState(), "\(name) cut \(cut): a ground export refused")
                #expect(snapshot == (try #require(on.exportState())), "\(name) cut \(cut)")
                #expect(try TerminalStateSnapshot(encoded: snapshot.encoded()) == snapshot, "\(name) cut \(cut)")
                #expect(off.exportForStreaming() != nil, "\(name) cut \(cut)")
            } else {
                openCuts += 1
                #expect(off.pendingParserBytes == nil, "\(name) cut \(cut): open sequence, flag off, \(off.replicationParserState.first ?? "")")
                #expect(off.exportState() == nil, "\(name) cut \(cut)")
                #expect(off.exportForStreaming() == nil, "\(name) cut \(cut)")
            }
        }
        #expect(groundCuts > 0)
    }

    /// P-b, one stream per kind of open sequence, the state checked so each kind is hit.
    static let kinds: [(String, String, String)] = [
        ("ESC", "a\u{1b}", "state = escape"),
        ("CSI", "a\u{1b}[1;3", "state = csiParam"),
        ("OSC", "a\u{1b}]2;tit", "state = oscString"),
        ("DCS", "a\u{1b}P$qm", "state = dcsPassthrough"),
        ("APC", "a\u{1b}_Gx=1", "state = apcString"),
        ("OSC 7501 status ESC", "a\u{1b}]7501;state=working\u{1b}", "state = programStatusEscape"),
    ]

    @Test(arguments: kinds.map(\.0))
    func flagOffInsideEachKindWaits(_ kind: String) {
        let (_, text, state) = Self.kinds.first { $0.0 == kind }!
        let terminal = Self.make(records: false)
        terminal.feed(byteArray: Self.u(text))
        #expect(terminal.replicationParserState.first == state)
        #expect(terminal.hasPendingSequence)
        #expect(terminal.pendingParserBytes == nil)
        #expect(terminal.exportState() == nil)
        #expect(terminal.exportForStreaming() == nil)
    }

    // MARK: P-c: the flag turned on at every byte index

    /// Each clause stream. Turned on at index j: nil until the first cut at or after j where the parser is in
    /// ground or a sequence has started after j; from then on equal to an always-on twin.
    @Test(arguments: ParserBoundaryTests.clauses.map(\.0))
    func flagTurnedOnAtEveryByteIndex(_ name: String) throws {
        let bytes = ParserBoundaryTests.clauses.first { $0.0 == name }!.1
        // The twin's record per cut, computed once.
        let twin = Self.make(records: true)
        var twinPending: [[UInt8]?] = [twin.pendingParserBytes]
        var twinRecord: [[UInt8]] = [twin.parserRecordForTesting]
        var twinGround: [Bool] = [Self.parserInGround(twin)]
        var twinSnapshots: [TerminalStateSnapshot?] = [twin.exportState()]
        for b in bytes {
            twin.feed(byteArray: [b])
            twinPending.append(twin.pendingParserBytes)
            twinRecord.append(twin.parserRecordForTesting)
            twinGround.append(Self.parserInGround(twin))
            twinSnapshots.append(twin.exportState())
        }
        // Single-byte batches: a sequence that started at byte k-1 is recorded as exactly that byte.
        func restarts(at k: Int) -> Bool { twinGround[k] || (k > 0 && twinRecord[k] == [bytes[k - 1]]) }
        var failures = 0
        for j in 0...bytes.count where failures < 5 {
            let subject = Self.make(records: false)
            if j > 0 { for b in bytes[..<j] { subject.feed(byteArray: [b]) } }
            subject.recordsPendingParserBytes = true
            var covered = false
            for cut in j...bytes.count where failures < 5 {
                if cut > j { subject.feed(byteArray: [bytes[cut - 1]]) }
                if !covered && (twinGround[cut] || (cut > j && restarts(at: cut))) { covered = true }
                let expected: [UInt8]? = covered ? twinPending[cut] : nil
                if subject.pendingParserBytes != expected {
                    failures += 1
                    Issue.record("\(name) on at \(j) cut \(cut): pending \(String(describing: subject.pendingParserBytes)) expected \(String(describing: expected))")
                }
                if covered, subject.exportState() != twinSnapshots[cut] {
                    failures += 1
                    Issue.record("\(name) on at \(j) cut \(cut): snapshot differs from the always-on twin's")
                }
                if !covered, subject.exportState() != nil {
                    failures += 1
                    Issue.record("\(name) on at \(j) cut \(cut): exported while the record does not cover the open sequence")
                }
            }
        }
    }

    // MARK: P-d: on -> off mid-sequence

    @Test func turningTheFlagOffEmptiesTheBytesAndWaitsWhileOpen() {
        let terminal = Self.make(records: true)
        terminal.feed(byteArray: Self.u("a\u{1b}]2;title"))
        #expect(terminal.pendingParserBytes == Self.u("\u{1b}]2;title"))
        terminal.recordsPendingParserBytes = false
        #expect(terminal.parserRecordForTesting == [], "turning the flag off must empty the recorded bytes")
        #expect(terminal.pendingParserBytes == nil)
        #expect(terminal.hasPendingSequence)
        terminal.feed(byteArray: Self.u("more"))
        #expect(terminal.pendingParserBytes == nil)
        #expect(terminal.parserRecordForTesting == [])
        terminal.feed(byteArray: [0x07])
        #expect(terminal.pendingParserBytes == [])
        #expect(terminal.exportState() != nil)
    }

    @Test(arguments: streams.map(\.0))
    func turningTheFlagOffAtEveryCutEmptiesTheBytes(_ name: String) {
        let bytes = Self.streams.first { $0.0 == name }!.1
        for cut in 0...bytes.count {
            let terminal = Self.make(records: true)
            for b in bytes[..<cut] { terminal.feed(byteArray: [b]) }
            terminal.recordsPendingParserBytes = false
            #expect(terminal.parserRecordForTesting == [], "\(name) cut \(cut)")
            if Self.parserInGround(terminal) {
                #expect(terminal.pendingParserBytes != nil, "\(name) cut \(cut)")
            } else {
                #expect(terminal.pendingParserBytes == nil, "\(name) cut \(cut)")
            }
        }
    }

    // MARK: P-f: source pins

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SwiftTerm")

    /// The parse loop reads the flag once, into a local, and nowhere else.
    @Test func theParseCallReadsTheFlagOnce() throws {
        let text = try String(contentsOf: Self.sources.appendingPathComponent("EscapeSequenceParser.swift"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.contains("func parseBorrowed(_ data: Span<UInt8>, _ terminal: Terminal)") })
        let end = try #require(lines[(start + 1)...].firstIndex { $0.hasPrefix("    }") })
        let reads = lines[start...end].enumerated().filter { $0.element.contains("recordsPendingBytes") }
        #expect(reads.count == 1, "parseBorrowed reads recordsPendingBytes \(reads.count) times: \(reads.map(\.element))")
        #expect(reads.first?.element.trimmingCharacters(in: .whitespaces) == "let records = recordsPendingBytes")
    }

    @Test func theDocCommentStatesTheContract() throws {
        let lines = try String(contentsOf: Self.sources.appendingPathComponent("Terminal.swift"), encoding: .utf8)
            .components(separatedBy: "\n")
        let at = try #require(lines.firstIndex { $0.contains("public var recordsPendingParserBytes: Bool {") })
        var doc: [String] = []
        var i = at - 1
        while i >= 0, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("///") {
            doc.insert(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(3)), at: 0)
            i -= 1
        }
        let text = doc.joined(separator: " ")
        for phrase in ["Default `false`", "wait", "returns the parser to ground", "terminalLock", "empties"] {
            #expect(text.contains(phrase), "recordsPendingParserBytes' doc lacks \"\(phrase)\": \(text)")
        }
    }
}
#endif
