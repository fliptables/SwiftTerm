#if os(macOS)
import Darwin
import Testing

@testable import SwiftTerm

/// IT-2001 D6: the fork's degenerate-size guard lives inside upstream's
/// `syncProcessWindowSizeIfNeeded()`, so both of its callers (a grid size
/// change, and a move to a window or a backing-scale change) are covered.
/// A TIOCSWINSZ with a degenerate size (SwiftUI sets a 0x0 frame while an
/// NSViewRepresentable is inserted) corrupts the shell's readline during its
/// start-up and breaks Tab completion.
@Suite("Process window size guard")
struct ProcessWindowSizeGuardTests {
    private static func size(cols: UInt16, rows: UInt16) -> winsize {
        winsize(ws_row: rows, ws_col: cols, ws_xpixel: cols &* 8, ws_ypixel: rows &* 16)
    }

    private static let previous = size(cols: 80, rows: 24)

    @Test func zeroByZeroSendsNothing() {
        #expect(!LocalProcessTerminalView.windowSizeShouldBeSent(Self.size(cols: 0, rows: 0), previous: Self.previous))
    }

    @Test func oneByOneSendsNothing() {
        #expect(!LocalProcessTerminalView.windowSizeShouldBeSent(Self.size(cols: 1, rows: 1), previous: Self.previous))
    }

    @Test func twoColumnsByOneRowSends() {
        #expect(LocalProcessTerminalView.windowSizeShouldBeSent(Self.size(cols: 2, rows: 1), previous: Self.previous))
    }

    @Test func anUnchangedSizeSendsNothing() {
        #expect(!LocalProcessTerminalView.windowSizeShouldBeSent(Self.previous, previous: Self.previous))
    }

    @Test func aChangedSizeSends() {
        #expect(LocalProcessTerminalView.windowSizeShouldBeSent(Self.size(cols: 100, rows: 30), previous: Self.previous))
    }
}
#endif
