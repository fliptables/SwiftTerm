#if !os(iOS) && !os(Windows)
import Foundation
import Testing
@testable import SwiftTerm

/// IT-2001, lead 14's rule for the fork: THE FORK ONLY ADDS. It never changes
/// or removes a line of a file that exists upstream; what Scape needs is added
/// beside it (a forwarder, an extension, a new file, an added line).
///
/// Why: one changed word (`public var userScrolling`, where upstream says
/// `var userScrolling`) cost about 10% of instructions on every headless
/// scrolling case (whole-fork A/B, 2026-11-13). Added lines can still cost
/// (an added line inside a hot upstream function); the inventory by path heat
/// and the whole-fork A/B guard those. This test guards the other half.
///
/// How, without git or network: `Tests/UpstreamManifest/<commit>.lines` holds
/// one 32-bit FNV-1a hash per line of every upstream file under
/// `Sources/SwiftTerm`, written by `Tools/upstream-manifest.py`. For each
/// file, upstream's hash sequence, less the allow-list's lines, must be a
/// subsequence of the file's lines at HEAD. Pure additions pass.
///
/// After an upstream merge: regenerate the manifest (see the script), point
/// `manifestName` at it, and re-derive the allow-list's line numbers and
/// hashes from the new upstream file (a failure prints both).
final class UpstreamOnlyAddsTests {
    static let manifestName = "d4f52faaa.lines"

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// One upstream line the fork changes or removes, with the reason.
    struct Allowed: Hashable {
        /// Path from the repository root, as in the manifest.
        let file: String
        /// 1-based line number in the upstream file.
        let line: Int
        /// The upstream line's FNV-1a 32 hash, eight hex digits.
        let hash: String
        let reason: String
    }

    /// THE ALLOW-LIST: closed. Each entry is one upstream line the fork changes
    /// or removes, with a one-sentence reason; the lead reads every line. An
    /// entry whose hash no longer matches upstream's line, or whose line the
    /// fork no longer needs to change, fails.
    static let allowList: [Allowed] = [
    ]

    // MARK: the rule

    @Test func everyUpstreamLineIsAtHead() throws {
        let manifest = try Self.loadManifest()
        let byFile = Dictionary(grouping: Self.allowList, by: \.file)
        for unknown in Set(byFile.keys).subtracting(manifest.files.map(\.path)).sorted() {
            Issue.record("allow-list names \(unknown), which is not an upstream file in \(Self.manifestName)")
        }
        for file in manifest.files {
            let url = Self.root.appendingPathComponent(file.path)
            guard let data = try? Data(contentsOf: url) else {
                Issue.record("\(file.path): upstream's file is missing at HEAD (\(file.hashes.count) upstream lines removed)")
                continue
            }
            let head = Self.lineHashes([UInt8](data))
            var allowed = Set<Int>()
            for entry in byFile[file.path] ?? [] {
                let index = entry.line - 1
                guard file.hashes.indices.contains(index),
                      Self.hex(file.hashes[index]) == entry.hash else {
                    let actual = file.hashes.indices.contains(index) ? Self.hex(file.hashes[index]) : "none"
                    Issue.record("\(file.path):\(entry.line): stale allow-list entry: hash \(entry.hash), upstream's line hashes \(actual)")
                    continue
                }
                allowed.insert(index)
            }
            let kept = file.hashes.indices.filter { !allowed.contains($0) }
            let upstream = kept.map { file.hashes[$0] }
            guard !Self.isSubsequence(upstream, of: head) else {
                // Every entry must be needed: with it put back, the file must fail.
                for index in allowed.sorted() {
                    let withEntry = file.hashes.indices.filter { $0 == index || !allowed.contains($0) }
                    if Self.isSubsequence(withEntry.map { file.hashes[$0] }, of: head) {
                        Issue.record("\(file.path):\(index + 1): unneeded allow-list entry: HEAD keeps upstream's line \(Self.hex(file.hashes[index]))")
                    }
                }
                continue
            }
            // Report the fewest upstream lines that are not at HEAD.
            var removed: [(line: Int, hash: UInt32)] = []
            for change in head.difference(from: upstream) {
                if case .remove(let offset, let hash, _) = change {
                    removed.append((kept[offset] + 1, hash))
                }
            }
            let missing = removed.sorted { $0.line < $1.line }
                .map { "\(file.path):\($0.line) \(Self.hex($0.hash))" }
            Issue.record("""
                \(file.path): \(missing.count) upstream line(s) changed or removed at HEAD \
                (upstream \(manifest.upstream.prefix(9)); file:upstream_line hash). Restore upstream's \
                text and add what the fork needs beside it, or bring the case to the lead for the allow-list:
                \(missing.joined(separator: "\n"))
                """)
        }
    }

    // MARK: the manifest and its generator

    @Test func theManifestIsTheGeneratorsOutput() throws {
        let manifest = try Self.loadManifest()
        let script = try Data(contentsOf: Self.root.appendingPathComponent("Tools/upstream-manifest.py"))
        #expect(manifest.generatorSHA256 == SHA256Hex.hash([UInt8](script)),
                "Tools/upstream-manifest.py changed since it wrote \(Self.manifestName): run it again (`write`)")
        #expect(manifest.upstream.hasPrefix(String(Self.manifestName.prefix(9))))
        #expect(manifest.files.contains { $0.path == "Sources/SwiftTerm/Terminal.swift" })
        #expect(manifest.files.allSatisfy { $0.path.hasPrefix("Sources/SwiftTerm/") })
    }

    @Test func theHashIsFNV1a32() {
        #expect(Self.fnv1a32([]) == 0x811c_9dc5)
        #expect(Self.fnv1a32(Array("a".utf8)) == 0xe40c_292c)
        #expect(Self.fnv1a32(Array("foobar".utf8)) == 0xbf9c_f968)
    }

    @Test func theAllowListIsWellFormed() {
        let keys = Self.allowList.map { "\($0.file):\($0.line)" }
        #expect(Set(keys).count == keys.count, "duplicate allow-list entries")
        for entry in Self.allowList {
            #expect(entry.line >= 1 && entry.hash.count == 8, "\(entry.file):\(entry.line)")
            #expect(!entry.reason.isEmpty, "\(entry.file):\(entry.line) has no reason")
        }
    }

    @Test func theSubsequenceCheckAcceptsAdditionsOnly() {
        #expect(Self.isSubsequence([1, 2, 3], of: [1, 9, 2, 9, 3]))
        #expect(Self.isSubsequence([], of: [4]))
        #expect(!Self.isSubsequence([1, 2, 3], of: [1, 3]))
        #expect(!Self.isSubsequence([1, 2, 3], of: [1, 3, 2]))
    }

    // MARK: Scape's forwarders beside upstream's declarations

    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// Upstream declares `var userScrolling`; Scape reads `isUserScrolling`.
    @Test func isUserScrollingForwardsBothWays() {
        let terminal = Terminal(delegate: Sink())
        #expect(!terminal.isUserScrolling)
        terminal.isUserScrolling = true
        #expect(terminal.userScrolling)
        terminal.userScrolling = false
        #expect(!terminal.isUserScrolling)
    }

    // MARK: helpers

    struct ManifestFile {
        let path: String
        let hashes: [UInt32]
    }

    struct Manifest {
        let upstream: String
        let generatorSHA256: String
        let files: [ManifestFile]
    }

    static func loadManifest() throws -> Manifest {
        let url = root.appendingPathComponent("Tests/UpstreamManifest").appendingPathComponent(manifestName)
        let text = try String(contentsOf: url, encoding: .utf8)
        var upstream = "", generator = ""
        var files: [ManifestFile] = []
        var path: String?
        var expected = 0
        var hashes: [UInt32] = []
        func finish() {
            if let path {
                #expect(hashes.count == expected, "\(manifestName): \(path) has \(hashes.count) hashes, header says \(expected)")
                files.append(ManifestFile(path: path, hashes: hashes))
            }
        }
        for row in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if row.hasPrefix("# upstream ") {
                upstream = String(row.dropFirst("# upstream ".count))
            } else if row.hasPrefix("# generator ") {
                generator = String(row.split(separator: " ").last ?? "")
            } else if row.hasPrefix("#") {
                continue
            } else if row.hasPrefix("= ") {
                finish()
                let fields = row.dropFirst(2).split(separator: " ")
                path = String(fields[0])
                expected = Int(fields[1]) ?? -1
                hashes = []
            } else {
                for field in row.split(separator: " ") {
                    hashes.append(try #require(UInt32(field, radix: 16), "bad hash \(field)"))
                }
            }
        }
        finish()
        try #require(!files.isEmpty, "\(manifestName) lists no files")
        return Manifest(upstream: upstream, generatorSHA256: generator, files: files)
    }

    static func fnv1a32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var value: UInt32 = 0x811c_9dc5
        for byte in bytes {
            value ^= UInt32(byte)
            value = value &* 0x0100_0193
        }
        return value
    }

    /// The file's bytes split on LF, as the generator splits them.
    static func lineHashes(_ bytes: [UInt8]) -> [UInt32] {
        bytes.split(separator: 0x0a, omittingEmptySubsequences: false).map { fnv1a32($0) }
    }

    /// Greedy matching answers "is `a` a subsequence of `b`" exactly.
    static func isSubsequence(_ a: [UInt32], of b: [UInt32]) -> Bool {
        var next = a.startIndex
        for value in b where next < a.endIndex && a[next] == value {
            next += 1
        }
        return next == a.endIndex
    }

    static func hex(_ value: UInt32) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 8 - digits.count) + digits
    }
}
#endif
