//
//  MainHopCoalescingTests.swift
//  SwiftTermTests
//
//  IT-1075: DEC 2026 synchronized-output ends and OSC title changes arrive once
//  per TUI frame. Each used to enqueue its own main-queue block (~140 000/s
//  from one busy terminal), which flooded main with a dozen agent terminals.
//  They now ride TerminalEventQueue: at most one main block outstanding per
//  terminal, carrying the latest state.
//

import Foundation
import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit

@Suite("Main-hop coalescing (IT-1075)")
struct MainHopCoalescingTests {
    private static let esc = "\u{1b}"

    /// K Claude-Code-shaped frames: sync begin, title spinner, redraw, sync end.
    private static func frames(_ k: Int) -> String {
        (0..<k).map { i in
            "\(esc)[?2026h\(esc)]0;spin \(i)\u{7}\(esc)[H\(esc)[2Kframe \(i)\(esc)[?2026l"
        }.joined()
    }

    private final class RecordingDelegate: TerminalViewDelegate, @unchecked Sendable {
        var scrolled: [Double] = []
        var titles: [String] = []

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) { titles.append(title) }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) { scrolled.append(position) }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// Runs `body` on a fresh thread and blocks the caller (main) until it
    /// finishes, so main cannot service the queue during the burst.
    private static func runOnThreadBlocking(_ body: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        Thread {
            body()
            done.signal()
        }.start()
        done.wait()
    }

    @MainActor
    private func makeView(_ delegate: RecordingDelegate) -> TerminalView {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        view.terminalDelegate = delegate
        // Scroll the normal buffer so the sync-end position is a real value.
        for i in 0..<30 {
            view.feed(text: "line \(i)\r\n")
        }
        view.eventQueue.drain()
        delegate.scrolled.removeAll()
        delegate.titles.removeAll()
        view.eventQueue.resetCounters()
        return view
    }

    /// The headline: a burst of K frames (2K sync toggles + K titles) enqueues
    /// at most one main block, and draining it leaves the final state applied.
    /// Main is not serviced during the burst, which is the busy-main scenario.
    @MainActor
    @Test func burstOfSyncFramesYieldsOneMainHopAndFinalState() {
        let delegate = RecordingDelegate()
        let view = makeView(delegate)
        let k = 500

        view.feed(text: Self.frames(k))

        // Parsing holds the terminal lock, so nothing is delivered inline.
        #expect(view.eventQueue.posts == 2 * k)
        #expect(view.eventQueue.scheduledHops <= 1)
        #expect(delegate.scrolled.isEmpty)
        #expect(delegate.titles.isEmpty)

        // Discard feed-time frame requests so the drain's own request is seen.
        _ = view.frameSignal.takePendingDirtyForTesting()
        view.eventQueue.drain()

        #expect(view.eventQueue.drains == 1)
        #expect(!view.withTerminal { $0.synchronizedOutputActive })
        #expect(delegate.scrolled == [view.scrollPosition])
        #expect(delegate.titles == ["spin \(k - 1)"])
        // No missed final render: the drain requested a frame after the last end.
        #expect(view.frameSignal.takePendingDirtyForTesting())
    }

    /// Frames that arrive after a drain has started must schedule a new hop:
    /// the flag is cleared under the same lock that snapshots the state, so a
    /// late sync-end or title is never stranded.
    @MainActor
    @Test func postsAfterDrainScheduleAnotherHopWithLatestState() {
        let delegate = RecordingDelegate()
        let view = makeView(delegate)

        view.feed(text: Self.frames(10))
        view.eventQueue.drain()
        #expect(delegate.titles == ["spin 9"])

        view.feed(text: "\(Self.esc)[?2026h\(Self.esc)]0;final\u{7}more\r\n\(Self.esc)[?2026l")
        #expect(view.eventQueue.scheduledHops == 2)
        view.eventQueue.drain()

        #expect(delegate.titles == ["spin 9", "final"])
        #expect(delegate.scrolled.count == 2)
        #expect(delegate.scrolled.last == view.scrollPosition)
        #expect(!view.withTerminal { $0.synchronizedOutputActive })
    }

    /// An unmatched `?2026h` at the end of a burst leaves sync active and
    /// posts nothing for it; the flag lives in the terminal, not in the hop.
    @MainActor
    @Test func trailingSyncBeginStaysActiveUntilItsEnd() {
        let delegate = RecordingDelegate()
        let view = makeView(delegate)

        view.feed(text: Self.frames(5) + "\(Self.esc)[?2026h")
        view.eventQueue.drain()
        #expect(view.withTerminal { $0.synchronizedOutputActive })
        #expect(delegate.scrolled.count == 1)

        view.feed(text: "\(Self.esc)[?2026l")
        view.eventQueue.drain()
        #expect(!view.withTerminal { $0.synchronizedOutputActive })
        #expect(delegate.scrolled.count == 2)
    }

    /// Real delivery path: posts from a background thread while main is
    /// blocked collapse to one block, which the run loop then delivers.
    @MainActor
    @Test func backgroundBurstDeliversOnceThroughMainQueue() async throws {
        let delegate = RecordingDelegate()
        let view = makeView(delegate)
        let queue = view.eventQueue

        Self.runOnThreadBlocking {
            for i in 0..<10_000 {
                queue.postSynchronizedOutputEnded(scrollPosition: Double(i) / 10_000)
                queue.postTitle("t\(i)")
            }
        }

        #expect(queue.posts == 20_000)
        #expect(queue.scheduledHops == 1)

        // Yield main so the queued block runs (a RunLoop spin inside this
        // main-queue test body would not drain the main queue).
        try await Task.sleep(nanoseconds: 200_000_000)

        // (`drains` may also count an empty block left over from makeView's
        // setup feed; what matters is one hop for the burst and one delivery.)
        #expect(queue.scheduledHops == 1)
        #expect(delegate.scrolled == [9_999.0 / 10_000])
        #expect(delegate.titles == ["t9999"])
    }

    /// Nothing is delivered to the delegate after the view is gone: the queued
    /// block holds the queue weakly and the queue's sink holds the view weakly.
    @MainActor
    @Test func nothingDeliveredAfterViewTeardown() async throws {
        let delegate = RecordingDelegate()
        weak var weakView: TerminalView?
        weak var weakQueue: TerminalEventQueue?
        autoreleasepool {
            let view = makeView(delegate)
            let queue = view.eventQueue
            Self.runOnThreadBlocking {
                queue.postSynchronizedOutputEnded(scrollPosition: 0.5)
                queue.postTitle("late")
            }
            #expect(queue.scheduledHops == 1)
            weakView = view
            weakQueue = queue
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(delegate.scrolled.isEmpty)
        #expect(delegate.titles.isEmpty)
        // If the view outlived the pool, the assertions above prove nothing.
        #expect(weakView == nil)
        #expect(weakQueue == nil)
    }
}
#endif
