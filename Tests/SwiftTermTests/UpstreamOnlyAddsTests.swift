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
        // D8: a replica answers no query; user input still goes through.
        Allowed(file: "Sources/SwiftTerm/Terminal.swift", line: 3540, hash: "b1a7013e",
                reason: "D8: the semantic-prompt click is user input, so it must leave the gated sendResponse family for sendUserInputBytes; offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Terminal.swift", line: 7936, hash: "05801985",
                reason: "D8: sendResponse(_ bytes:) is a one-line body, so no guard line can be added before its send; it calls the gated sendQueryResponse; offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Terminal.swift", line: 9370, hash: "da96931e",
                reason: "D8: sendEvent's mouse packet is user input, so it must leave the gated sendResponse(_ bytes:) for sendUserInputBytes; offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Terminal.swift", line: 9371, hash: "e67cdf79",
                reason: "D8: second line of the same sendEvent call (mouse packet = user input); offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Terminal.swift", line: 9388, hash: "f6bd462a",
                reason: "D8: sendMousePacket's packet is user input, so it must leave the gated sendResponse(_ bytes:) for sendUserInputBytes; offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Terminal.swift", line: 9389, hash: "bae653ab",
                reason: "D8: second line of the same sendMousePacket call (mouse packet = user input); offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Terminal.swift", line: 9390, hash: "6d031297",
                reason: "D8: third line of the same sendMousePacket call (mouse packet = user input); offered upstream: IT-2023"),

        // D2 (IT-1075): a title rides the frame driver's pending-update tuple
        // instead of one main-queue hop per title (a TUI spinner retitles every
        // frame). With no title pending the frame adds no lock and no allocation.
        Allowed(file: "Sources/SwiftTerm/Apple/AppleTerminalView.swift", line: 2602, hash: "52c361a4",
                reason: "D2: applyPendingViewUpdates' one existing lock also takes the pending title (per frame; no lock or allocation added); offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Apple/AppleTerminalView.swift", line: 2604, hash: "261ce9d5",
                reason: "D2: second line of the same tuple, which gains `state.pendingTitle`; offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Mac/MacTerminalView.swift", line: 3948, hash: "3cc26f57",
                reason: "D2: setTerminalTitle records the latest title for the next frame instead of a main-queue hop per title; offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Mac/MacTerminalView.swift", line: 3949, hash: "4ed13a17",
                reason: "D2: same body (upstream's onMain hop removed); offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Mac/MacTerminalView.swift", line: 3950, hash: "f422eb86",
                reason: "D2: same body (upstream's onMain hop removed); offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Mac/MacTerminalView.swift", line: 3951, hash: "de268967",
                reason: "D2: same body (the delegate is called from applyPendingViewUpdates instead); offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Mac/MacTerminalView.swift", line: 3952, hash: "7ac2ae48",
                reason: "D2: same body (upstream's onMain closure's end); offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/iOS/iOSTerminalView.swift", line: 3833, hash: "3cc26f57",
                reason: "D2: setTerminalTitle records the latest title for the next frame instead of a main-queue hop per title; offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/iOS/iOSTerminalView.swift", line: 3834, hash: "4ed13a17",
                reason: "D2: same body (upstream's onMain hop removed); offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/iOS/iOSTerminalView.swift", line: 3835, hash: "f422eb86",
                reason: "D2: same body (upstream's onMain hop removed); offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/iOS/iOSTerminalView.swift", line: 3836, hash: "de268967",
                reason: "D2: same body (the delegate is called from applyPendingViewUpdates instead); offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/iOS/iOSTerminalView.swift", line: 3837, hash: "7ac2ae48",
                reason: "D2: same body (upstream's onMain closure's end); offered upstream: IT-2023"),

        // Mac view: one access level and one data race.
        Allowed(file: "Sources/SwiftTerm/Mac/MacTerminalView.swift", line: 3606, hash: "6df91429",
                reason: "scrollWheel is `open`, not `public`: Scape overrides it and calls super, and no addition can make a member overridable; offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Mac/MacTerminalView.swift", line: 2908, hash: "c44383af",
                reason: "autoscroll: the active check, hit test and dragExtend run under one terminal lock; upstream's unlocked dragExtend races the IO thread; offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Mac/MacTerminalView.swift", line: 2909, hash: "23c51cf4",
                reason: "autoscroll: same block (calculateMouseHitLocked inside the lock); offered upstream: IT-2023"),
        Allowed(file: "Sources/SwiftTerm/Mac/MacTerminalView.swift", line: 2910, hash: "de866c9d",
                reason: "autoscroll: same block (dragExtend inside the lock); offered upstream: IT-2023"),
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

#if os(macOS)
    /// Scape's view API (TerminalViewScapeAccess.swift) forwards to upstream's
    /// internal members, whose access is upstream's again.
    @MainActor
    @Test func theViewForwardersReachUpstreamsMembers() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        #expect(view.selectionService === view.selection)
        #expect(view.withLockedTerminal { $0.cols } == view.withTerminal { $0.cols })
    }
#endif

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
