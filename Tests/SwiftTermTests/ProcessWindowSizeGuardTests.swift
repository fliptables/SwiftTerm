#if os(macOS)
import Darwin
import Testing

@testable import SwiftTerm

/// IT-2001 D6: the fork's degenerate-size guard is a line added inside
/// upstream's `syncProcessWindowSizeIfNeeded()`, before upstream's own
/// "changed since the last send" check, so both of its callers (a grid size
/// change, and a move to a window or a backing-scale change) are covered.
/// A TIOCSWINSZ with a degenerate size (SwiftUI sets a 0x0 frame while an
/// NSViewRepresentable is inserted) corrupts the shell's readline during its
/// start-up and breaks Tab completion.
@Suite("Process window size guard")
struct ProcessWindowSizeGuardTests {
    private static func size(cols: UInt16, rows: UInt16) -> winsize {
        winsize(ws_row: rows, ws_col: cols, ws_xpixel: cols &* 8, ws_ypixel: rows &* 16)
    }

    @Test func zeroByZeroSendsNothing() {
        #expect(!LocalProcessTerminalView.windowSizeIsSendable(Self.size(cols: 0, rows: 0)))
    }

    @Test func oneByOneSendsNothing() {
        #expect(!LocalProcessTerminalView.windowSizeIsSendable(Self.size(cols: 1, rows: 1)))
    }

    @Test func twoColumnsByOneRowSends() {
        #expect(LocalProcessTerminalView.windowSizeIsSendable(Self.size(cols: 2, rows: 1)))
    }

    @Test func aNormalSizeSends() {
        #expect(LocalProcessTerminalView.windowSizeIsSendable(Self.size(cols: 80, rows: 24)))
    }
}
#endif
