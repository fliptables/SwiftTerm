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
/// needs. The hops are driven from a dedicated `.userInitiated` Thread, the
/// way the app drives them (the pty reader is its own Thread): starving the
/// pool also stops the constrained `DispatchQueue.global()` queues, so a hop
/// driven from GCD would prove nothing. They are XCTest, not Swift Testing, on purpose: a synchronous XCTest
/// method runs on the main thread outside any main-queue block and outside the
/// pool, so it can spin the run loop and still observe main-queue work while
/// the pool is blocked. A Swift Testing body would need the pool to resume.
@MainActor
final class CooperativePoolStarvationTests: XCTestCase {

    // MARK: - The hops (driven the way the app drives them)

    /// The frame signal's delivery is what a repaint waits for. A mark from a
    /// background thread (the pty parse thread in the app) must reach the sink.
    func testFrameSignalDeliversWhileThePoolIsStarved() throws {
        let signal = FrameDriverSignal()
        let deliveries = Locked(0)
        signal.configure { deliveries.withLock { $0 += 1 } }

        let starver = try starvedPool()
        defer { starver.release() }

        let drove = driveFromThread { signal.markDirty() }
        XCTAssertTrue(drove, "the driving thread never ran")
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

        let drove = driveFromThread { view.send(data: Array("ab".utf8)[...]) }
        XCTAssertTrue(drove, "the driving thread never ran")
        let delivered = spinMain(until: { delegate.bytes.withLock { $0 } == Array("ab".utf8) }, timeout: 3)

        XCTAssertTrue(delivered, "input sent off main while the pool is starved never reached the delegate")
    }

    /// The process adapter's exit callback reaches the host. The child's exec
    /// fails, so it exits (127) at once with no pty I/O. The exit then travels
    /// the app's own path: a process source on main, a dedicated reaper
    /// Thread, `main.async`, then the adapter's hop to the host. None of that
    /// needs a GCD global queue. The child starts AFTER the pool is starved,
    /// so its exit is delivered under starvation.
    func testProcessExitIsReportedWhileThePoolIsStarved() throws {
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let recorder = ProcessRecorder()
        view.processDelegate = recorder

        let starver = try starvedPool()
        defer { starver.release() }

        view.startProcess(executable: "/nonexistent/it2141-exec-fails")
        // The view owns the process and its adapter: keep it alive while the
        // exit is in flight.
        let reported = withExtendedLifetime(view) {
            spinMain(until: { recorder.terminations.withLock { $0 } >= 1 }, timeout: 5)
        }

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
        var plateaued = false
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            _ = spinMain(until: { false }, timeout: 0.05)
            let now = starver.started.withLock { $0 }
            if now != last { last = now; stableSince = Date() }
            if now > 0, Date().timeIntervalSince(stableSince) > 0.5 { plateaued = true; break }
        }
        guard plateaued else {
            starver.release()
            XCTFail("the blockers never settled within 10 s (\(last) running); this test proves nothing", file: file, line: line)
            throw PoolNotStarved()
        }
        // The proof: a fresh task at the highest and the lowest priority must
        // not run while the pool is starved. The probes stay queued; release()
        // checks them again, so a pool that was only slow (not starved) when
        // this check ran fails the test instead of passing it.
        let probeRan = starver.probeRan
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

    /// Runs `body` once on a new `.userInitiated` Thread (a pthread, not GCD)
    /// and waits for it to finish. True when the body ran.
    private func driveFromThread(_ body: @escaping @Sendable () -> Void) -> Bool {
        let ran = Locked(false)
        let thread = Thread {
            body()
            ran.withLock { $0 = true }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
        return spinMain(until: { ran.withLock { $0 } }, timeout: 3)
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
    /// Set by a probe task. It must stay false until `release()`.
    let probeRan = Locked(false)
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
        // Checked before the gate opens: a probe that ran means the pool had a
        // free thread during the test, so whatever the test saw proves nothing.
        if probeRan.withLock({ $0 }) {
            XCTFail("a probe task ran before release: the pool was not starved for the whole test")
        }
        for _ in 0..<total { gate.signal() }
        let deadline = Date().addingTimeInterval(60)
        while finished.withLock({ $0 }) < total, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        // A blocker still running would starve the next test's pool: fail
        // here, by name, rather than leave a dirty pool behind silently.
        let done = finished.withLock { $0 }
        if done < total {
            XCTFail("the pool did not drain: \(done) of \(total) blockers finished within 60 s of release")
        }
    }
}

private final class ProcessRecorder: LocalProcessTerminalViewDelegate {
    let terminations = Locked(0)
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { terminations.withLock { $0 += 1 } }
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

#endif
