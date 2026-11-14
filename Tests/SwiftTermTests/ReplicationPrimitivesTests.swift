#if !os(iOS) && !os(Windows)
import Testing
@testable import SwiftTerm

/// The additions a replicating host needs: `HeadlessTerminal.onOutput`,
/// `Terminal.respondsToQueries` and `Terminal.hasPendingSequence` (with the
/// optional exports: export only at ground).
final class ReplicationPrimitivesTests {
    private final class Capture: TerminalDelegate {
        var sent: [UInt8] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    }

    private func makeTerminal(respondsToQueries: Bool = true) -> (Terminal, Capture) {
        let capture = Capture()
        let terminal = Terminal(delegate: capture, options: TerminalOptions(cols: 40, rows: 10))
        terminal.respondsToQueries = respondsToQueries
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

    // MARK: hasPendingSequence (export only at ground)

    @Test func groundStateHasNothingPending() {
        let (terminal, _) = makeTerminal()
        terminal.feed(text: "hello \u{1b}[31mworld\u{1b}[0m\r\n")
        #expect(!terminal.hasPendingSequence)
        #expect(terminal.exportState() != nil)
    }

    @Test func everyCutInsideACsiWaits() {
        let sequence = bytes("\u{1b}[38;2;10;20;30m")
        for cut in 1..<sequence.count {
            let (terminal, _) = makeTerminal()
            terminal.feed(byteArray: bytes("ab"))
            terminal.feed(byteArray: Array(sequence[..<cut]))
            #expect(terminal.hasPendingSequence, "cut \(cut)")
            #expect(terminal.exportState() == nil, "cut \(cut)")
        }
    }

    @Test func aSequenceSplitOverManyFeedsWaitsUntilItEnds() {
        let sequence = bytes("\u{1b}]2;a long window title\u{07}")
        let (terminal, _) = makeTerminal()
        for byte in sequence.dropLast() {
            terminal.feed(byteArray: [byte])
            #expect(terminal.hasPendingSequence)
        }
        terminal.feed(byteArray: [sequence.last!])
        #expect(!terminal.hasPendingSequence)
        #expect(terminal.terminalTitle == "a long window title")
        #expect(terminal.exportState() != nil)
    }

    @Test func aC0ExecutedInsideASequenceRunsAndTheSequenceStaysOpen() {
        let (terminal, _) = makeTerminal()
        terminal.feed(byteArray: bytes("\u{1b}[3\n"))
        #expect(terminal.buffer.y == 1)
        #expect(terminal.hasPendingSequence)
    }

    @Test func aStringEndedByEscapeIsDispatchedAndTheEscapeIsOpen() {
        let (terminal, _) = makeTerminal()
        terminal.feed(byteArray: bytes("\u{1b}]2;title\u{1b}"))
        #expect(terminal.terminalTitle == "title")
        #expect(terminal.hasPendingSequence)
        #expect(terminal.exportState() == nil)
    }

    @Test func aPartialUTF8CharacterIsPending() {
        let (terminal, _) = makeTerminal()
        let e = bytes("é")
        terminal.feed(byteArray: [e[0]])
        #expect(terminal.hasPendingSequence)
        #expect(terminal.exportState() == nil)
        terminal.feed(byteArray: [e[1]])
        #expect(!terminal.hasPendingSequence)
    }

    /// An open string of any size is one more wait; there is no bound.
    @Test func anOversizedOpenStringWaitsLikeAnyOther() {
        let (terminal, _) = makeTerminal()
        let payload = [UInt8](repeating: 0x41, count: 300 * 1024)
        terminal.feed(byteArray: bytes("\u{1b}]52;c;") + payload)
        #expect(terminal.hasPendingSequence)
        #expect(terminal.exportState() == nil)
        terminal.feed(byteArray: [0x07])
        #expect(!terminal.hasPendingSequence)
        #expect(terminal.exportState() != nil)
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
        // Upstream's valve (Void): active before the call, not after; a second
        // call changes nothing. It is not the timer, so `fired` stays 0.
        #expect(terminal.synchronizedOutputActive)
        terminal.expireSynchronizedOutput()
        #expect(!terminal.synchronizedOutputActive)
        terminal.expireSynchronizedOutput()
        #expect(!terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputWatchdogCounters.fired == 0)
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
