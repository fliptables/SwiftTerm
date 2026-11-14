//
//  TerminalViewScapeAccess.swift
//
//  Scape fork (IT-2001, "the fork only adds"): the view API Scape uses, added
//  BESIDE upstream's internal declarations instead of changing their access.
//  Each member forwards to one upstream member and adds no logic.
//
#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
#if os(macOS)
import AppKit
#endif

extension TerminalView {
    /// Runs `body` with the terminal under its lock: upstream's internal
    /// `withTerminal`. The lock is not re-entrant: do not call it, or a member
    /// that takes the lock, from inside `body`.
    public func withLockedTerminal<T>(_ body: (Terminal) throws -> T,
                                      caller: StaticString = #function) rethrows -> T {
        try withTerminal(body, caller: caller)
    }
}

#if os(macOS)
extension TerminalView {
    /// The view's selection: upstream's internal `selection`.
    public var selectionService: SelectionService { selection }

    /// The grid and pixel position under a mouse event: upstream's internal
    /// `calculateMouseHit(with:)`. Takes the terminal lock.
    public func mouseHit(with event: NSEvent) -> (grid: Position, pixels: Position) {
        calculateMouseHit(with: event)
    }
}
#endif
#endif
#endif
