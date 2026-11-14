#if !os(iOS) && !os(Windows)
import Foundation
import Testing
@testable import SwiftTerm

/// IT-2001, lead 14's rule for the fork: the fork only ADDS. It does not change
/// an upstream declaration; what Scape needs is added beside it.
///
/// `userScrolling`: upstream declares `var userScrolling = false` and reads it
/// on the scroll path. The fork's former `public var userScrolling` cost about
/// 10% of instructions on every headless scrolling case (whole-fork A/B,
/// 2026-11-13): a public stored property of an open class keeps a dynamic
/// exclusivity check on each read. Scape reads `isUserScrolling`, a forwarder
/// in the fork's accessor block.
final class UpstreamDeclarationTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SwiftTerm")

    private static func lines(_ file: String) throws -> [String] {
        try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            .components(separatedBy: "\n")
    }

    @Test func userScrollingIsUpstreamsDeclaration() throws {
        let terminal = try Self.lines("Terminal.swift")
        let declarations = terminal.filter {
            $0.range(of: #"\bvar userScrolling\b"#, options: .regularExpression) != nil
        }
        #expect(declarations == ["    var userScrolling = false"],
                "Terminal.userScrolling must keep upstream's declaration: \(declarations)")
        #expect(terminal.contains("    public var isUserScrolling: Bool {"),
                "Scape's public forwarder `isUserScrolling` is missing")
    }

    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    @Test func isUserScrollingForwardsBothWays() {
        let terminal = Terminal(delegate: Sink())
        #expect(!terminal.isUserScrolling)
        terminal.isUserScrolling = true
        #expect(terminal.userScrolling)
        terminal.userScrolling = false
        #expect(!terminal.isUserScrolling)
    }
}
#endif
