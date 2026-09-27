//
//  TerminalEventQueue.swift
//  SwiftTerm
//
//  Coalescing channel for idempotent terminal notifications (io-gaps.md G6).
//
//  The problem it solves, measured on `cat` of 256 MB of random bytes:
//  `bufferActivated` and `mouseModeChanged` each fired 4 708 times, and every
//  one posted its own `DispatchQueue.main.async` block that then took the
//  terminal lock. The main thread's lock *holds* totalled 69 ms while its
//  *waits* totalled 12.4 seconds, because each of ~600 acquisitions per frame
//  queued behind a 3 ms parse batch.
//
//  These notifications are state edges, not history: the view only needs to
//  know the buffer changed, never how many times. So the parse thread sets a
//  bit and, only when no drain is already scheduled, posts a single main-queue
//  block. While that block is pending, every further notification is a lock and
//  a bitwise or.
//
//  This is Ghostty's `surfaceMessageWriter(.ring_bell)` shape — push a
//  payloadless value and forget — with collapsing added, which its 64-slot
//  mailbox does not do.
//

import Foundation

/// A notification that can be collapsed: repeated occurrences within one
/// delivery window are indistinguishable from a single one.
///
/// Only add cases here that are genuinely idempotent. Anything carrying a
/// payload that the view must see every time (bytes to send, a resize) does not
/// belong in this queue. A payload where only the *latest* value matters is
/// fine: it lives in `TerminalEventPayload`, is overwritten by each post, and
/// is snapshotted under the same lock that clears the event bit.
enum TerminalEvent: Int, CaseIterable, Sendable {
    /// The active buffer changed (normal <-> alternate).
    case bufferActivated = 0
    /// Mouse reporting mode changed.
    case mouseModeChanged = 1
    /// A BEL was received. Collapsing matches the debounce that follows it.
    case bell = 2
    /// DEC 2026 synchronized output ended (IT-1075). TUIs such as Claude Code
    /// bracket every frame with `?2026h` / `?2026l`, and each end used to post
    /// its own main-queue block: ~140 000 per second from one busy terminal
    /// fed a tight frame loop. The view only needs the scroller position after
    /// the last frame. The sync flag itself is read from the terminal under its
    /// lock, never carried by this hop, so collapsing cannot strand it "on".
    case synchronizedOutputEnded = 3
    /// OSC 0/2 window title changed. TUIs animate a spinner in the title, one
    /// update per frame; only the latest title is delivered.
    case titleChanged = 4

    fileprivate var mask: UInt32 { 1 << UInt32(rawValue) }
}

/// Latest-value payloads for the events that carry one. Each post overwrites
/// its field, so a drain sees the state after the most recent post.
struct TerminalEventPayload: Sendable {
    /// Scroller position computed under the terminal lock at the last
    /// `synchronizedOutputEnded` post.
    var synchronizedOutputScrollPosition: Double = 0
    /// Title from the last `titleChanged` post.
    var title: String = ""
}

/// Thread-safe coalescing queue: at most one main-queue block outstanding.
final class TerminalEventQueue: Sendable {
    private struct State {
        var pending: UInt32 = 0
        var payload = TerminalEventPayload()
        var drainScheduled = false
        var posts = 0
        var drains = 0
        var scheduledHops = 0
        var configured = false
        var onDrain: (@MainActor @Sendable (TerminalEvent, TerminalEventPayload) -> Void)?
        var canDeliverInline: (@MainActor @Sendable () -> Bool)?
    }

    private let state = Locked(State())

    /// Installs the main-actor callbacks. A queue has one sink for its complete
    /// lifetime, so configuration is deliberately one-shot.
    @MainActor
    func configure(
        onDrain: @escaping @MainActor @Sendable (TerminalEvent, TerminalEventPayload) -> Void,
        canDeliverInline: @escaping @MainActor @Sendable () -> Bool
    ) {
        state.withLock { state in
            precondition(!state.configured, "TerminalEventQueue configured more than once")
            state.configured = true
            state.onDrain = onDrain
            state.canDeliverInline = canDeliverInline
        }
    }

    /// Diagnostics: how many posts arrived, and how many main-queue drains they
    /// turned into. The ratio is the whole point of this type.
    var posts: Int { state.withLock { $0.posts } }
    var drains: Int { state.withLock { $0.drains } }
    /// Main-queue blocks this queue has enqueued. Never more than one is
    /// outstanding at a time.
    var scheduledHops: Int { state.withLock { $0.scheduledHops } }

    /// Records an event. Safe on any thread, and cheap enough for the parse
    /// path: one lock, one bitwise or, and at most one dispatch per drain
    /// window.
    func post(_ event: TerminalEvent, caller: StaticString = #function) {
        post(event, caller: caller) { _ in }
    }

    /// Records a synchronized-output end with the scroller position after it.
    func postSynchronizedOutputEnded(scrollPosition: Double,
                                     caller: StaticString = #function) {
        post(.synchronizedOutputEnded, caller: caller) {
            $0.synchronizedOutputScrollPosition = scrollPosition
        }
    }

    /// Records a title change; only the latest title survives to the drain.
    func postTitle(_ title: String, caller: StaticString = #function) {
        post(.titleChanged, caller: caller) { $0.title = title }
    }

    private func post(_ event: TerminalEvent,
                      caller: StaticString,
                      updatePayload: (inout TerminalEventPayload) -> Void) {
        // Deliver inline when the caller is already on the main thread, nothing
        // is queued ahead of this event, and the view says it is safe. This
        // keeps the long-standing synchronous behaviour for hosts that call
        // into the view directly, and costs nothing: the amplification this
        // type exists to fix comes from the parse thread, never from main.
        //
        // The "nothing queued ahead" test matters — delivering inline past
        // pending events would reorder them.
        let inlineGate = state.withLock { $0.canDeliverInline }
        let canDeliverNow = Thread.isMainThread && MainActor.assumeIsolated {
            inlineGate?() == true
        }
        if canDeliverNow {
            // Apply anything already queued together with this event, in
            // order, and clear the schedule flag. Any main-queue block still
            // outstanding then finds an empty queue and does nothing.
            //
            // Deferring instead would make delivery depend on the run loop
            // being serviced, which is not true in tests and not a contract
            // this type should impose on hosts.
            let (events, payload) = state.withLock { state in
                state.posts += 1
                updatePayload(&state.payload)
                let events = state.pending | event.mask
                state.pending = 0
                state.drainScheduled = false
                state.drains += 1
                return (events, state.payload)
            }
            MainActor.assumeIsolated {
                deliver(events, payload)
            }
            return
        }

        let needsSchedule = state.withLock { state in
            state.posts += 1
            updatePayload(&state.payload)
            state.pending |= event.mask
            if !state.drainScheduled {
                state.drainScheduled = true
                state.scheduledHops += 1
                return true
            }
            return false
        }

        guard needsSchedule else { return }
        if ProfilingStats.enabled {
            ProfilingHopCounter.shared.record(caller)
        }
        DispatchQueue.main.async { @MainActor [weak self] in
            self?.drain()
        }
    }

    /// Applies every pending event once. Main thread only.
    @MainActor
    func drain() {
        let (events, payload) = state.withLock { state in
            let events = state.pending
            state.pending = 0
            state.drainScheduled = false
            state.drains += 1
            return (events, state.payload)
        }

        deliver(events, payload)
    }

    @MainActor
    private func deliver(_ events: UInt32, _ payload: TerminalEventPayload) {
        guard events != 0 else { return }
        let onDrain = state.withLock { $0.onDrain }
        guard let onDrain else { return }
        for event in TerminalEvent.allCases where events & event.mask != 0 {
            onDrain(event, payload)
        }
    }

    func resetCounters() {
        state.withLock { state in
            state.posts = 0
            state.drains = 0
            state.scheduledHops = 0
        }
    }

    /// Test hook: pending events without touching the schedule flag.
    var pendingEventsForTesting: [TerminalEvent] {
        let events = state.withLock { $0.pending }
        return TerminalEvent.allCases.filter { events & $0.mask != 0 }
    }
}
