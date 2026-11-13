#if !os(iOS) && !os(Windows)
import Testing
@_spi(Replication) @testable import SwiftTerm

/// IT-2001 D4: the parser's sequence-boundary hook. A terminal fed a stream
/// in any batches up to a cut reports ``Terminal/pendingParserBytes``; a fresh
/// parser fed exactly those bytes must reach the same parse state, and after
/// the rest of the stream both must be in the same state again and have sent
/// the same bytes. This compares parser fields only, so it does not depend on
/// the rest of the snapshot (the whole-digest corpus in
/// TerminalStateSnapshotTests runs the same streams end to end).
///
/// The contract, one stream per clause: the hook sees every transition once,
/// with the batch index of its first byte; bytes handled before the tail
/// (printable runs, CSI digits, OSC/APC continuation bytes at a batch start)
/// belong to the open sequence by position; a C0 executed inside a sequence
/// is skipped, never replayed; a parser reset during the parse clears the
/// record; a transition that consumes zero bytes records nothing.
final class ParserBoundaryTests {
    private final class Capture: TerminalDelegate {
        var sent: [UInt8] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    }

    private static func make(_ capture: Capture) -> Terminal {
        let terminal = Terminal(delegate: capture, options: TerminalOptions(cols: 30, rows: 8, scrollback: 50))
        terminal.synchronizedOutputTimeout = nil
        return terminal
    }

    private static func state(_ terminal: Terminal) -> [String] {
        terminal.replicationParserState + ["pending = \(terminal.pendingParserBytes.map { "\($0)" } ?? "overflow")"]
    }

    /// Returns the first failure, or nil. `splits` picks the batch boundaries
    /// before each cut: the prefix is fed as `[0..<k]` then `[k..<cut]`.
    static func check(_ bytes: [UInt8], splits: (Int) -> [Int]) -> String? {
        for cut in 0...bytes.count {
            for k in Set(splits(cut)) where k >= 0 && k <= cut {
                let ownerCapture = Capture()
                let owner = make(ownerCapture)
                if k > 0 { owner.feed(byteArray: Array(bytes[0..<k])) }
                if cut > k { owner.feed(byteArray: Array(bytes[k..<cut])) }
                guard let pending = owner.pendingParserBytes else {
                    return "cut \(cut) split \(k): pendingParserBytes overflowed"
                }
                let freshCapture = Capture()
                let fresh = make(freshCapture)
                if !pending.isEmpty { fresh.feed(byteArray: pending) }
                let where_ = "cut \(cut) split \(k) pending \(pending)"
                if state(owner) != state(fresh) {
                    return "\(where_): at the cut\n  owner \(state(owner))\n  fresh \(state(fresh))"
                }
                ownerCapture.sent = []
                freshCapture.sent = []
                if cut < bytes.count {
                    owner.feed(byteArray: Array(bytes[cut...]))
                    fresh.feed(byteArray: Array(bytes[cut...]))
                }
                if state(owner) != state(fresh) {
                    return "\(where_): after the tail\n  owner \(state(owner))\n  fresh \(state(fresh))"
                }
                if ownerCapture.sent != freshCapture.sent {
                    return "\(where_): the tail sent \(ownerCapture.sent) vs \(freshCapture.sent)"
                }
            }
        }
        return nil
    }

    private static func u(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// One stream per contract clause. Each is cut at every byte, with every
    /// split of the prefix into two batches.
    static let clauses: [(String, [UInt8])] = [
        ("whole CSI sequences, consumed > 1",
         u("a\u{1b}[1;31mred\u{1b}[0m\u{1b}[2;5Hx\u{1b}[K\u{1b}[?25l\u{1b}[?25h")),
        ("CSI digits split across feeds",
         u("\u{1b}[12;34Hy\u{1b}[38;5;123mz\u{1b}[48:2::10:20:30mw")),
        // U+20AC and U+0100 have continuation bytes 0x82 and 0x80, which the
        // table alone would take for C1 controls.
        ("OSC continuation bytes at a batch start",
         u("\u{1b}]2;€Ā€\u{07}t\u{1b}]2;Ā€\u{1b}\\")),
        ("APC continuation bytes at a batch start",
         u("\u{1b}_X€Ā€\u{1b}\\a\u{1b}_YĀ€\u{1b}\\b")),
        ("C0 inside CSI", u("\u{1b}[3\r1mA\u{1b}[2\n;4HB\u{1b}[\u{08}5CC")),
        ("C0 inside OSC", u("\u{1b}]2;ab\u{08}cd\u{07}\u{1b}]2;e\u{0e}f\u{1b}\\g")),
        ("RIS mid-sequence", u("x\u{1b}[3;\u{1b}c\u{1b}[5mA\u{1b}]2;t\u{1b}cB\u{1b}[1")),
        ("OSC 7501, well-formed ST", u("a\u{1b}]7501;state=working\u{1b}\\b\u{1b}]7501;state=done:id=r\u{1b}\\c")),
        ("OSC 7501, malformed terminator (zero-byte transition)",
         u("a\u{1b}]7501;state=working\u{1b}7b\u{1b}]7501;state=x\u{1b}[1mc\u{1b}]7501;s\u{1b}\u{1b}\\d")),
    ]

    @Test(arguments: clauses.map(\.0))
    func aFreshParserFedThePendingBytesReachesTheSameState(_ name: String) {
        let bytes = Self.clauses.first { $0.0 == name }!.1
        let failure = Self.check(bytes) { cut in Array(0...cut) }
        #expect(failure == nil, "\(name): \(failure ?? "")")
    }

    /// The every-byte corpus (TerminalStateSnapshotTests), resizes left out:
    /// they do not touch the parser. Cut at every byte, prefix in one batch
    /// and in two halves.
    @Test(arguments: TerminalStateSnapshotTests.corpus.map(\.0))
    func theCorpusParsesTheSame(_ name: String) {
        let steps = TerminalStateSnapshotTests.corpus.first { $0.0 == name }!.1
        let bytes = steps.flatMap { step -> [UInt8] in
            if case .bytes(let b) = step { return b }
            return []
        }
        let failure = Self.check(bytes) { cut in [0, cut / 2] }
        #expect(failure == nil, "\(name): \(failure ?? "")")
    }
}
#endif
