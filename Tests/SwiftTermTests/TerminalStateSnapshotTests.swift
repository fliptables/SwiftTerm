#if !os(iOS) && !os(Windows)
import Testing
@_spi(Replication) @testable import SwiftTerm

/// The state export and import (IT-1149): a terminal that imports another's
/// snapshot and is then fed the rest of the stream is indistinguishable from
/// the terminal that read the whole stream, at every cut.
final class TerminalStateSnapshotTests {
    private final class Capture: TerminalDelegate {
        var sent: [UInt8] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    }

    enum Step {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
    }

    private static func make(_ capture: Capture, responds: Bool) -> Terminal {
        let terminal = Terminal(delegate: capture, options: TerminalOptions(cols: 30, rows: 8, scrollback: 50))
        terminal.respondsToQueries = responds
        return terminal
    }

    private static func apply(_ step: Step, to terminal: Terminal) {
        switch step {
        case .bytes(let bytes): terminal.feed(byteArray: bytes)
        case .resize(let cols, let rows): terminal.resize(cols: cols, rows: rows)
        }
    }

    /// Splits byte steps into single bytes so every byte boundary is a cut.
    private static func explode(_ steps: [Step]) -> [Step] {
        steps.flatMap { step -> [Step] in
            if case .bytes(let bytes) = step { return bytes.map { .bytes([$0]) } }
            return [step]
        }
    }

    private static func firstDifference(_ a: [String], _ b: [String]) -> String? {
        if a == b { return nil }
        var diffs: [String] = []
        for (x, y) in zip(a, b) where x != y && diffs.count < 4 {
            diffs.append("expected \(x.prefix(400))\n     got \(y.prefix(400))")
        }
        if a.count != b.count { diffs.append("digest lengths \(a.count) vs \(b.count)") }
        return diffs.joined(separator: "\n")
    }

    /// Returns the first failing cut, or nil.
    static func replicate(_ steps: [Step]) -> String? {
        let units = explode(steps)
        var resyncs = 0
        defer { if resyncs > 0 { print("streamed resyncs: \(resyncs)") } }
        for cut in 0...units.count {
            let ownerCapture = Capture()
            let owner = make(ownerCapture, responds: true)
            for step in units[..<cut] { apply(step, to: owner) }
            let snapshot = owner.exportState()
            let encoded = snapshot.encoded()
            guard let decoded = try? TerminalStateSnapshot(encoded: encoded) else {
                return "cut \(cut): the encoded snapshot does not decode"
            }
            if decoded != snapshot { return "cut \(cut): decode(encode(s)) != s" }

            let replicaCapture = Capture()
            let replica = make(replicaCapture, responds: false)
            replica.importState(decoded)
            if let diff = firstDifference(owner.replicationDigest(), replica.replicationDigest()) {
                return "cut \(cut) at the snapshot: \(diff)"
            }
            for step in units[cut...] {
                apply(step, to: owner)
                apply(step, to: replica)
            }
            if let diff = firstDifference(owner.replicationDigest(), replica.replicationDigest()) {
                return "cut \(cut) after the tail: \(diff)"
            }
            if !replicaCapture.sent.isEmpty { return "cut \(cut): the replica answered a query" }

            // Streamed: the screen part, half the tail (stopping before a resize), the history
            // chunks nearest the screen first, then the rest.
            let freshCapture = Capture()
            let fresh = make(freshCapture, responds: true)
            for step in units[..<cut] { apply(step, to: fresh) }
            let export = fresh.exportForStreaming()
            guard let screen = try? TerminalStateSnapshot(encoded: export.screen.encoded()) else {
                return "cut \(cut): the screen part does not decode"
            }
            let streamedCapture = Capture()
            let streamed = make(streamedCapture, responds: false)
            streamed.importState(screen)
            let tail = Array(units[cut...])
            var split = tail.count / 2
            if let resize = tail.firstIndex(where: { if case .resize = $0 { return true }; return false }) {
                split = min(split, resize)
            }
            for step in tail[..<split] { apply(step, to: streamed) }
            var refused = false
            for chunk in export.historyChunks(linesPerChunk: 7) {
                guard let decoded = try? TerminalHistoryChunk(encoded: chunk.encoded()) else {
                    return "cut \(cut): a history chunk does not decode"
                }
                if !streamed.importHistoryChunk(decoded) { refused = true; break }
            }
            if refused {
                // The protocol's resync: the grid changed under the chunks, so the host
                // snapshots again where the replica now is (this point of the tail).
                guard tail[..<split].contains(where: { if case .resize = $0 { return true }; return false })
                        || fresh.normalBuffer.cols != fresh.cols || fresh.normalBuffer.rows != fresh.rows else {
                    return "cut \(cut): a chunk was refused although no grid changed"
                }
                resyncs += 1
                continue
            }
            for step in tail[split...] { apply(step, to: streamed) }
            if let diff = firstDifference(owner.replicationDigest(), streamed.replicationDigest()) {
                return "cut \(cut) streamed, after the tail: \(diff)"
            }
        }
        return nil
    }

    private static func b(_ text: String) -> Step { .bytes(Array(text.utf8)) }

    static let corpus: [(String, [Step])] = [
        ("shell lines and wraps", [
            b("$ ls -la\r\ntotal 8\r\n"),
            b(String(repeating: "wrapped-text-", count: 6) + "\r\n"),
            b("\u{1b}[1;32mgreen\u{1b}[0m \u{1b}[38;2;1;2;3;48;5;200mtrue\u{1b}[m\r\n$ "),
        ]),
        ("pending wrap at the last column", [
            b(String(repeating: "x", count: 30)),
            b("y\r\n"),
        ]),
        ("alternate screen with saved cursors", [
            b("before\r\n\u{1b}7\u{1b}[3;4H"),
            b("\u{1b}[?1049h\u{1b}[2J\u{1b}[H~\r\n~\r\n\u{1b}[8;1H\u{1b}[7m-- INSERT --\u{1b}[m\u{1b}7"),
            b("\u{1b}[2;3Hab\u{1b}8z\u{1b}[?1049l"),
            b("after"),
        ]),
        ("scroll region, origin and margins", [
            b("\u{1b}[2;6r\u{1b}[?6h\u{1b}[Hin\r\nregion\r\n\r\n\r\n\r\n\r\nscrolled"),
            b("\u{1b}[?69h\u{1b}[3;10s\u{1b}[?6lab\u{1b}[r\u{1b}[?69l"),
        ]),
        ("modes, tabs, charsets, insert", [
            b("\u{1b}[?1h\u{1b}=\u{1b}[?2004h\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?25l\u{1b}[4h"),
            b("\u{1b}[3g\u{1b}[5G\u{1b}H\u{1b}[12G\u{1b}H\r\ta\tb\u{1b}[4l"),
            b("\u{1b}(0lqk\u{1b}(B \u{1b})0\u{0e}x\u{0f}\u{1b}[5 q\u{1b}[?12h"),
            b("\u{1b}[?1004h\u{1b}[?2026h"),
        ]),
        ("wide, combining, emoji and hyperlinks", [
            b("日本語 é e\u{301} 👍🏽 🇫🇷\r\n"),
            b("\u{1b}]8;id=1;https://example.invalid/a\u{1b}\\link\u{1b}]8;;\u{1b}\\ plain\r\n"),
            b("\u{1b}]8;;https://example.invalid/open\u{07}still"),
        ]),
        ("titles, stacks and directories", [
            b("\u{1b}]0;one\u{07}\u{1b}[22;0t\u{1b}]2;two\u{07}\u{1b}]1;icon\u{07}\u{1b}[22t"),
            b("\u{1b}]7;file://host/tmp/dir\u{07}\u{1b}]4;1;rgb:12/34/56\u{07}"),
        ]),
        ("kitty keyboard stacks per screen", [
            b("\u{1b}[>1u\u{1b}[>3u\u{1b}[=5;1u"),
            b("\u{1b}[?1049h\u{1b}[>8u\u{1b}[<u\u{1b}[>2u"),
        ]),
        ("semantic prompts", [
            b("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}echo hi\u{1b}]133;C\u{07}\r\nhi\r\n\u{1b}]133;D;0\u{07}"),
            b("\u{1b}]133;A;cl=m\u{07}> \u{1b}]133;B\u{07}"),
        ]),
        ("resize mid-stream", [
            b(String(repeating: "abcdefghij", count: 7) + "\r\nshort\r\n"),
            .resize(cols: 20, rows: 6),
            b("after narrow " + String(repeating: "z", count: 25)),
            b("\u{1b}[?1049h\u{1b}[Hfull"),
            .resize(cols: 40, rows: 10),
            b("\u{1b}[?1049lback"),
        ]),
        ("scrollback overflow", [
            b((0..<80).map { "line \($0)\r\n" }.joined()),
        ]),
        ("queries answered only by the owner", [
            b("\u{1b}[c\u{1b}[6n\u{1b}[>q\u{1b}]10;?\u{07}\u{1b}[?u\u{1b}P$qm\u{1b}\\"),
        ]),
    ]

    @Test(arguments: corpus.map(\.0))
    func everyCutReplicates(_ name: String) {
        let steps = Self.corpus.first { $0.0 == name }!.1
        let failure = Self.replicate(steps)
        #expect(failure == nil, "\(name): \(failure ?? "")")
    }

    /// Found by T3 on a recorded `less` session: a terminal made at 24 rows has an
    /// alternate buffer that holds 25 lines (it was built at the default 25), and its
    /// capacity decides when output starts trimming.
    @Test func aBufferHoldingMoreLinesThanItsRowsRoundTrips() throws {
        let capture = Capture()
        let owner = Terminal(delegate: capture, options: TerminalOptions(cols: 80, rows: 24, scrollback: 500))
        owner.feed(text: "\u{1b}[?1049h\u{1b}[24;1Hx")
        let replica = Terminal(delegate: Capture(), options: TerminalOptions(cols: 80, rows: 24, scrollback: 500))
        replica.respondsToQueries = false
        replica.importState(try TerminalStateSnapshot(encoded: owner.exportState().encoded()))
        #expect(owner.replicationDigest() == replica.replicationDigest())
        let tail = (0..<40).map { "\u{1b}[24;1H\r\nline \($0)" }.joined()
        owner.feed(text: tail)
        replica.feed(text: tail)
        #expect(owner.replicationDigest() == replica.replicationDigest())
    }

    @Test func everyExclusionNamesARealProperty() {
        let terminal = Terminal(delegate: Capture())
        let terminalLabels = Set(Mirror(reflecting: terminal).children.compactMap(\.label))
        let bufferLabels = Set(Mirror(reflecting: terminal.buffer).children.compactMap(\.label))
        let lineLabels = Set(Mirror(reflecting: terminal.buffer.lines[0]).children.compactMap(\.label))
        #expect(Set(Terminal.digestExcludedTerminalProperties.keys).subtracting(terminalLabels).isEmpty)
        #expect(Set(Terminal.digestExcludedBufferProperties.keys).subtracting(bufferLabels).isEmpty)
        #expect(Set(Terminal.digestExcludedLineProperties.keys).subtracting(lineLabels).isEmpty)
    }

    @Test func aDifferentFormatVersionIsRefused() {
        let terminal = Terminal(delegate: Capture())
        var encoded = terminal.exportState().encoded()
        encoded[4] &+= 1
        #expect(throws: TerminalStateSnapshotError.self) { try TerminalStateSnapshot(encoded: encoded) }
        #expect(throws: TerminalStateSnapshotError.self) { try TerminalStateSnapshot(encoded: Array(encoded.prefix(10))) }
    }
}
#endif
