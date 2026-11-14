//
//  ReplicationSourceScanTests.swift
//
//  IT-2001 D3: the replication files reach `Terminal`, `Buffer` and
//  `BufferLine` only through the marked accessor blocks and public API, so
//  their private state keeps its upstream access level and an upstream change
//  to that state shows up at a merge in one place.
//
//  The scan reads the sources as text. It collects every member and nested
//  type that the three classes declare (in their bodies and in extensions of
//  them, at member indentation) without `public` or `open`, outside the
//  accessor blocks. None of those names may appear in the four replication
//  files, except on the closed lists below, each entry with its reason.
//
//  It is a name scan, not a type check: a name that is public on one of the
//  three classes, or declared by an accessor block or by a replication file,
//  is allowed wherever it appears.
//

import Foundation
import Testing

@Suite("Replication source scan (IT-2001 D3)")
struct ReplicationSourceScanTests {
    static let replicationFiles = [
        "TerminalStateSnapshot.swift",
        "TerminalStateSnapshotCoding.swift",
        "TerminalHistoryStreaming.swift",
        "TerminalReplicationDigest.swift",
    ]

    /// Nested types of `Terminal` the replication files name. Naming a type is
    /// not reaching a member (the daemon lead's ruling on PR A). Closed: a
    /// third name fails.
    static let allowedNestedTypes: [String: String] = [
        "MouseProtocolEncoding": "field type of TerminalModesImage; encoded by SnapshotCodec",
        "TerminalConformance": "field type of TerminalModesImage; encoded by SnapshotCodec",
    ]

    /// Accessor-block members allowed to mention `tdel`. Closed: any other
    /// mention of `tdel` in a replication file or an accessor block fails.
    static let allowedTdelMembers: [String: String] = [
        "replicationNotifyBufferActivated":
            "tells the host the active buffer after an import; a notification, carries no bytes toward the child",
        "replicationSetProgramStatusRecords":
            "tells the host the imported program status, as an OSC 7501 does; a notification, carries no bytes toward the child",
    ]

    /// Identifiers in the replication files that are spelled like a non-public
    /// member of the three classes but are not that member. Closed; each
    /// checked by hand.
    static let allowedCollisions: [String: String] = [
        "pack": "TerminalStateSnapshot calls `arena.pack(...)`, CellArena's method (CellStorage.swift), not BufferLine.pack(_:)",
    ]

    struct Declaration {
        let name: String
        let isPublic: Bool
        let isType: Bool
        let inAccessorBlock: Bool
    }

    static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SwiftTermTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources/SwiftTerm")
    }

    static func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: sourcesDirectory, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    static let scopeStart = try! NSRegularExpression(
        pattern: #"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|open|final|internal)\s+)*(?:class|extension)\s+(Terminal|Buffer|BufferLine)\b"#)
    static let memberDeclaration = try! NSRegularExpression(
        pattern: #"^    (?:@\w+(?:\([^)]*\))?\s+)*((?:(?:public|open|private|fileprivate|internal|final|static|class|override|lazy|weak|unowned(?:\(unsafe\))?|nonisolated|mutating|dynamic|required|convenience|indirect|private\(set\)|internal\(set\)|fileprivate\(set\))\s+)*)(var|let|func|enum|struct|class|typealias|actor)\s+`?([A-Za-z_][A-Za-z0-9_]*)"#)
    static let identifier = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)

    static func match(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = regex.firstMatch(in: line, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: line).map { String(line[$0]) } ?? ""
        }
    }

    /// Declarations at member indentation inside `class`/`extension` blocks of
    /// the three classes, with the accessor blocks marked, and every
    /// `tdel` mention inside an accessor block, keyed by its member.
    static func declarations() throws -> (decls: [Declaration], accessorTdel: [(file: String, line: Int, member: String)]) {
        var decls: [Declaration] = []
        var accessorTdel: [(String, Int, String)] = []
        for url in try swiftFiles() where !replicationFiles.contains(url.lastPathComponent) {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            var inScope = false
            var inAccessorBlock = false
            var sawAccessorMark = false
            var currentMember = ""
            for (index, line) in lines.enumerated() {
                if line.hasPrefix("// MARK: - Replication accessors") { sawAccessorMark = true; continue }
                if !inScope {
                    if match(scopeStart, line) != nil {
                        inScope = true
                        inAccessorBlock = sawAccessorMark
                        sawAccessorMark = false
                        currentMember = ""
                    }
                    continue
                }
                if line == "}" { inScope = false; inAccessorBlock = false; continue }
                if let groups = match(memberDeclaration, line) {
                    let modifiers = groups[1]
                    let kind = groups[2]
                    let name = groups[3]
                    let isPublic = modifiers.contains("public") || modifiers.contains("open")
                    let isType = ["enum", "struct", "class", "typealias", "actor"].contains(kind)
                    decls.append(Declaration(name: name, isPublic: isPublic, isType: isType,
                                             inAccessorBlock: inAccessorBlock))
                    currentMember = name
                }
                if inAccessorBlock, codeOnly(line).range(of: #"\btdel\b"#, options: .regularExpression) != nil {
                    accessorTdel.append((url.lastPathComponent, index + 1, currentMember))
                }
            }
        }
        return (decls, accessorTdel)
    }

    /// The line without its `//` comment and with string literal contents
    /// blanked (interpolations included, which is conservative).
    static func codeOnly(_ line: String) -> String {
        var out = ""
        var inString = false
        var previous: Character = " "
        var iterator = line.makeIterator()
        while let c = iterator.next() {
            if !inString && c == "/" && previous == "/" { out.removeLast(); break }
            if c == "\"" && previous != "\\" { inString.toggle(); out.append(c) }
            else if !inString { out.append(c) }
            previous = c
        }
        return out
    }

    @Test func replicationFilesReachTheClassesOnlyThroughAccessorBlocksAndPublicAPI() throws {
        let (decls, _) = try Self.declarations()
        var allowed = Set(decls.filter { $0.isPublic || $0.inAccessorBlock }.map(\.name))
        var declaredByReplication = Set<String>()
        for file in Self.replicationFiles {
            let text = try String(contentsOf: Self.sourcesDirectory.appendingPathComponent(file), encoding: .utf8)
            for line in text.components(separatedBy: "\n") {
                if let groups = Self.match(
                    try NSRegularExpression(pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|static|final|mutating|nonisolated|override|indirect)\s+)*(?:var|let|func|enum|struct|class|case|typealias)\s+`?([A-Za-z_][A-Za-z0-9_]*)"#),
                    line) {
                    declaredByReplication.insert(groups[1])
                }
            }
        }
        allowed.formUnion(declaredByReplication)
        let forbiddenMembers = Set(decls.filter { !$0.isType }.map(\.name)).subtracting(allowed)
        let forbiddenTypes = Set(decls.filter { $0.isType && !$0.isPublic }.map(\.name)).subtracting(allowed)

        #expect(!forbiddenMembers.isEmpty, "the scan found no non-public members: it is not reading the sources")
        var violations: [String] = []
        var usedAllowedTypes = Set<String>()
        for file in Self.replicationFiles {
            let text = try String(contentsOf: Self.sourcesDirectory.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let code = Self.codeOnly(line)
                let range = NSRange(code.startIndex..., in: code)
                for m in Self.identifier.matches(in: code, range: range) {
                    let name = String(code[Range(m.range, in: code)!])
                    if forbiddenTypes.contains(name) {
                        if Self.allowedNestedTypes[name] != nil { usedAllowedTypes.insert(name); continue }
                        violations.append("\(file):\(index + 1): nested type \(name)")
                    } else if forbiddenMembers.contains(name), Self.allowedCollisions[name] == nil {
                        violations.append("\(file):\(index + 1): member \(name)")
                    }
                }
            }
        }
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
        // The closed type list carries no stale entry.
        #expect(usedAllowedTypes == Set(Self.allowedNestedTypes.keys))
    }

    @Test func tdelAppearsOnlyInTheAllowListedAccessor() throws {
        var violations: [String] = []
        for file in Self.replicationFiles {
            let text = try String(contentsOf: Self.sourcesDirectory.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated()
            where Self.codeOnly(line).range(of: #"\btdel\b"#, options: .regularExpression) != nil {
                violations.append("\(file):\(index + 1)")
            }
        }
        let (_, accessorTdel) = try Self.declarations()
        var usedMembers = Set<String>()
        for hit in accessorTdel {
            if Self.allowedTdelMembers[hit.member] != nil { usedMembers.insert(hit.member) }
            else { violations.append("\(hit.file):\(hit.line) in \(hit.member)") }
        }
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
        #expect(usedMembers == Set(Self.allowedTdelMembers.keys))
    }

    /// There are exactly three accessor blocks, one per class.
    @Test func oneAccessorBlockPerClass() throws {
        var count = 0
        for url in try Self.swiftFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            count += text.components(separatedBy: "\n").filter { $0.hasPrefix("// MARK: - Replication accessors") }.count
        }
        #expect(count == 3)
    }
}
