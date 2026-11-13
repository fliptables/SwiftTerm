import Foundation
import Testing
@testable import SwiftTerm

/// IT-2001 D7, proof P1: with `synchronizedOutputTimeout == nil` no timer is
/// requested; in the builds we ship, a timer armed earlier cannot fire; the
/// view still knows a synchronized update is open. No wall-clock dependence:
/// counters, recording delegates, callbacks delivered by hand.
@Suite(.serialized)
final class SynchronizedOutputValveTests {
    final class Recorder: TerminalDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _changes: [Bool] = []
        private var _timerRequests: [UInt32] = []
        var changes: [Bool] { lock.withLock { _changes } }
        var timerRequests: [UInt32] { lock.withLock { _timerRequests } }
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func synchronizedOutputChanged(source: Terminal, active: Bool) {
            lock.withLock { _changes.append(active) }
        }
        func scheduleSynchronizedOutputTimeout(source: Terminal, afterMilliseconds: UInt32) {
            lock.withLock { _timerRequests.append(afterMilliseconds) }
        }
    }

    private static let open = "\u{1b}[?2026h"

    // Pin 1: plain Terminal, nil from the start, DEC 2026 open.
    @Test func aPlainTerminalWithNilStaysOpenAndArmsNothing() {
        let recorder = Recorder()
        let terminal = Terminal(delegate: recorder)
        terminal.synchronizedOutputTimeout = nil
        terminal.feed(text: Self.open)

        #expect(terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 0)
        #expect(terminal.expireSynchronizedOutput() == true)
        #expect(!terminal.synchronizedOutputActive)
        #expect(terminal.expireSynchronizedOutput() == false)
        #expect(recorder.changes == [true, false])
    }

    // Pin 4: arm, set nil, deliver the old callback (plain Terminal). The work
    // item's body is exactly `synchronizedOutputWatchdogFired(generation:)`
    // (source pin below), so the callback is delivered by calling that.
    @Test func aPlainTerminalIgnoresAnOldCallbackAfterNil() {
        let recorder = Recorder()
        let terminal = Terminal(delegate: recorder)
        terminal.synchronizedOutputTimeout = 60
        terminal.feed(text: Self.open)
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 1)
        let generation = terminal.synchronizedOutputGeneration

        terminal.synchronizedOutputTimeout = nil
        terminal.synchronizedOutputWatchdogFired(generation: generation)

        #expect(terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputWatchdogCounters.fired == 0)
        #expect(recorder.changes == [true])
        terminal.feed(text: "\u{1b}[?2026l")
    }

    /// Setting a value while a window is open re-arms (P1 decision 2).
    @Test func aPlainTerminalReArmsWhenAValueIsSetInAnOpenWindow() {
        let terminal = Terminal(delegate: Recorder())
        terminal.synchronizedOutputTimeout = nil
        terminal.feed(text: Self.open)
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 0)

        terminal.synchronizedOutputTimeout = 60

        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 1)
        terminal.feed(text: "\u{1b}[?2026l")
        #expect(terminal.synchronizedOutputWatchdogCounters.cancelled == 1)
    }

    // Pin 7: the decision "request a timer, cancel, or nothing" is one pure
    // function of (active, timeout is nil, armed), used by all three branches.
    @Test func theWatchdogDecisionTable() {
        typealias T = Terminal
        #expect(T.synchronizedOutputWatchdogDecision(active: true, timeoutIsNil: false, armed: false) == .requestTimer)
        #expect(T.synchronizedOutputWatchdogDecision(active: true, timeoutIsNil: false, armed: true) == .requestTimer)
        #expect(T.synchronizedOutputWatchdogDecision(active: true, timeoutIsNil: true, armed: false) == .nothing)
        #expect(T.synchronizedOutputWatchdogDecision(active: true, timeoutIsNil: true, armed: true) == .cancel)
        #expect(T.synchronizedOutputWatchdogDecision(active: false, timeoutIsNil: false, armed: false) == .nothing)
        #expect(T.synchronizedOutputWatchdogDecision(active: false, timeoutIsNil: false, armed: true) == .cancel)
        #expect(T.synchronizedOutputWatchdogDecision(active: false, timeoutIsNil: true, armed: false) == .nothing)
        #expect(T.synchronizedOutputWatchdogDecision(active: false, timeoutIsNil: true, armed: true) == .cancel)
    }

    // Pin 6, the narrowed Embedded guarantee, through the decision's seam:
    // the host-timer branch requests on `decision(...) == .requestTimer` with
    // `armed: false` (source pin below). Across windows and re-entry into
    // DEC 2026, one request is recorded per window while a value is set and
    // none after nil.
    @Test func theHostTimerIsRequestedOnlyWhileAValueIsSet() {
        var requests = 0
        func window(timeoutIsNil: Bool) {
            for active in [true, true, false] where Terminal.synchronizedOutputWatchdogDecision(
                active: active, timeoutIsNil: timeoutIsNil, armed: false) == .requestTimer {
                requests += 1
            }
        }
        window(timeoutIsNil: false)
        #expect(requests == 2)
        requests = 0
        window(timeoutIsNil: true)
        window(timeoutIsNil: true)
        #expect(requests == 0)
    }

    // Pin 6, the stated consequence (not a rejection): with nil and the mode
    // open, a public expiry (a late host timer or the ordered valve: the same
    // call) ends the mode and returns true.
    @Test func withNilAPublicExpiryEndsTheModeAsTheOrderedValve() {
        let recorder = Recorder()
        let terminal = Terminal(delegate: recorder)
        terminal.synchronizedOutputTimeout = nil
        terminal.feed(text: Self.open)
        #expect(terminal.expireSynchronizedOutput() == true)
        #expect(recorder.changes == [true, false])
    }

    // Pin 5(b): ViewTerminal, a callback already past the view target's lock:
    // capture the armed generation, set nil, deliver it to the terminal.
    @Test func aViewTerminalIgnoresACallbackAlreadyPastTheTargetAfterNil() {
        let recorder = Recorder()
        let updates = Locked<[(Bool, UInt64)]>([])
        let terminal = ViewTerminal(
            delegate: recorder,
            synchronizedOutputWatchdogHandler: { active, generation in
                updates.withLock { $0.append((active, generation)) }
            },
            scrollHandler: { _ in })
        terminal.terminalLock.withLock {
            terminal.synchronizedOutputTimeout = 60
            terminal.feed(text: Self.open)
        }
        let armed = updates.withLock { $0.last }
        #expect(armed?.0 == true)
        let generation = armed?.1 ?? 0

        terminal.terminalLock.withLock { terminal.synchronizedOutputTimeout = nil }
        terminal.synchronizedOutputWatchdogFired(generation: generation)

        terminal.terminalLock.withLock {
            #expect(terminal.synchronizedOutputActive)
            #expect(terminal.synchronizedOutputWatchdogCounters.fired == 0)
        }
        #expect(recorder.changes == [true])
    }

#if os(macOS)
    @MainActor
    private func pipeline(_ recorder: Recorder) -> (owner: TerminalRenderOwner, terminal: ViewTerminal) {
        let owner = TerminalRenderOwner()
        let terminal = ViewTerminal(
            delegate: recorder,
            options: TerminalOptions(cols: 40, rows: 5, scrollback: 20),
            synchronizedOutputWatchdogHandler: owner.synchronizedOutputWatchdogHandler()
        ) { _ in }
        let selection = terminal.terminalLock.withLock { SelectionService(terminal: terminal) }
        owner.attach(terminal: terminal, selection: selection, search: SearchService(terminal: terminal))
        return (owner, terminal)
    }

    // Pin 2: ViewTerminal, nil, DEC 2026 open: the view still holds its
    // display (the feed transaction reports the mode active, which is what
    // the view reads) and the view's watchdog never armed.
    @MainActor
    @Test func aViewWithNilHoldsItsDisplayAndArmsNoWatchdog() {
        let recorder = Recorder()
        let (owner, terminal) = pipeline(recorder)
        terminal.terminalLock.withLock {
            terminal.synchronizedOutputTimeout = 60
            terminal.synchronizedOutputTimeout = nil
        }

        let held = owner.feed(text: Self.open)

        #expect(held == true)
        #expect(owner.feed(text: "") == true)
        #expect(owner.synchronizedOutputWatchdog.counters.armed == 0)
        #expect(owner.synchronizedOutputWatchdog.target.counters.armed == 0)
        owner.synchronizedOutputWatchdog.invalidate()
    }

    // Pin 3: ViewTerminal, nil: expiry returns true once; the view is
    // released (the next transaction reports the mode inactive) and redraws
    // (the whole screen is in the update range; the view is told it ended).
    @MainActor
    @Test func aViewWithNilIsReleasedAndRedrawsOnExpiry() {
        let recorder = Recorder()
        let (owner, terminal) = pipeline(recorder)
        terminal.terminalLock.withLock { terminal.synchronizedOutputTimeout = nil }
        #expect(owner.feed(text: Self.open) == true)

        let (first, second, range) = terminal.terminalLock.withLock {
            _ = terminal.getUpdateRange()
            terminal.clearUpdateRange()
            let first = terminal.expireSynchronizedOutput()
            let range = terminal.getUpdateRange()
            let second = terminal.expireSynchronizedOutput()
            return (first, second, range)
        }

        #expect(first == true)
        #expect(second == false)
        #expect(range?.startY == 0)
        #expect(range?.endY == 4)
        #expect(recorder.changes == [true, false])
        #expect(owner.feed(text: "") == false)
        owner.synchronizedOutputWatchdog.invalidate()
    }

    /// A view pipeline whose watchdog runs no timer: a ViewTerminal, the
    /// view's `Target`, and one pending-update slot that each handler call
    /// overwrites and `feed` applies after `terminalLock` is released, as
    /// TerminalRenderOwner.feedTransaction does. `arm` is a no-op and the
    /// timeout is 0, so an armed deadline has already passed and `fire()` by
    /// hand is not stopped by the clock.
    final class ClocklessView {
        let recorder = Recorder()
        let target = SynchronizedOutputWatchdog.Target()
        let pending = Locked<(Bool, UInt64)?>(nil)
        let terminal: ViewTerminal

        init() {
            let pending = pending
            terminal = ViewTerminal(
                delegate: recorder,
                synchronizedOutputWatchdogHandler: { active, generation in
                    pending.withLock { $0 = (active, generation) }
                },
                scrollHandler: { _ in })
            target.attach(terminal: terminal) {}
        }

        func setTimeout(_ value: TimeInterval?) {
            terminal.terminalLock.withLock { terminal.synchronizedOutputTimeout = value }
        }

        func feed(_ text: String) {
            terminal.terminalLock.withLock { terminal.feed(text: text) }
            guard let update = pending.withLock({ value -> (Bool, UInt64)? in
                defer { value = nil }
                return value
            }) else { return }
            target.update(active: update.0, generation: update.1, timeout: 0, arm: { _ in }, disarm: {})
        }

        var active: Bool { terminal.terminalLock.withLock { terminal.synchronizedOutputActive } }
        var terminalFired: Int { terminal.terminalLock.withLock { terminal.synchronizedOutputWatchdogCounters.fired } }
        var generation: UInt64 { terminal.terminalLock.withLock { terminal.synchronizedOutputGeneration } }
    }

    // Pin 5(a): arm, set nil, one feed (an empty batch), then the view's
    // Target.fire() by hand returns before reaching the terminal.
    @Test func aViewDisarmedByNilAndOneFeedDoesNotReachTheTerminal() {
        let view = ClocklessView()
        view.setTimeout(60)
        view.feed(Self.open)
        #expect(view.target.armedGeneration == view.generation)

        view.setTimeout(nil)
        view.feed("")
        view.target.fire()

        #expect(view.target.armedGeneration == nil)
        #expect(view.target.counters.fired == 0)
        #expect(view.terminalFired == 0)
        #expect(view.active)
        #expect(view.recorder.changes == [true])
    }

    // Pin 5(c), sub-case "armed before": window open and armed at g; nil then
    // a value with no feed: the view's armed + rearmed is unchanged; after
    // one empty feed exactly one arm is outstanding, for g; the mode is open.
    @Test func aViewArmedBeforeNilThenAValueKeepsItsOneArm() {
        let view = ClocklessView()
        view.setTimeout(60)
        view.feed(Self.open)
        let g = view.generation
        let before = view.target.counters

        view.setTimeout(nil)
        view.setTimeout(60)
        #expect(view.target.counters.armed + view.target.counters.rearmed == before.armed + before.rearmed)
        view.feed("")

        let after = view.target.counters
        #expect(after.armed + after.rearmed == before.armed + before.rearmed)
        #expect(after.armed - after.cancelled - after.fired == 1)
        #expect(view.target.armedGeneration == g)
        #expect(view.active)
    }

    // Pin 5(c), sub-case "nil from the start": the view never armed; a value
    // set with no feed arms nothing until the next feed, which arms once, for
    // the current generation. (The limitation: until a feed comes, this view
    // has no valve.)
    @Test func aViewOpenedWithNilArmsOnlyAtTheFeedAfterAValue() {
        let view = ClocklessView()
        view.setTimeout(nil)
        view.feed(Self.open)
        #expect(view.target.counters.armed == 0)

        view.setTimeout(60)
        #expect(view.target.counters.armed + view.target.counters.rearmed == 0)
        view.feed("")

        #expect(view.target.counters.armed == 1)
        #expect(view.target.counters.rearmed == 0)
        #expect(view.target.armedGeneration == view.generation)
        #expect(view.active)
    }

    // Pin 5(c), sub-case "a late fire consumed the arm": armed at g, nil, the
    // view's timer fires (the terminal ignores it: nil), then a value and one
    // feed: a NEW arm (armed + 1), for g.
    @Test func aViewWhoseLateFireConsumedTheArmArmsAgainAtTheNextFeed() {
        let view = ClocklessView()
        view.setTimeout(60)
        view.feed(Self.open)
        let g = view.generation

        view.setTimeout(nil)
        view.target.fire()
        #expect(view.target.counters.fired == 1)
        #expect(view.terminalFired == 0)
        #expect(view.active)
        #expect(view.target.armedGeneration == nil)

        view.setTimeout(60)
        view.feed("")

        #expect(view.target.counters.armed == 2)
        #expect(view.target.armedGeneration == g)
        #expect(view.active)
    }

    // Pin 5(d): armed at g; nil then a value, no feed; one feed: the view's
    // target is still armed for g (the original arm and its deadline stand;
    // rearmed and cancelled unchanged). The accept half, as 5(b) does it: g
    // delivered to the terminal by hand ends the mode; the terminal's fired
    // is 1. No generation bump: the generation names a window.
    @MainActor
    @Test func aViewKeepsItsOriginalArmAcrossNilAndAValue() {
        let recorder = Recorder()
        let (owner, terminal) = pipeline(recorder)
        terminal.terminalLock.withLock { terminal.synchronizedOutputTimeout = 60 }
        _ = owner.feed(text: Self.open)
        let g = terminal.terminalLock.withLock { terminal.synchronizedOutputGeneration }
        let before = owner.synchronizedOutputWatchdog.counters
        #expect(owner.synchronizedOutputWatchdog.target.armedGeneration == g)

        terminal.terminalLock.withLock {
            terminal.synchronizedOutputTimeout = nil
            terminal.synchronizedOutputTimeout = 60
        }
        _ = owner.feed(text: "")

        let after = owner.synchronizedOutputWatchdog.counters
        #expect(owner.synchronizedOutputWatchdog.target.armedGeneration == g)
        #expect(after.rearmed == before.rearmed)
        #expect(after.cancelled == before.cancelled)

        terminal.synchronizedOutputWatchdogFired(generation: g)
        terminal.terminalLock.withLock {
            #expect(!terminal.synchronizedOutputActive)
            #expect(terminal.synchronizedOutputWatchdogCounters.fired == 1)
        }
        owner.synchronizedOutputWatchdog.invalidate()
    }
#endif
}

/// P1 source pins (pin 8; lead ruling D).
struct SynchronizedOutputValveSourceTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SwiftTerm")

    static func swiftFiles() throws -> [(String, String)] {
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        var result: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append((url.path, try String(contentsOf: url, encoding: .utf8)))
        }
        return result
    }

    static func terminalSource() throws -> String {
        try String(contentsOf: sources.appendingPathComponent("Terminal.swift"), encoding: .utf8)
    }

    /// The body of `func <name>` (from its line to the line that closes it at
    /// the same indentation).
    static func body(of signature: String, in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(signature) }) else { return [] }
        let indent = lines[start].prefix { $0 == " " }
        var end = start + 1
        while end < lines.count, lines[end] != "\(indent)}" { end += 1 }
        return Array(lines[start...min(end, lines.count - 1)])
    }

    /// No subclass overrides the gated caller, so every receiver of the
    /// watchdog signal is behind the gate.
    @Test func noOverrideOfTheGatedCaller() throws {
        for (path, text) in try Self.swiftFiles() {
            #expect(!text.contains("override func reconcileSynchronizedOutputWatchdog"), "\(path)")
        }
        let reconcile = Self.body(of: "func reconcileSynchronizedOutputWatchdog", in: try Self.terminalSource())
        #expect(reconcile.first?.contains("final func reconcileSynchronizedOutputWatchdog") == true,
                "\(reconcile.first ?? "not found")")
    }

    /// The Embedded branch requests a host timer only on the decision
    /// function's result, and it is the only request in the sources.
    @Test func theEmbeddedTimerRequestIsOnTheDecisionsResult() throws {
        var requests: [String] = []
        for (path, text) in try Self.swiftFiles() {
            for line in text.components(separatedBy: "\n")
            where line.contains("scheduleSynchronizedOutputTimeout(source: self") {
                requests.append("\(path): \(line)")
            }
        }
        #expect(requests.count == 1, "\(requests)")
        let apply = Self.body(of: "func applySynchronizedOutputWatchdog(active: Bool, generation: UInt64) {",
                              in: try Self.terminalSource())
        guard let request = apply.firstIndex(where: { $0.contains("scheduleSynchronizedOutputTimeout(source: self") }),
              request > 0 else {
            Issue.record("no request in applySynchronizedOutputWatchdog: \(apply)")
            return
        }
        let guardLine = apply[request - 1].trimmingCharacters(in: .whitespaces)
        #expect(guardLine.hasPrefix("if Terminal.synchronizedOutputWatchdogDecision("), "\(guardLine)")
        #expect(guardLine.hasSuffix("== .requestTimer {"), "\(guardLine)")
    }

    /// Lead ruling D: no seam. The terminal's own work item's body is exactly
    /// the call the tests deliver by hand.
    @Test func theWorkItemBodyIsExactlyTheFiredCall() throws {
        let apply = Self.body(of: "func applySynchronizedOutputWatchdog(active: Bool, generation: UInt64) {",
                              in: try Self.terminalSource())
        let normal = apply.drop { !$0.contains("#else") }.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let open = normal.firstIndex(of: "let workItem = TerminalEventWorkItem {") else {
            Issue.record("work item not found: \(normal)")
            return
        }
        #expect(normal[open + 1] == "self.synchronizedOutputWatchdogFired(generation: generation)")
        #expect(normal[open + 2] == "}")
    }
}
