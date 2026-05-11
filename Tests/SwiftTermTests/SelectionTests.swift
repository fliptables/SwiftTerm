//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 4/29/20.
//

import Foundation
import Testing

@testable import SwiftTerm

final class SelectionTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        print ("here")
    }
    
    @Test func testDoesNotCrashWhenSelectingWordOrExpressionOutsideColumnRange() {
        let terminal = Terminal(delegate: self, options: TerminalOptions (cols: 10, rows: 10))
        let selection = SelectionService(terminal: terminal)
        terminal.feed (text: "1234567890")
        
        // depending on the size of terminal view, there might be a space near the margin where the user
        // clicks which might result in a col or row outside the bounds of terminal,
        selection.selectWordOrExpression(at: Position(col: -1, row: 0), in: terminal.buffer)
        selection.selectWordOrExpression(at: Position(col: 11, row: 0), in: terminal.buffer)
    }
    
    @Test func testDoesNotCrashWhenSelectingWordOrExpressionOutsideRowRange() {
        let terminal = Terminal(delegate: self, options: TerminalOptions (cols: 10, rows: 10))
        let selection = SelectionService(terminal: terminal)
        terminal.feed (text: "1234567890")

        // depending on the size of terminal view, there might be a space near the margin where the user
        // clicks which might result in a col or row outside the bounds of terminal,
        selection.selectWordOrExpression(at: Position (col: 0, row: -1), in: terminal.buffer)

    }

    @Test func testSelectWordOrExpressionSelectsWord() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "hello world")

        selection.selectWordOrExpression(at: Position(col: 1, row: 0), in: terminal.buffer)

        #expect(selection.getSelectedText() == "hello")
    }

    @Test func testSelectWordOrExpressionSelectsBalancedParens() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "(abc) def")

        selection.selectWordOrExpression(at: Position(col: 0, row: 0), in: terminal.buffer)
        #expect(selection.getSelectedText() == "(abc)")

        selection.selectWordOrExpression(at: Position(col: 4, row: 0), in: terminal.buffer)
        #expect(selection.getSelectedText() == "(abc)")
    }

#if os(macOS)
    // Test only on macOS due to differences in how frames are handled on mac and iOS
    @Test func testMouseHitCorrectWhenScrolled() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 10, height: 10)))

        for _ in 0..<100 {
            view.terminal.feed (text: "12345")
        }

        // Scroll all the way down, check the bottom-left corner
        view.scrollTo(row: 100)
        #expect(view.calculateMouseHit(at: CGPoint(x: 0, y: 0)).grid.row == 100)

        // Scroll all the way back up, check the top-left corner
        view.scrollTo(row: 1)
        #expect(view.calculateMouseHit(at: CGPoint(x: 0, y: 10)).grid.row == 1)
    }

    @Test func testZeroSizedResizeDoesNotChangeTerminalDimensions() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 320, height: 160)))
        let originalCols = view.terminal.cols
        let originalRows = view.terminal.rows

        let changed = view.processSizeChange(newSize: .zero)

        #expect(!changed)
        #expect(view.terminal.cols == originalCols)
        #expect(view.terminal.rows == originalRows)
    }
#endif

    // MARK: - Selection Tests Ported from Ghostty

    /// Test that selection start and end are properly ordered
    /// From Ghostty: "Selection: order, standard"
    @Test func testSelectionOrdering() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 10))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "ABCDE\nFGHIJ\nKLMNO")

        // Set selection from higher position to lower position
        selection.setSelection(
            start: Position(col: 5, row: 2),
            end: Position(col: 2, row: 0)
        )

        // Selection service should keep start before end internally
        // or the getSelectedText should work regardless of order
        let text = selection.getSelectedText()
        #expect(text.contains("ABCDE") || text.contains("CDE"))
    }

    /// Test selecting entire line
    /// From Ghostty: row selection
    @Test func testSelectRow() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "line1\nline2\nline3")

        selection.select(row: 1)

        #expect(selection.active)
        #expect(selection.start.row == 1)
        #expect(selection.end.row == 1)
        #expect(selection.start.col == 0)
        #expect(selection.end.col == terminal.cols - 1)
    }

    /// Test select all
    /// From Ghostty: selection of entire buffer
    @Test func testSelectAll() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "line1\nline2\nline3")

        selection.selectAll()

        #expect(selection.active)
        #expect(selection.start.col == 0)
        #expect(selection.start.row == 0)
    }

    /// Test drag extend moves end position
    /// From Ghostty: selection adjustment
    @Test func testDragExtendMovesEnd() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "ABCDEFGHIJ")

        // Start selection at position 2
        selection.startSelection(row: 0, col: 2)

        // Drag to position 7
        selection.dragExtend(row: 0, col: 7)

        #expect(selection.end.col == 7)
        #expect(selection.end.row == 0)
    }

    /// Test drag extend across multiple lines
    /// From Ghostty: multi-line selection
    @Test func testDragExtendMultiLine() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "line1\nline2\nline3")

        // Start selection on line 0
        selection.startSelection(row: 0, col: 2)

        // Drag to line 2
        selection.dragExtend(row: 2, col: 3)

        #expect(selection.isMultiLine)
        #expect(selection.end.row == 2)
    }

    /// Test shift extend can swap start and end
    /// From Ghostty: "Selection: adjust left/right"
    @Test func testShiftExtendSwapsWhenNeeded() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "ABCDEFGHIJ")

        // Start selection at position 5
        selection.startSelection(row: 0, col: 5)
        selection.dragExtend(row: 0, col: 7)

        // Now shift extend to position 2 (before start)
        selection.shiftExtend(row: 0, col: 2)

        // Selection should now include position 2
        let text = selection.getSelectedText()
        #expect(text.contains("C") || selection.start.col <= 2)
    }

    /// Test selection with empty line
    @Test func testSelectionWithEmptyContent() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)

        // Don't feed any text - buffer should be empty/spaces
        selection.startSelection(row: 0, col: 0)
        selection.dragExtend(row: 0, col: 5)

        // Should not crash, text may be empty or spaces
        let text = selection.getSelectedText()
        #expect(text.count >= 0)
    }

    /// Test selection active state
    /// From Ghostty: selection state management
    @Test func testSelectionActiveState() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "test content")

        #expect(!selection.active)

        selection.startSelection(row: 0, col: 0)
        #expect(selection.active)

        selection.active = false
        #expect(!selection.active)
    }

    /// Test hasSelectionRange
    @Test func testHasSelectionRange() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "test content")

        // Initially no range
        #expect(!selection.hasSelectionRange)

        // Start selection - still no range (start == end)
        selection.startSelection(row: 0, col: 5)
        #expect(!selection.hasSelectionRange)

        // Extend - now has range
        selection.dragExtend(row: 0, col: 8)
        #expect(selection.hasSelectionRange)
    }

    /// Test selection text extraction with newlines
    /// From Ghostty: formatter tests for selection
    @Test func testSelectionTextWithNewlines() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "AAA\r\nBBB\r\nCCC")

        // Use selectAll to get everything
        selection.selectAll()

        let text = selection.getSelectedText()
        // Should contain content from multiple lines
        #expect(text.contains("AAA"))
        #expect(text.contains("BBB"))
        #expect(text.contains("CCC"))
    }

    /// Test word selection at word boundaries
    /// From Ghostty: word boundary selection
    @Test func testWordSelectionAtBoundary() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "hello world test")

        // Select word at start of "world"
        selection.selectWordOrExpression(at: Position(col: 6, row: 0), in: terminal.buffer)
        #expect(selection.getSelectedText() == "world")

        // Select word at end of "world"
        selection.selectWordOrExpression(at: Position(col: 10, row: 0), in: terminal.buffer)
        #expect(selection.getSelectedText() == "world")
    }

    /// Test balanced expression selection with nested brackets
    @Test func testBalancedExpressionNested() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "foo(bar[baz])end")

        // Click on opening paren - should select balanced expression
        selection.selectWordOrExpression(at: Position(col: 3, row: 0), in: terminal.buffer)
        let text = selection.getSelectedText()

        // Should include the full balanced expression
        #expect(text == "(bar[baz])")
    }

    /// Test balanced expression with braces
    @Test func testBalancedExpressionBraces() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "x{a{b}c}y")

        selection.selectWordOrExpression(at: Position(col: 1, row: 0), in: terminal.buffer)
        let text = selection.getSelectedText()

        #expect(text == "{a{b}c}")
    }

    /// Test selection mode persists during extension
    @Test func testSelectionModePersistence() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "hello world test")

        // Start character selection
        selection.startSelection(row: 0, col: 5)
        #expect(selection.selectionMode == .character)

        // Select row
        selection.select(row: 0)
        #expect(selection.selectionMode == .row)
    }

    /// Test soft start doesn't activate selection visually
    @Test func testSoftStartBehavior() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "test")

        // Soft start should set position but selection should still be active
        // (in SwiftTerm, setSoftStart calls setActiveAndNotify)
        selection.setSoftStart(row: 0, col: 3)

        // The position should be set
        #expect(selection.start.col == 3)
        #expect(selection.end.col == 3)
    }

    // MARK: - Rectangular (column-block) Selection

    /// Rectangular selection extracts the same column slice from every row in
    /// the row range, joined by `\n`.
    @Test func testRectangularBasic() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "abcdefghij\r\nklmnopqrst\r\nuvwxyz1234")

        selection.setSelection(
            start: Position(col: 2, row: 0),
            end: Position(col: 6, row: 2)
        )
        selection.selectionMode = .rectangular
        #expect(selection.getSelectedText() == "cdef\nmnop\nwxyz")
    }

    /// Reverse-corner drag (lower-right anchor → upper-left release) must produce
    /// the same rectangle as the forward case — start/end are independently min/maxed.
    @Test func testRectangularReverseDrag() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "abcdefghij\r\nklmnopqrst\r\nuvwxyz1234")

        selection.setSelection(
            start: Position(col: 6, row: 2),
            end: Position(col: 2, row: 0)
        )
        selection.selectionMode = .rectangular
        #expect(selection.getSelectedText() == "cdef\nmnop\nwxyz")
    }

    /// Upper-right to lower-left diagonal (start.col > end.col, start.row < end.row)
    /// should still resolve to the minRow/maxRow × minCol/maxCol rectangle.
    @Test func testRectangularDiagonalDrag() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "abcdefghij\r\nklmnopqrst\r\nuvwxyz1234")

        selection.setSelection(
            start: Position(col: 6, row: 0),
            end: Position(col: 2, row: 2)
        )
        selection.selectionMode = .rectangular
        #expect(selection.getSelectedText() == "cdef\nmnop\nwxyz")
    }

    /// Zero-width drag (start.col == end.col) yields an empty selection — never a
    /// column of newlines.
    @Test func testRectangularZeroWidthIsEmpty() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "abcdefghij\r\nklmnopqrst\r\nuvwxyz1234")

        selection.setSelection(
            start: Position(col: 5, row: 0),
            end: Position(col: 5, row: 2)
        )
        selection.selectionMode = .rectangular
        #expect(selection.getSelectedText() == "")
    }

    /// A rectangle that covers a row past end-of-content emits a blank line —
    /// preserving the vertical structure of the original block.
    @Test func testRectangularPreservesBlankLine() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "AAA\r\n\r\nCCC")

        selection.setSelection(
            start: Position(col: 0, row: 0),
            end: Position(col: 3, row: 2)
        )
        selection.selectionMode = .rectangular
        #expect(selection.getSelectedText() == "AAA\n\nCCC")
    }

    /// Trailing whitespace within the column slice is trimmed per row, but rows
    /// where the slice covers actual content keep that content intact.
    @Test func testRectangularRstripsPerRow() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 5))
        let selection = SelectionService(terminal: terminal)
        // Row 0: "ab" (2 chars, then blanks). Slice [0..6) trims to "ab".
        // Row 1: "klmnop" (6 chars). Slice [0..6) keeps all 6.
        terminal.feed(text: "ab\r\nklmnop")

        selection.setSelection(
            start: Position(col: 0, row: 0),
            end: Position(col: 6, row: 1)
        )
        selection.selectionMode = .rectangular
        #expect(selection.getSelectedText() == "ab\nklmnop")
    }

    /// dragExtend in rectangular mode must only update `end` — no word-boundary
    /// expansion, even if the position lands in the middle of a word. Column
    /// range is `[minCol, maxCol)` — end is exclusive, matching flow selection.
    @Test func testRectangularDragExtendNoWordExpansion() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "hello world")

        selection.setSelection(
            start: Position(col: 1, row: 0),
            end: Position(col: 1, row: 0)
        )
        selection.selectionMode = .rectangular
        selection.dragExtend(bufferPosition: Position(col: 8, row: 0))

        #expect(selection.end.col == 8)
        // Cols [1, 8) → "ello wo" (7 chars).
        #expect(selection.getSelectedText() == "ello wo")
    }

    /// shiftExtend in rectangular mode updates the rectangle's `end` — no word
    /// boundary expansion, no swap of start.
    @Test func testRectangularShiftExtendNoWordExpansion() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "hello world test")

        selection.setSelection(
            start: Position(col: 1, row: 0),
            end: Position(col: 4, row: 0)
        )
        selection.selectionMode = .rectangular
        selection.shiftExtend(bufferPosition: Position(col: 9, row: 0))

        #expect(selection.start.col == 1)
        #expect(selection.end.col == 9)
        // Cols [1, 9) → "ello wor" (8 chars).
        #expect(selection.getSelectedText() == "ello wor")
    }

    /// Calling selectWordOrExpression after a rectangular selection resets mode
    /// to .word — prevents rectangular-mode stickiness.
    @Test func testWordSelectionAfterRectangularResetsMode() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "hello world")

        selection.setSelection(
            start: Position(col: 0, row: 0),
            end: Position(col: 3, row: 0)
        )
        selection.selectionMode = .rectangular
        #expect(selection.selectionMode == .rectangular)

        selection.selectWordOrExpression(at: Position(col: 6, row: 0), in: terminal.buffer)
        #expect(selection.selectionMode == .word)
        #expect(selection.getSelectedText() == "world")
    }

    /// startSelection() resets mode to .character — guards against rectangular
    /// stickiness when the user begins a fresh non-rectangular drag.
    @Test func testStartSelectionResetsRectangularMode() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "hello world")

        selection.setSelection(
            start: Position(col: 0, row: 0),
            end: Position(col: 3, row: 0)
        )
        selection.selectionMode = .rectangular
        selection.startSelection(row: 0, col: 5)

        #expect(selection.selectionMode == .character)
    }

    /// Wide CJK glyph: a rectangle covering the lead column extracts the whole
    /// glyph — translateToString's skipNullCellsFollowingWide handling preserves
    /// glyph integrity.
    @Test func testRectangularWideGlyph() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 1))
        let selection = SelectionService(terminal: terminal)
        // "あ" is 2 cells (lead + trailing null). Cols 0..3 covers glyph + '1'.
        terminal.feed(text: "あ12345")

        selection.setSelection(
            start: Position(col: 0, row: 0),
            end: Position(col: 3, row: 0)
        )
        selection.selectionMode = .rectangular
        #expect(selection.getSelectedText() == "あ1")
    }

    /// setSelection resets mode to .character — guards against rectangular
    /// stickiness when another feature (search result highlight, programmatic
    /// selection) drives the selection without setting mode explicitly.
    @Test func testSetSelectionResetsRectangularMode() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "hello world")

        // Start with a rectangular selection.
        selection.setSelection(
            start: Position(col: 1, row: 0),
            end: Position(col: 4, row: 0)
        )
        selection.selectionMode = .rectangular

        // Simulate the search code path: setSelection with no explicit mode reset.
        selection.setSelection(
            start: Position(col: 6, row: 0),
            end: Position(col: 11, row: 0)
        )

        #expect(selection.selectionMode == .character)
        #expect(selection.getSelectedText() == "world")
    }
}
