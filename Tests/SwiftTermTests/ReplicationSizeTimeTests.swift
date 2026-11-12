#if !os(iOS) && !os(Windows)
import Foundation
import Testing
@_spi(Replication) import SwiftTerm

/// IT-1149 T3's budget probe, as the S2 lead restated it: a 200 × 60 screen over 10,000 lines
/// of dense history. (1) The screen part (modes, cursor, the visible grids) must paint in under
/// 50 ms and stay well under 1 MiB; (2) the history streams after it in chunks, with no total
/// cap. It prints and asserts only equality and the size; run it in release for timings:
/// swift test -c release -Xswiftc -enable-testing --filter ReplicationSizeTimeTests
final class ReplicationSizeTimeTests {
    final class Sink: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }

    static func ms(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }

    @Test func screenPartAndHistoryChunksAtTwoHundredBySixty() throws {
        let owner = Terminal(delegate: Sink(), options: TerminalOptions(cols: 200, rows: 60, scrollback: 10_000))
        var text = ""
        for n in 0..<10_060 {
            text += "\u{1b}[\(31 + n % 7)m\(String(format: "%05d", n))\u{1b}[0m "
            text += String(repeating: "abcdefghij", count: 19) + "\u{1b}[1mEND\u{1b}[22m\r\n"
        }
        owner.feed(text: text)

        var best: [String: Double] = [:]
        func record(_ key: String, _ value: Double) { best[key] = min(best[key] ?? .infinity, value) }
        var screenSize = 0, historySize = 0, chunkCount = 0, maxChunk = 0, unsplitSize = 0
        for _ in 0..<5 {
            var t = Date()
            let export = owner.exportForStreaming()
            record("1-underLock(screen+historyCopy)", Self.ms(t))
            t = Date()
            let screenBytes = export.screen.encoded()
            record("2-screenEncode", Self.ms(t))
            screenSize = screenBytes.count
            let replica = Terminal(delegate: Sink(), options: TerminalOptions(cols: 200, rows: 60, scrollback: 10_000))
            replica.respondsToQueries = false
            t = Date()
            replica.importState(try TerminalStateSnapshot(encoded: screenBytes))
            record("3-screenDecodeImport", Self.ms(t))

            t = Date()
            let chunkBytes = export.historyChunks(linesPerChunk: 500).map { $0.encoded() }
            record("4-historyBuildEncode", Self.ms(t))
            historySize = chunkBytes.reduce(0) { $0 + $1.count }
            chunkCount = chunkBytes.count
            maxChunk = chunkBytes.map(\.count).max() ?? 0
            var slowestChunk = 0.0
            for bytes in chunkBytes {
                let c = Date()
                replica.importHistoryChunk(try TerminalHistoryChunk(encoded: bytes))
                slowestChunk = max(slowestChunk, Self.ms(c))
            }
            record("5-slowestChunkDecodeImport", slowestChunk)
            #expect(replica.replicationDigest() == owner.replicationDigest())

            t = Date()
            unsplitSize = owner.exportState().encoded().count
            record("6-unsplitExportEncode", Self.ms(t))
        }
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        let times = best.keys.sorted().map { String(format: "%@=%.1fms", $0, best[$0]!) }.joined(separator: " ")
        print("T3-SIZE-TIME build=\(build) 200x60+10000 produced=\(text.utf8.count) screenPart=\(screenSize) history=\(historySize) chunks=\(chunkCount) maxChunk=\(maxChunk) unsplit=\(unsplitSize) \(times)")
        #expect(screenSize < 1024 * 1024)
    }
}
#endif
