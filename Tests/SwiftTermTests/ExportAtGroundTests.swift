#if !os(iOS) && !os(Windows)
import Foundation
import Testing
@_spi(Replication) @testable import SwiftTerm

/// IT-2001 D4, lead 14's ruling (B), 2026-11-13: export only at ground.
///
/// The parser is upstream's, byte for byte: it records nothing for replication.
/// `exportState()` and `exportForStreaming()` return nil ("wait") whenever
/// ``Terminal/hasPendingSequence`` is true: the parser is inside a sequence,
/// or a cut UTF-8 character is held. Otherwise they export, and the snapshot's
/// pending field is empty. A nil export changes nothing; the next feed that
/// returns the parser to ground ends the wait.
///
/// The whole-digest comparison at every ground cut is
/// `TerminalStateSnapshotTests.everyCutReplicates` (same corpus). This suite
/// compares what the rule decides: nil or not, the parser state, and the
/// replica's silence.
final class ExportAtGroundTests {
    private final class Capture: TerminalDelegate {
        var sent: [UInt8] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    }

    private static func make(_ capture: Capture, responds: Bool) -> Terminal {
        let terminal = Terminal(delegate: capture, options: TerminalOptions(cols: 30, rows: 8, scrollback: 50))
        terminal.respondsToQueries = responds
        terminal.synchronizedOutputTimeout = nil
        return terminal
    }

    private static func u(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// The clause streams, the corpus (resizes left out: they do not touch the
    /// parser), and printed UTF-8 characters, so that a cut can fall inside a
    /// character while the parser is in ground.
    static let streams: [(String, [UInt8], splitEverywhere: Bool)] =
        ParserBoundaryTests.clauses.map { ($0.0, $0.1, true) }
        + [("UTF-8 characters printed at ground", u("a€bĀc😀d\u{1b}[1mé\u{1b}[0mあ"), true)]
        + TerminalStateSnapshotTests.corpus.map { name, steps in
            ("corpus: \(name)", steps.flatMap { step -> [UInt8] in
                if case .bytes(let b) = step { return b }
                return []
            }, false)
        }

    /// Every cut, the prefix fed in two batches (every split for the short
    /// streams; one batch and two halves for the corpus).
    @Test(arguments: streams.map(\.0))
    func onlyAGroundCutExports(_ name: String) throws {
        let (_, bytes, everywhere) = Self.streams.first { $0.0 == name }!
        var failures = 0, groundCuts = 0, waitCuts = 0
        for cut in 0...bytes.count where failures < 5 {
            let splits = everywhere ? Array(0...cut) : Array(Set([0, cut / 2]))
            for k in splits where failures < 5 {
                let ownerCapture = Capture()
                let owner = Self.make(ownerCapture, responds: true)
                if k > 0 { owner.feed(byteArray: Array(bytes[0..<k])) }
                if cut > k { owner.feed(byteArray: Array(bytes[k..<cut])) }
                let at = "\(name) cut \(cut) split \(k)"
                if owner.hasPendingSequence {
                    waitCuts += 1
                    let before = owner.replicationDigest()
                    if owner.exportState() != nil {
                        failures += 1
                        Issue.record("\(at): exported while a sequence or character is open: \(owner.replicationParserState)")
                    }
                    if owner.exportForStreaming() != nil {
                        failures += 1
                        Issue.record("\(at): exportForStreaming exported while a sequence or character is open")
                    }
                    if owner.replicationDigest() != before {
                        failures += 1
                        Issue.record("\(at): a nil export changed the terminal")
                    }
                    continue
                }
                groundCuts += 1
                guard let snapshot = owner.exportState() else {
                    failures += 1
                    Issue.record("\(at): a ground cut refused to export")
                    continue
                }
                let replicaCapture = Capture()
                let replica = Self.make(replicaCapture, responds: false)
                replica.importState(try TerminalStateSnapshot(encoded: snapshot.encoded()))
                if replica.replicationParserState != owner.replicationParserState {
                    failures += 1
                    Issue.record("\(at): parser after import \(replica.replicationParserState) vs \(owner.replicationParserState)")
                }
                if cut < bytes.count {
                    owner.feed(byteArray: Array(bytes[cut...]))
                    replica.feed(byteArray: Array(bytes[cut...]))
                }
                if replica.replicationParserState != owner.replicationParserState {
                    failures += 1
                    Issue.record("\(at): parser after the tail \(replica.replicationParserState) vs \(owner.replicationParserState)")
                }
                if !replicaCapture.sent.isEmpty {
                    failures += 1
                    Issue.record("\(at): the replica answered \(replicaCapture.sent)")
                }
            }
        }
        #expect(groundCuts > 0, "\(name): no ground cut")
        if name.hasPrefix("UTF-8") || name.contains("OSC") {
            #expect(waitCuts > 0, "\(name): no cut waited")
        }
    }

    /// 806cb0f's case under (B): an OSC 7501 body ended by ESC leaves the parser
    /// in the status ESC state, waiting for `\`. A cut there exports nil; once
    /// the ST ends the sequence the export succeeds and the replica equals the owner.
    @Test func aCutInTheStatusEscStateWaitsThenReplicates() throws {
        let owner = Self.make(Capture(), responds: true)
        owner.feed(byteArray: Self.u("a\u{1b}]7501;state=working\u{1b}"))
        #expect(owner.replicationParserState.first == "state = programStatusEscape")
        #expect(owner.hasPendingSequence)
        #expect(owner.exportState() == nil)
        #expect(owner.exportForStreaming() == nil)
        owner.feed(byteArray: Self.u("\\b"))
        #expect(!owner.hasPendingSequence)
        let snapshot = try #require(owner.exportState())
        let replica = Self.make(Capture(), responds: false)
        replica.importState(try TerminalStateSnapshot(encoded: snapshot.encoded()))
        #expect(owner.replicationDigest() == replica.replicationDigest())
        owner.feed(byteArray: Self.u("\u{1b}]7501;state=done\u{1b}\\c"))
        replica.feed(byteArray: Self.u("\u{1b}]7501;state=done\u{1b}\\c"))
        #expect(owner.replicationDigest() == replica.replicationDigest())
    }

    /// A character cut at ground: the parser is in ground but the terminal
    /// holds the character's first bytes, so the export waits.
    @Test func aCutUTF8CharacterWaits() throws {
        let owner = Self.make(Capture(), responds: true)
        owner.feed(byteArray: [0x61, 0xe2, 0x82])
        #expect(owner.replicationParserState == ["state = ground"])
        #expect(owner.hasPendingSequence)
        #expect(owner.exportState() == nil)
        #expect(owner.exportForStreaming() == nil)
        owner.feed(byteArray: [0xac, 0x62])
        #expect(!owner.hasPendingSequence)
        #expect(owner.exportState() != nil)
    }

    // MARK: the parser is upstream's

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SwiftTerm")

    /// SHA-256 of `Sources/SwiftTerm/EscapeSequenceParser.swift` at upstream
    /// `d4f52faaa`. The WHOLE file is compared: the fork changes no line of it
    /// (D9's empty-span guard is in ByteRunScanner.swift, not here). A future
    /// upstream merge that changes the parser updates this constant to the new
    /// upstream file's hash, and to nothing else.
    static let upstreamParserSHA256 = "986e60d2cf95f156ad8abf1d34841bd13439fa5c1cf4209317e7eac2a7416045"

    @Test func theParserFileIsUpstreams() throws {
        let data = try Data(contentsOf: Self.sources.appendingPathComponent("EscapeSequenceParser.swift"))
        #expect(SHA256Hex.hash([UInt8](data)) == Self.upstreamParserSHA256,
                "EscapeSequenceParser.swift differs from upstream d4f52faaa's: the parse loop must carry no fork code")
    }

    @Test func theHashIsSHA256() {
        #expect(SHA256Hex.hash([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256Hex.hash(Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

/// A plain SHA-256 (FIPS 180-4), for the source pin; no dependency.
enum SHA256Hex {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var bytes = message
        let bitLength = UInt64(message.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(bytes[b]) << 24 | UInt32(bytes[b + 1]) << 16 | UInt32(bytes[b + 2]) << 8 | UInt32(bytes[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
#endif
