import Foundation
import Testing
@testable import SwiftTerm

/// IT-2001 D8, proof P2: a replica answers nothing, and still sends what the
/// user does. Two sinks write bytes toward the child: the reply sink
/// (`sendQueryResponse`, gated by `respondsToQueries`) and the user-input
/// transport (`sendUserInputBytes`, not gated). Input REGISTRATION (the OSC
/// 133 submission scanner) is a separate call and stays where it was.
@Suite(.serialized)
final class ReplicaSinkTests {
    final class Recorder: TerminalDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [[UInt8]] = []
        private var _pasteEvents: [[UInt8]] = []
        var sent: [[UInt8]] { lock.withLock { _sent } }
        var pasteEvents: [[UInt8]] { lock.withLock { _pasteEvents } }
        func send(source: Terminal, data: ArraySlice<UInt8>) { lock.withLock { _sent.append(Array(data)) } }
        func kittyClipboardCapabilities(source: Terminal) -> KittyClipboardCapabilities { .standard }
        func kittyClipboardSendPasteEvent(source: Terminal, data: ArraySlice<UInt8>) -> Bool {
            lock.withLock { _pasteEvents.append(Array(data)) }
            return true
        }
    }

    /// Counts input registrations (a test-only override; no production seam).
    final class CountingTerminal: Terminal {
        var registrations = 0
        override func registerUserInput(_ data: ArraySlice<UInt8>) {
            registrations += 1
            super.registerUserInput(data)
        }
    }

    private static func make(responds: Bool) -> (CountingTerminal, Recorder) {
        let recorder = Recorder()
        let terminal = CountingTerminal(
            delegate: recorder,
            options: TerminalOptions(cols: 20, rows: 4, scrollback: 10, kittyClipboardPolicy: .all))
        terminal.respondsToQueries = responds
        // As a host does when it installs its clipboard service: a later first
        // refresh that changes the capability set resets mode 5522.
        terminal.refreshKittyClipboardCapabilities()
        return (terminal, recorder)
    }

    private static func snapshot() -> TerminalClipboardSnapshot {
        TerminalClipboardSnapshot(location: .standard, mimeTypes: ["text/plain"], identity: 1, expiresAfter: nil) { _, completion in
            completion(.unavailable)
            return true
        }
    }

    /// A prompt with click events and input armed (OSC 133 A/B).
    private static let armedPrompt = "\u{1b}]133;A;click_events=1\u{07}>\u{1b}]133;B\u{07}hi"

    // MARK: user input is sent by a replica

    @Test func aReplicaSendsAMousePacket() {
        let (terminal, recorder) = Self.make(responds: false)
        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        terminal.sendEvent(buttonFlags: 0, x: 2, y: 1)
        #expect(recorder.sent == [Array("\u{1b}[<0;3;2M".utf8)])
    }

    @Test func aReplicaSendsASemanticClick() {
        let (terminal, recorder) = Self.make(responds: false)
        terminal.feed(text: Self.armedPrompt)
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
        #expect(recorder.sent == [Array("\u{1b}[<0;2;1M".utf8)])
    }

    @Test func aReplicaSendsUserInput() {
        let (terminal, recorder) = Self.make(responds: false)
        terminal.sendUserInput(Array("ls\r".utf8)[...])
        #expect(recorder.sent == [Array("ls\r".utf8)])
    }

    @Test func aReplicaSendsATextPaste() {
        let (terminal, recorder) = Self.make(responds: false)
        #expect(terminal.paste(TerminalPasteRequest(text: "pasted")) == .textSent)
        #expect(recorder.sent == [Array("pasted".utf8)])
    }

    @Test func aReplicaSendsAKittyPasteEvent() {
        let (terminal, recorder) = Self.make(responds: false)
        terminal.feed(text: "\u{1b}[?5522h")
        #expect(terminal.paste(TerminalPasteRequest(snapshot: Self.snapshot())) == .eventSent)
        #expect(recorder.pasteEvents.count == 1)
    }

    @Test func aReplicaSendsAFocusReportTheHostCaused() {
        let (terminal, recorder) = Self.make(responds: false)
        terminal.feed(text: "\u{1b}[?1004h")
        terminal.setTerminalFocus(false)
        #expect(recorder.sent == [Array("\u{1b}[O".utf8)])
    }

    // MARK: the 1004 enable-time report is a reply

    @Test func theFocusReportOnEnablingModeTenZeroFourIsAReply() {
        let (owner, ownerSent) = Self.make(responds: true)
        owner.feed(text: "\u{1b}[?1004h")
        #expect(ownerSent.sent == [Array("\u{1b}[I".utf8)])

        let (replica, replicaSent) = Self.make(responds: false)
        replica.feed(text: "\u{1b}[?1004h")
        #expect(replicaSent.sent.isEmpty)
    }

    // MARK: registration is unchanged (pinned against the pre-merge behaviour)

    @Test func keyboardInputRegistersOnceAndSubmitsOnNewline() {
        let (terminal, recorder) = Self.make(responds: true)
        defer { withExtendedLifetime(recorder) {} }
        terminal.feed(text: Self.armedPrompt)
        #expect(terminal.buffer.semanticInput == .armed)
        terminal.sendUserInput(Array("x".utf8)[...])
        #expect(terminal.registrations == 1)
        #expect(terminal.buffer.semanticInput == .armed)
        terminal.sendUserInput(Array("\r".utf8)[...])
        #expect(terminal.registrations == 2)
        #expect(terminal.buffer.semanticInput == .submitted)
    }

    @Test func aTextPasteRegistersOnce() {
        let (terminal, recorder) = Self.make(responds: true)
        defer { withExtendedLifetime(recorder) {} }
        terminal.feed(text: Self.armedPrompt)
        _ = terminal.paste(TerminalPasteRequest(text: "a\r"))
        #expect(terminal.registrations == 1)
        #expect(terminal.buffer.semanticInput == .submitted)
    }

    @Test func aKittyPasteEventRegistersOnce() {
        let (terminal, recorder) = Self.make(responds: true)
        defer { withExtendedLifetime(recorder) {} }
        terminal.feed(text: Self.armedPrompt + "\u{1b}[?5522h")
        #expect(terminal.paste(TerminalPasteRequest(snapshot: Self.snapshot())) == .eventSent)
        #expect(terminal.registrations == 1)
    }

    @Test func mouseClickAndFocusRegisterNothingAndLeaveTheArmedStateAlone() {
        let (terminal, recorder) = Self.make(responds: true)
        terminal.feed(text: Self.armedPrompt + "\u{1b}[?1004h")
        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        let before = recorder.sent.count
        terminal.sendEvent(buttonFlags: 0, x: 1, y: 0)
        terminal.setTerminalFocus(false)
        terminal.feed(text: "\u{1b}[?1000l")
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
        #expect(recorder.sent.count == before + 3)
        #expect(terminal.registrations == 0)
        #expect(terminal.buffer.semanticInput == .armed)
    }
}

/// P2 source pins (C5; lead ruling C).
struct ReplicaSinkSourceTests {
    static let sinks = ["sendQueryResponse", "sendUserInputBytes"]

    /// Each function that matches `tdel?.send(` in the shared sources
    /// (outside Apple/, Mac/, iOS/), any spacing, qualified or not.
    static func sendSites() throws -> [(file: String, line: Int, function: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SwiftTerm")
        let pattern = try Regex(#"tdel\s*\?\s*\.\s*send\s*\("#)
        let funcPattern = try Regex(#"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        var result: [(String, Int, String)] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if relative.hasPrefix("Apple/") || relative.hasPrefix("Mac/") || relative.hasPrefix("iOS/") { continue }
            var function = "?"
            for (index, line) in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                if let match = line.firstMatch(of: funcPattern) { function = String(match.output[1].substring ?? "?") }
                if line.contains(pattern) { result.append((relative, index + 1, function)) }
            }
        }
        return result
    }

    /// Closed and empty allow-list: a write toward the child outside the two
    /// sinks fails. To add one, add a line here with its reason.
    static let allowList: [String: String] = [:]

    @Test func onlyTheTwoSinksWriteTowardTheChild() throws {
        let sites = try Self.sendSites()
        let outside = sites.filter { !Self.sinks.contains($0.function) && Self.allowList[$0.function] == nil }
        #expect(outside.isEmpty, "\(outside.map { "\($0.file):\($0.line) in \($0.function)" })")
        #expect(Set(sites.map(\.function)) == Set(Self.sinks), "\(sites.map { "\($0.file):\($0.line) \($0.function)" })")
    }

    /// Ruling C(2): `kittyClipboardSendPasteEvent` is user input only if no
    /// parsed input reaches it; its one call site is the user-paste path.
    @Test func thePasteEventHasOneCallSite() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SwiftTerm")
        var calls: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            where line.contains("kittyClipboardSendPasteEvent(source:") && !line.contains("func ") {
                calls.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(calls == ["KittyClipboardProtocol.swift: guard terminal.tdel?.kittyClipboardSendPasteEvent(source: terminal, data: batch[...]) == true"],
                "\(calls)")
    }
}
