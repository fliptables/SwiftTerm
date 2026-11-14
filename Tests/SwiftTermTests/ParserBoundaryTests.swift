#if !os(iOS) && !os(Windows)
import Testing
@_spi(Replication) @testable import SwiftTerm

/// IT-2001 D4: the parser-boundary streams, one per contract clause of the
/// former sequence-boundary hook. Under ruling (B), export only at ground, the
/// hook is gone and the parser is upstream's; these streams are kept as cut
/// cases for ExportAtGroundTests (every cut, every two-batch split): a cut
/// inside a sequence exports nil, a ground cut exports and replicates.
enum ParserBoundaryTests {
    private static func u(_ text: String) -> [UInt8] { Array(text.utf8) }

    static let clauses: [(String, [UInt8])] = [
        ("whole CSI sequences, consumed > 1",
         u("a\u{1b}[1;31mred\u{1b}[0m\u{1b}[2;5Hx\u{1b}[K\u{1b}[?25l\u{1b}[?25h")),
        ("CSI digits split across feeds",
         u("\u{1b}[12;34Hy\u{1b}[38;5;123mz\u{1b}[48:2::10:20:30mw")),
        // U+20AC and U+0100 have continuation bytes 0x82 and 0x80, which the
        // table alone would take for C1 controls.
        ("OSC continuation bytes at a batch start",
         u("\u{1b}]2;€Ā€\u{07}t\u{1b}]2;Ā€\u{1b}\\")),
        ("APC continuation bytes at a batch start",
         u("\u{1b}_X€Ā€\u{1b}\\a\u{1b}_YĀ€\u{1b}\\b")),
        ("C0 inside CSI", u("\u{1b}[3\r1mA\u{1b}[2\n;4HB\u{1b}[\u{08}5CC")),
        ("C0 inside OSC", u("\u{1b}]2;ab\u{08}cd\u{07}\u{1b}]2;e\u{0e}f\u{1b}\\g")),
        ("RIS mid-sequence", u("x\u{1b}[3;\u{1b}c\u{1b}[5mA\u{1b}]2;t\u{1b}cB\u{1b}[1")),
        ("OSC 7501, well-formed ST", u("a\u{1b}]7501;state=working\u{1b}\\b\u{1b}]7501;state=done:id=r\u{1b}\\c")),
        ("OSC 7501, malformed terminator (zero-byte transition)",
         u("a\u{1b}]7501;state=working\u{1b}7b\u{1b}]7501;state=x\u{1b}[1mc\u{1b}]7501;s\u{1b}\u{1b}\\d")),
    ]
}
#endif
