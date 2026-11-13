#if !os(iOS) && !os(Windows)
import Testing
@testable import SwiftTerm

/// The four additions a replicating host needs: `HeadlessTerminal.onOutput`,
/// `Terminal.respondsToQueries`, `Terminal.hasPendingSequence` and
/// `Terminal.pendingParserBytes`.
final class ReplicationPrimitivesTests {
    private final class Capture: TerminalDelegate {
        var sent: [UInt8] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    }

    private func makeTerminal(respondsToQueries: Bool = true) -> (Terminal, Capture) {
        let capture = Capture()
        let terminal = Terminal(delegate: capture, options: TerminalOptions(cols: 40, rows: 10))
        terminal.respondsToQueries = respondsToQueries
        terminal.recordsPendingParserBytes = true
        return (terminal, capture)
    }

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: respondsToQueries

    static let queries: [String] = [
        "\u{1b}[c",              // DA1
        "\u{1b}[>c",             // DA2
        "\u{1b}[5n",             // DSR status
        "\u{1b}[6n",             // DSR cursor position
        "\u{1b}[>q",             // XTVERSION
        "\u{1b}[?2004$p",        // DECRQM
        "\u{1b}]10;?\u{07}",     // foreground colour query
        "\u{1b}]4;1;?\u{07}",    // palette query
        "\u{1b}[?u",             // Kitty keyboard flags query
        "\u{1b}[18t",            // text area size report
        "\u{1b}P$qm\u{1b}\\",    // DECRQSS
        "\u{1b}[?1004h",         // focus reporting on: reports the current focus
    ]

    @Test(arguments: queries)
    func aTerminalThatRespondsAnswersEachQuery(_ query: String) {
        let (terminal, capture) = makeTerminal()
        terminal.feed(text: query)
        #expect(!capture.sent.isEmpty)
    }

    @Test(arguments: queries)
    func aPassiveReplicaAnswersNoQuery(_ query: String) {
        let (terminal, capture) = makeTerminal(respondsToQueries: false)
        terminal.feed(text: query)
        #expect(capture.sent.isEmpty)
    }

    @Test func aPassiveReplicaSendsNoUnsolicitedSizeReport() {
        let (terminal, capture) = makeTerminal(respondsToQueries: false)
        terminal.feed(text: "\u{1b}[?2048h")
        terminal.resize(cols: 50, rows: 12)
        #expect(capture.sent.isEmpty)
    }

    @Test func aPassiveReplicaStillSendsUserInputAndMouseReports() {
        let (terminal, capture) = makeTerminal(respondsToQueries: false)
        terminal.sendUserInput(bytes("ls\r")[...])
        #expect(capture.sent == bytes("ls\r"))
        capture.sent = []
        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        terminal.sendEvent(buttonFlags: 0, x: 2, y: 3)
        #expect(capture.sent == bytes("\u{1b}[<0;3;4M"))
    }

    // MARK: hasPendingSequence / pendingParserBytes

    @Test func groundStateHasNothingPending() {
        let (terminal, _) = makeTerminal()
        terminal.feed(text: "hello \u{1b}[31mworld\u{1b}[0m\r\n")
        #expect(!terminal.hasPendingSequence)
        #expect(terminal.pendingParserBytes == [])
    }

    @Test func everyCutInsideACsiKeepsTheBytesVerbatim() {
        let sequence = bytes("\u{1b}[38;2;10;20;30m")
        for cut in 1..<sequence.count {
            let (terminal, _) = makeTerminal()
            terminal.feed(byteArray: bytes("ab"))
            terminal.feed(byteArray: Array(sequence[..<cut]))
            #expect(terminal.hasPendingSequence)
            #expect(terminal.pendingParserBytes == Array(sequence[..<cut]))
        }
    }

    @Test func aSequenceSplitOverManyFeedsAccumulates() {
        let sequence = bytes("\u{1b}]2;a long window title\u{07}")
        let (terminal, _) = makeTerminal()
        for byte in sequence.dropLast() {
            terminal.feed(byteArray: [byte])
        }
        #expect(terminal.pendingParserBytes == Array(sequence.dropLast()))
        terminal.feed(byteArray: [sequence.last!])
        #expect(!terminal.hasPendingSequence)
        #expect(terminal.terminalTitle == "a long window title")
    }

    @Test func aC0ExecutedInsideASequenceIsLeftOut() {
        let (terminal, _) = makeTerminal()
        terminal.feed(byteArray: bytes("\u{1b}[3\n"))
        #expect(terminal.buffer.y == 1)
        #expect(terminal.pendingParserBytes == bytes("\u{1b}[3"))
    }

    @Test func aNewEscapeAbandonsTheOpenSequence() {
        let (terminal, _) = makeTerminal()
        terminal.feed(byteArray: bytes("\u{1b}[12;"))
        terminal.feed(byteArray: bytes("\u{1b}[4"))
        #expect(terminal.pendingParserBytes == bytes("\u{1b}[4"))
    }

    @Test func aStringEndedByEscapeKeepsOnlyTheEscape() {
        let (terminal, _) = makeTerminal()
        terminal.feed(byteArray: bytes("\u{1b}]2;title\u{1b}"))
        #expect(terminal.terminalTitle == "title")
        #expect(terminal.pendingParserBytes == [0x1b])
    }

    @Test func aPartialUTF8CharacterIsPending() {
        let (terminal, _) = makeTerminal()
        let e = bytes("é")
        terminal.feed(byteArray: [e[0]])
        #expect(terminal.hasPendingSequence)
        #expect(terminal.pendingParserBytes == [e[0]])
        terminal.feed(byteArray: [e[1]])
        #expect(!terminal.hasPendingSequence)
    }

    @Test func anOversizedOpenStringReportsNil() {
        let (terminal, _) = makeTerminal()
        let payload = [UInt8](repeating: 0x41, count: EscapeSequenceParser.maximumPendingSequenceBytes + 10)
        terminal.feed(byteArray: bytes("\u{1b}]52;c;") + payload)
        #expect(terminal.hasPendingSequence)
        #expect(terminal.pendingParserBytes == nil)
        terminal.feed(byteArray: [0x07])
        #expect(!terminal.hasPendingSequence)
        #expect(terminal.pendingParserBytes == [])
    }

    /// The property a snapshot relies on: a second parser fed the pending
    /// bytes and then the rest of the stream ends in the same state as the
    /// parser that read the whole stream, at every cut point.
    @Test func replayingThePendingBytesResumesTheSameParse() {
        let stream = bytes("x\u{1b}[1;31mR\u{1b}]2;tït\u{1b}\\\u{1b}P$qm\u{1b}\\é\u{1b}[?25l\u{1b}[5;7Hz")
        var stCuts = 0
        defer { #expect(stCuts == 2) }
        for cut in 0...stream.count {
            let (whole, _) = makeTerminal()
            whole.feed(byteArray: Array(stream[..<cut]))
            let pending = whole.pendingParserBytes!
            whole.feed(byteArray: Array(stream[cut...]))

            // The replica starts from the whole terminal's state at the cut,
            // which here is the cut prefix minus its pending bytes.
            let (replica, capture) = makeTerminal(respondsToQueries: false)
            replica.feed(byteArray: Array(stream[..<(cut - pending.count)]))
            // A cut between the ESC and the backslash of an ST: the whole
            // terminal already dispatched the string at the ESC, so the
            // prefix without the pending ESC is not its state. The snapshot
            // tests cover that cut with the exported state.
            if replica.hasPendingSequence {
                stCuts += 1
                continue
            }
            replica.feed(byteArray: pending)
            replica.feed(byteArray: Array(stream[cut...]))
            #expect(capture.sent.isEmpty)
            #expect(replica.terminalTitle == whole.terminalTitle, "cut \(cut)")
            #expect(replica.buffer.x == whole.buffer.x && replica.buffer.y == whole.buffer.y, "cut \(cut)")
            #expect(replica.cursorHidden == whole.cursorHidden, "cut \(cut)")
            for col in 0..<6 {
                #expect(replica.getCharData(col: col, row: 0)?.attribute == whole.getCharData(col: col, row: 0)?.attribute, "cut \(cut) col \(col)")
                #expect(replica.getText(col: col, row: 0) == whole.getText(col: col, row: 0), "cut \(cut) col \(col)")
            }
        }
    }

    // MARK: the DEC 2026 valve under the host's control

    @Test func aNilTimeoutNeverArmsTheValve() {
        let (terminal, _) = makeTerminal()
        terminal.synchronizedOutputTimeout = nil
        terminal.feed(text: "\u{1b}[?2026h")
        #expect(terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 0)
        #expect(terminal.synchronizedOutputTimeout == nil)
    }

    @Test func theDefaultTimeoutIsUnchanged() {
        let (terminal, _) = makeTerminal()
        #expect(terminal.synchronizedOutputTimeout == 1.0)
        terminal.feed(text: "\u{1b}[?2026h")
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 1)
        terminal.feed(text: "\u{1b}[?2026l")
    }

    @Test func expiringTheValveEndsTheModeOnceAndOnlyOnce() {
        let (terminal, _) = makeTerminal()
        terminal.synchronizedOutputTimeout = nil
        terminal.feed(text: "\u{1b}[?2026h")
        #expect(terminal.expireSynchronizedOutput())
        #expect(!terminal.synchronizedOutputActive)
        #expect(!terminal.expireSynchronizedOutput())
        #expect(terminal.synchronizedOutputWatchdogCounters.fired == 1)
    }

    @Test func settingNilCancelsAnArmedValve() {
        let (terminal, _) = makeTerminal()
        terminal.feed(text: "\u{1b}[?2026h")
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 1)
        terminal.synchronizedOutputTimeout = nil
        #expect(terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputTimeout == nil)
        // IT-2001 D7: the setter cancels through the watchdog's reconcile, which counts it.
        #expect(terminal.synchronizedOutputWatchdogCounters.cancelled == 1)
        // The armed item was cancelled, so ending the mode records no cancellation of a live timer.
        terminal.feed(text: "\u{1b}[?2026l")
        #expect(terminal.synchronizedOutputWatchdogCounters.cancelled == 1)
    }

    // MARK: onOutput

    @Test func onOutputSeesEachBatchUnderTheLockAfterTheFeed() {
        let headless = HeadlessTerminal { _ in }
        var observed: [[UInt8]] = []
        var heldLock: [Bool] = []
        var cursorAtCall: [Int] = []
        headless.onOutput = { slice in
            observed.append(Array(slice))
            heldLock.append(headless.terminal.terminalLock.isLockedByCurrentThread)
            cursorAtCall.append(headless.terminal.buffer.x)
        }
        headless.dataReceived(slice: bytes("abc")[...])
        headless.dataReceived(slice: bytes("\u{1b}[1")[...])
        #expect(observed == [bytes("abc"), bytes("\u{1b}[1")])
        #expect(heldLock == [true, true])
        #expect(cursorAtCall == [3, 3])
    }
}
#endif
