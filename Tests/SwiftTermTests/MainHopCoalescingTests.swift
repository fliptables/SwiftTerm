//
//  MainHopCoalescingTests.swift
//  SwiftTermTests
//
//  IT-1075: DEC 2026 synchronized-output ends and OSC title changes arrive once
//  per TUI frame. Each used to enqueue its own main-queue block (~140 000/s
//  from one busy terminal), which flooded main with a dozen agent terminals.
//
//  IT-2001 D2: both now use upstream's mechanism (a329fc7). The parse thread
//  records the latest value in the view's cross-thread state and requests a
//  view update; the frame driver applies it once, at its next tick
//  (`applyPendingViewUpdates`). Neither posts to TerminalEventQueue. These
//  tests call `applyPendingViewUpdates` directly as the tick.
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

    /// Hands a main-actor object to a background thread for a call that is
    /// `nonisolated` (the terminal delegate methods the parse thread calls).
    private final class Unchecked<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
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
        view.applyPendingViewUpdates()
        delegate.scrolled.removeAll()
        delegate.titles.removeAll()
        view.eventQueue.resetCounters()
        return view
    }

    /// The headline: N frames (N sync-ends and N titles) between two frame
    /// ticks give one `scrolled` and one `setTerminalTitle`, each with the last
    /// value, and post nothing to the event queue.
    @MainActor
    @Test func burstOfSyncFramesBetweenTwoTicksDeliversOnceWithFinalState() {
        let delegate = RecordingDelegate()
        let view = makeView(delegate)
        let k = 500

        view.feed(text: Self.frames(k))

        #expect(view.eventQueue.posts == 0)
        #expect(delegate.scrolled.isEmpty)
        #expect(delegate.titles.isEmpty)

        view.applyPendingViewUpdates()

        #expect(!view.withTerminal { $0.synchronizedOutputActive })
        #expect(delegate.scrolled == [view.scrollPosition])
        #expect(delegate.titles == ["spin \(k - 1)"])

        // A second tick with nothing new delivers nothing.
        view.applyPendingViewUpdates()
        #expect(delegate.scrolled.count == 1)
        #expect(delegate.titles.count == 1)
    }

    /// Frames after a tick are delivered at the next tick, with their latest
    /// values: nothing recorded after a tick is stranded.
    @MainActor
    @Test func framesAfterATickAreDeliveredAtTheNextTick() {
        let delegate = RecordingDelegate()
        let view = makeView(delegate)

        view.feed(text: Self.frames(10))
        view.applyPendingViewUpdates()
        #expect(delegate.titles == ["spin 9"])

        view.feed(text: "\(Self.esc)[?2026h\(Self.esc)]0;final\u{7}more\r\n\(Self.esc)[?2026l")
        view.applyPendingViewUpdates()

        #expect(delegate.titles == ["spin 9", "final"])
        #expect(delegate.scrolled.count == 2)
        #expect(delegate.scrolled.last == view.scrollPosition)
        #expect(!view.withTerminal { $0.synchronizedOutputActive })
        #expect(view.eventQueue.posts == 0)
    }

    /// An unmatched `?2026h` at the end of a burst leaves sync active; the
    /// flag lives in the terminal, not in the recorded update.
    @MainActor
    @Test func trailingSyncBeginStaysActiveUntilItsEnd() {
        let delegate = RecordingDelegate()
        let view = makeView(delegate)

        view.feed(text: Self.frames(5) + "\(Self.esc)[?2026h")
        view.applyPendingViewUpdates()
        #expect(view.withTerminal { $0.synchronizedOutputActive })
        #expect(delegate.scrolled.count == 1)

        view.feed(text: "\(Self.esc)[?2026l")
        view.applyPendingViewUpdates()
        #expect(!view.withTerminal { $0.synchronizedOutputActive })
        #expect(delegate.scrolled.count == 2)
    }

    /// A sync-end followed by an alternate-screen switch between two ticks:
    /// one `scrolled`, one title, and the view ends on the alternate buffer
    /// with sync inactive.
    @MainActor
    @Test func syncEndThenBufferSwitchBetweenTwoTicksDeliversOnce() {
        let delegate = RecordingDelegate()
        let view = makeView(delegate)

        view.feed(text: Self.frames(3) + "\(Self.esc)[?1049h")
        view.eventQueue.drain()
        view.applyPendingViewUpdates()

        #expect(view.withTerminal { $0.isCurrentBufferAlternate })
        #expect(!view.withTerminal { $0.synchronizedOutputActive })
        #expect(delegate.scrolled.count == 1)
        #expect(delegate.titles == ["spin 2"])
    }

    /// Titles set from a background thread while main is blocked: one
    /// delegate call at the next tick, with the last title, and no
    /// event-queue post.
    @MainActor
    @Test func backgroundTitleBurstDeliversTheLastTitleAtTheNextTick() {
        let delegate = RecordingDelegate()
        let view = makeView(delegate)
        let box = Unchecked((view, view.terminal!))

        Self.runOnThreadBlocking {
            let (view, terminal) = box.value
            for i in 0..<10_000 {
                view.setTerminalTitle(source: terminal, title: "t\(i)")
            }
        }

        #expect(view.eventQueue.posts == 0)
        #expect(delegate.titles.isEmpty)
        view.applyPendingViewUpdates()
        #expect(delegate.titles == ["t9999"])
    }

    /// Waits on the main actor (bounded) until `done` holds.
    @MainActor
    private static func waitOnMain(_ done: () -> Bool) async {
        for _ in 0..<400 where !done() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// A view that draws no frames still delivers its title (lead 14's D2
    /// question): with no running tick source, `requestViewUpdate()` schedules
    /// one main-actor delivery, and the driver applies view updates while
    /// suspended. Nothing here calls `applyPendingViewUpdates` by hand.
    @MainActor
    @Test func aViewInNoWindowDeliversItsTitle() async {
        let delegate = RecordingDelegate()
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        view.terminalDelegate = delegate
        #expect(view.window == nil)

        view.feed(text: "\(Self.esc)]0;detached\u{7}")
        await Self.waitOnMain { !delegate.titles.isEmpty }

        #expect(delegate.titles == ["detached"])
    }

    /// The same for a view in a window that is never shown (not visible, so
    /// the frame driver is suspended), as a background tab's view is.
    @MainActor
    @Test func aViewInAHiddenWindowDeliversItsTitle() async {
        let delegate = RecordingDelegate()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        view.terminalDelegate = delegate
        window.contentView?.addSubview(view)
        #expect(view.window === window)
        #expect(!window.isVisible)
        #expect(view.frameDriver?.isVisibilitySuspended == true, "premise: the driver draws no frames")

        view.feed(text: "\(Self.esc)]0;hidden\u{7}")
        await Self.waitOnMain { !delegate.titles.isEmpty }

        #expect(delegate.titles == ["hidden"])
        view.removeFromSuperview()
    }

    /// Nothing is delivered to the delegate after the view is gone.
    @MainActor
    @Test func nothingDeliveredAfterViewTeardown() async throws {
        let delegate = RecordingDelegate()
        weak var weakView: TerminalView?
        autoreleasepool {
            let view = makeView(delegate)
            let box = Unchecked((view, view.terminal!))
            Self.runOnThreadBlocking {
                let (view, terminal) = box.value
                view.setTerminalTitle(source: terminal, title: "late")
            }
            weakView = view
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(delegate.scrolled.isEmpty)
        #expect(delegate.titles.isEmpty)
        // If the view outlived the pool, the assertions above prove nothing.
        #expect(weakView == nil)
    }
}
#endif
