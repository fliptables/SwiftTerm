import Foundation
import Testing
@testable import SwiftTerm

/// IT-2001 P2: one case per reply site of the merged tree (the site table in
/// the findings record, file:line at 61892dc): the terminal that owns the
/// child sends a reply; a replica (`respondsToQueries == false`) fed the
/// same bytes sends nothing. The exact reply bytes are pinned by each
/// feature's own tests; this pins the route.
@Suite(.serialized)
struct ReplicaReplySiteTests {
    enum Host {
        case plain
        /// The delegate answers window queries, clipboard reads and the cell size.
        case answering
        /// `featureReport` set (OSC 1337 Capabilities).
        case featureReport
        /// A `termName` other than xterm.
        case termName(String)
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let site: String
        let input: String
        let host: Host
        var testDescription: String { site }
    }

    final class Recorder: TerminalDelegate, @unchecked Sendable {
        let answering: Bool
        private let lock = NSLock()
        private var _sent: [UInt8] = []
        var sent: [UInt8] { lock.withLock { _sent } }
        init(answering: Bool) { self.answering = answering }
        func send(source: Terminal, data: ArraySlice<UInt8>) { lock.withLock { _sent.append(contentsOf: data) } }
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
            answering ? Array("\u{1b}[4;100;200t".utf8) : nil
        }
        func clipboardRead(source: Terminal) -> TerminalData? {
            answering ? TerminalData(Array("clip".utf8)) : nil
        }
        func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? {
            answering ? (8, 16) : nil
        }
    }

    static let esc = "\u{1b}"
    static let st = "\u{1b}\\"

    static let cases: [Case] = [
        Case(site: "KittyClipboardProtocol:1598 send(_:to:) (write EINVAL)", input: "\(esc)]5522;type=write:loc=x\u{07}", host: .plain),
        Case(site: "KittyClipboardProtocol:1598 send(_:to:) (read ENOSYS)", input: "\(esc)]5522;type=read;Lg==\u{07}", host: .plain),
        Case(site: "ProgramStatus:121 oscProgramStatus", input: "\(esc)]7501;?\u{07}", host: .plain),
        Case(site: "Terminal:1160 reportTerminalVisibility (DSR 998)", input: "\(esc)[?998n", host: .plain),
        Case(site: "Terminal:1160 reportTerminalVisibility (DECSET 2033)", input: "\(esc)[?2033h", host: .plain),
        Case(site: "Terminal:1617 handleKittyKeyboardProtocol", input: "\(esc)[?u", host: .plain),
        Case(site: "Terminal:1798 XTGETTCAP reply", input: "\(esc)P+q524742\(st)", host: .plain),
        Case(site: "Terminal:1848 XTGETTCAP terminal name", input: "\(esc)P+q544E\(st)", host: .plain),
        Case(site: "Terminal:1902 DECRQSS (too long)", input: "\(esc)P$qabc\(st)", host: .plain),
        Case(site: "Terminal:1942 DECRQSS", input: "\(esc)P$qm\(st)", host: .plain),
        Case(site: "Terminal:4163 oscClipboard (OSC 52 read)", input: "\(esc)]52;c;?\u{07}", host: .answering),
        Case(site: "Terminal:4311 osciTerm2 Capabilities", input: "\(esc)]1337;Capabilities\u{07}", host: .featureReport),
        Case(site: "Terminal:4409 oscChangeOrQueryColorIndex", input: "\(esc)]4;1;?\u{07}", host: .plain),
        Case(site: "Terminal:4435 reportColor", input: "\(esc)]10;?\u{07}", host: .plain),
        Case(site: "Terminal:4440 reportColorScheme", input: "\(esc)[?996n", host: .plain),
        Case(site: "Terminal:5486 cmdDECRQCRA", input: "\(esc)[1;1;1;1;1;1*y", host: .plain),
        Case(site: "Terminal:5742 CSI 14 t (host answers)", input: "\(esc)[14t", host: .answering),
        Case(site: "Terminal:5745 CSI 14 t", input: "\(esc)[14t", host: .plain),
        Case(site: "Terminal:5749 CSI 14;2 t (host answers)", input: "\(esc)[14;2t", host: .answering),
        Case(site: "Terminal:5752 CSI 14;2 t", input: "\(esc)[14;2t", host: .plain),
        Case(site: "Terminal:5756 CSI 15 t (host answers)", input: "\(esc)[15t", host: .answering),
        Case(site: "Terminal:5759 CSI 15 t", input: "\(esc)[15t", host: .plain),
        Case(site: "Terminal:5765 CSI 16 t (host answers)", input: "\(esc)[16t", host: .answering),
        Case(site: "Terminal:5768 CSI 16 t", input: "\(esc)[16t", host: .plain),
        Case(site: "Terminal:5772 CSI 18 t (host answers)", input: "\(esc)[18t", host: .answering),
        Case(site: "Terminal:5774 CSI 18 t", input: "\(esc)[18t", host: .plain),
        Case(site: "Terminal:5778 CSI 19 t (host answers)", input: "\(esc)[19t", host: .answering),
        Case(site: "Terminal:5780 CSI 19 t", input: "\(esc)[19t", host: .plain),
        Case(site: "Terminal:5785 CSI 20 t", input: "\(esc)[20t", host: .plain),
        Case(site: "Terminal:5789 CSI 21 t", input: "\(esc)[21t", host: .plain),
        Case(site: "Terminal:5972 cmdXTVERSION", input: "\(esc)[>0q", host: .plain),
        Case(site: "Terminal:6432 cmdDecRqm (DEC mode)", input: "\(esc)[?1$p", host: .plain),
        Case(site: "Terminal:6434 cmdDecRqm (ANSI mode)", input: "\(esc)[4$p", host: .plain),
        Case(site: "Terminal:6583 DSR 5", input: "\(esc)[5n", host: .plain),
        Case(site: "Terminal:6591 DSR 6", input: "\(esc)[6n", host: .plain),
        Case(site: "Terminal:6604 DSR ?6", input: "\(esc)[?6n", host: .plain),
        Case(site: "Terminal:6607 DSR ?15", input: "\(esc)[?15n", host: .plain),
        Case(site: "Terminal:6611 DSR ?25", input: "\(esc)[?25n", host: .plain),
        Case(site: "Terminal:6616 DSR ?26", input: "\(esc)[?26n", host: .plain),
        Case(site: "Terminal:6625 DSR ?55", input: "\(esc)[?55n", host: .plain),
        Case(site: "Terminal:6628 DSR ?56", input: "\(esc)[?56n", host: .plain),
        Case(site: "Terminal:6631 DSR ?62", input: "\(esc)[?62n", host: .plain),
        Case(site: "Terminal:6635 DSR ?63", input: "\(esc)[?63;1n", host: .plain),
        Case(site: "Terminal:6638 DSR ?75", input: "\(esc)[?75n", host: .plain),
        Case(site: "Terminal:6641 DSR ?85", input: "\(esc)[?85n", host: .plain),
        Case(site: "Terminal:7439 DECSET 1004 enable-time focus report", input: "\(esc)[?1004h", host: .plain),
        Case(site: "Terminal:7617 DA2", input: "\(esc)[>c", host: .plain),
        Case(site: "Terminal:7640 DA1 (xterm)", input: "\(esc)[c", host: .plain),
        Case(site: "Terminal:7640 DECID", input: "\(esc)Z", host: .plain),
        Case(site: "Terminal:7642 DA1 (screen)", input: "\(esc)[c", host: .termName("screen-256color")),
        Case(site: "Terminal:7644 DA1 (linux)", input: "\(esc)[c", host: .termName("linux")),
        Case(site: "Terminal:9175 reportInBandSizeIfAvailable", input: "\(esc)[?2048h", host: .answering),
        Case(site: "KittyGraphics:1993 sendKittyOk (query)", input: "\(esc)_Ga=q,i=1,s=1,v=1;AAAAAA==\(st)", host: .plain),
        Case(site: "KittyGraphics:2020 sendKittyError (unknown action)", input: "\(esc)_Ga=x,i=1\(st)", host: .plain),
    ]

    static func make(_ host: Host, responds: Bool) -> (Terminal, Recorder) {
        var options = TerminalOptions(cols: 30, rows: 8, scrollback: 50)
        var answering = false
        switch host {
        case .plain: break
        case .answering: answering = true
        case .featureReport: options.featureReport = "swiftterm"
        case .termName(let name): options.termName = name
        }
        let recorder = Recorder(answering: answering)
        let terminal = Terminal(delegate: recorder, options: options)
        terminal.respondsToQueries = responds
        return (terminal, recorder)
    }

    @Test(arguments: cases)
    func theOwnerAnswersAndAReplicaDoesNot(_ c: Case) {
        let (owner, ownerSent) = Self.make(c.host, responds: true)
        owner.feed(text: c.input)
        #expect(!ownerSent.sent.isEmpty, "\(c.site): the owner sent nothing (trigger wrong?)")

        let (replica, replicaSent) = Self.make(c.host, responds: false)
        replica.feed(text: c.input)
        #expect(replicaSent.sent.isEmpty,
                "\(c.site): the replica sent \(String(decoding: replicaSent.sent, as: UTF8.self).debugDescription)")
        withExtendedLifetime((ownerSent, replicaSent)) {}
    }
}
