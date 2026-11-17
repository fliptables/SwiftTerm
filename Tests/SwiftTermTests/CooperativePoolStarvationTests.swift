#if os(macOS)
import AppKit
import XCTest

@testable import SwiftTerm

/// IT-2141: a terminal must keep drawing, reading and reporting while Swift's
/// cooperative thread pool is starved.
///
/// In Scape on 17 Nov every thread of the pool blocked at 15:24:41 and never
/// came back. The main thread and GCD kept running, but no job that needed a
/// pool thread ran again. Every terminal stopped repainting: the frame signal
/// asked for its main-actor delivery with `Task { @MainActor in … }`, that task
/// never ran, and `deliveryScheduled` stayed latched, so no later mark asked
/// again. Keystrokes still reached the pty, so the caret moved and nothing else.
///
/// These tests block the pool at every priority, prove the starvation with a
/// probe task that must not run, and then check each main hop the terminal
/// needs. They are XCTest, not Swift Testing, on purpose: a synchronous XCTest
/// method runs on the main thread outside any main-queue block and outside the
/// pool, so it can spin the run loop and still observe main-queue work while
/// the pool is blocked. A Swift Testing body would need the pool to resume.
@MainActor
final class CooperativePoolStarvationTests: XCTestCase {

    // MARK: - The four hops

    /// The frame signal's delivery is what a repaint waits for. A mark from a
    /// background thread (the pty parse thread in the app) must reach the sink.
    func testFrameSignalDeliversWhileThePoolIsStarved() throws {
        let signal = FrameDriverSignal()
        let deliveries = Locked(0)
        signal.configure { deliveries.withLock { $0 += 1 } }

        let starver = try starvedPool()
        defer { starver.release() }

        DispatchQueue.global(qos: .userInitiated).async { signal.markDirty() }
        let delivered = spinMain(until: { deliveries.withLock { $0 } >= 1 }, timeout: 3)

        XCTAssertTrue(delivered, "a dirty mark published while the pool is starved never reached the frame sink, so the view would never repaint")
    }

    /// Input sent off the main thread is delivered to the delegate on main.
    func testOffMainInputReachesTheDelegateWhileThePoolIsStarved() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let delegate = SendRecorder()
        view.terminalDelegate = delegate

        let starver = try starvedPool()
        defer { starver.release() }

        DispatchQueue.global(qos: .userInitiated).async { view.send(data: Array("ab".utf8)[...]) }
        let delivered = spinMain(until: { delegate.bytes.withLock { $0 } == Array("ab".utf8) }, timeout: 3)

        XCTAssertTrue(delivered, "input sent off main while the pool is starved never reached the delegate")
    }

    /// A keystroke reaches the pty and its echo is read back. This path has no
    /// pool hop; the test keeps it that way (IT-2141 question 2: on 17 Nov the
    /// typed bytes still reached the pty).
    func testKeystrokeReachesThePtyAndEchoesWhileThePoolIsStarved() throws {
        let host = ProcessHost()
        let view = try host.startCat()
        defer { host.stop() }
        // Let the shell-less cat settle so a stray startup byte can't pass the test.
        _ = spinMain(until: { false }, timeout: 0.3)
        let before = view.diagnostics.bytesFed

        let starver = try starvedPool()
        defer { starver.release() }

        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        let echoed = spinMain(until: { view.diagnostics.bytesFed > before }, timeout: 3)

        XCTAssertTrue(echoed, "a keystroke typed while the pool is starved never came back from the pty")
    }

    /// The child's exit reaches the host while the pool is starved.
    func testProcessExitIsReportedWhileThePoolIsStarved() throws {
        let host = ProcessHost()
        let view = try host.startCat()
        defer { host.stop() }

        let starver = try starvedPool()
        defer { starver.release() }

        view.send(data: [0x04][...])   // ^D on an empty line: cat reads EOF and exits
        let reported = spinMain(until: { host.recorder.terminations.withLock { $0 } >= 1 }, timeout: 5)

        XCTAssertTrue(reported, "the child exited while the pool was starved, but processTerminated never reached the host")
    }

    // MARK: - Starving the pool

    /// Blocks every priority lane of the cooperative pool, then proves it.
    /// Fails the test (rather than passing vacuously) if a probe still runs.
    private func starvedPool(file: StaticString = #filePath, line: UInt = #line) throws -> PoolStarver {
        let starver = PoolStarver()
        starver.block()
        // Wait for the blockers to take every thread they can get: the count
        // stops rising once the pool is full.
        var last = -1
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            _ = spinMain(until: { false }, timeout: 0.05)
            let now = starver.started.withLock { $0 }
            if now != last { last = now; stableSince = Date() }
            if now > 0, Date().timeIntervalSince(stableSince) > 0.5 { break }
        }
        // The proof: a fresh task at the highest and the lowest priority must
        // not run while the pool is starved.
        let probeRan = Locked(false)
        for priority in [TaskPriority.high, .background] {
            Task.detached(priority: priority) { probeRan.withLock { $0 = true } }
        }
        _ = spinMain(until: { probeRan.withLock { $0 } }, timeout: 0.5)
        if probeRan.withLock({ $0 }) {
            starver.release()
            XCTFail("could not starve the cooperative pool (\(last) blockers running); this test proves nothing", file: file, line: line)
            throw PoolNotStarved()
        }
        return starver
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func spinMain(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

private struct PoolNotStarved: Error {}

/// Occupies every thread of the cooperative pool with tasks that block on a
/// semaphore, at each priority, until `release()`.
private final class PoolStarver: @unchecked Sendable {
    let started = Locked(0)
    let finished = Locked(0)
    private let gate = DispatchSemaphore(value: 0)
    private var total = 0
    private var released = false

    func block() {
        let perPriority = ProcessInfo.processInfo.activeProcessorCount * 2
        for priority in [TaskPriority.high, .medium, .low, .background] {
            for _ in 0..<perPriority {
                total += 1
                Task.detached(priority: priority) { [self] in
                    started.withLock { $0 += 1 }
                    waitOnGate()
                    finished.withLock { $0 += 1 }
                }
            }
        }
    }

    /// Synchronous on purpose: a blocking wait is not allowed directly in an
    /// async body, and blocking the pool thread is the whole point.
    private func waitOnGate() {
        gate.wait()
    }

    /// Unblocks every blocker, and waits for them to finish so the next test
    /// starts with a healthy pool.
    func release() {
        guard !released else { return }
        released = true
        for _ in 0..<total { gate.signal() }
        let deadline = Date().addingTimeInterval(10)
        while finished.withLock({ $0 }) < total, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

private final class SendRecorder: TerminalViewDelegate {
    let bytes = Locked<[UInt8]>([])
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.withLock { $0.append(contentsOf: data) } }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
}

private final class ProcessRecorder: LocalProcessTerminalViewDelegate {
    let terminations = Locked(0)
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { terminations.withLock { $0 += 1 } }
}

/// A real `LocalProcessTerminalView` running `/bin/cat` in a pty.
@MainActor
private final class ProcessHost {
    let recorder = ProcessRecorder()
    private var view: LocalProcessTerminalView?

    func startCat() throws -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.processDelegate = recorder
        view.startProcess(executable: "/bin/cat")
        self.view = view
        let deadline = Date().addingTimeInterval(5)
        while view.process?.running != true, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard view.process?.running == true else {
            throw XCTSkip("could not start /bin/cat in a pty")
        }
        return view
    }

    func stop() {
        if view?.process?.running == true { view?.terminate() }
        view = nil
    }
}
#endif
