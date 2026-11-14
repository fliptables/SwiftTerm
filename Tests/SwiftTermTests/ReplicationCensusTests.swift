#if !os(iOS) && !os(Windows)
import Testing
@_spi(Replication) @testable import SwiftTerm

/// IT-2001 format v2: the field census. Every stored property that reflection shows on
/// `Terminal` (and in the holders the digest names), `Buffer` and `BufferLine` is either
/// CARRIED by the snapshot or EXCLUDED by the digest with a reason (TerminalReplicationDigest.swift),
/// never both; and every name in either list is a real property (both ways).
///
/// A field is carried when a reader of the replica can observe it: what is drawn, what the
/// next byte does, what a query would answer, what a key at the viewer sends.
///
/// The coverage test proves that each carried field is replicated: the every-cut corpus
/// exercises most of them (the field differs from a fresh terminal's at a cut whose import
/// gave equal digests); the rest each have a hand row. The hand set is computed: a carried
/// field in neither set fails, and so does a hand row the corpus already covers.
final class ReplicationCensusTests {
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    // MARK: The census

    static let carriedTerminal: Set<String> = [
        "programStatusStore", "_cols", "_rows", "synchronizedOutputActive",
        "applicationKeypad", "applicationCursor", "reverseColors", "keyboardModeNormal", "keyboardModeAlt",
        "sendFocus", "_currentBidiState", "bidiArrowKeySwap", "savedPrivateModes", "cursorHidden",
        "originMode", "marginMode", "insertMode", "keyboardActionMode", "sendReceiveMode",
        "backarrowKeyMode", "characterProtectionMode", "characterProtection", "wraparound",
        "bracketedPasteMode", "alternateScrollMode", "colorSchemeUpdatesEnabled", "colorScheme",
        "charset", "gCharsets", "reverseWraparound", "reverseWraparoundExtended",
        "curAttr", "currentEraseAttribute", "gLevel", "cursorBlink", "allow80To132",
        "noClearOnColumnChange", "ansiColors", "cc",
        "hostCurrentDirectory", "hostCurrentDocument", "mouseProtocol", "foregroundColor",
        "backgroundColor", "cursorColor", "mouseMode", "mouseShiftCapture", "xtermTitleSetUtf",
        "xtermTitleSetHex", "xtermTitleQueryUtf", "xtermTitleQueryHex", "conformance",
        "cursorStartsNewGrapheme", "terminalTitle", "iconTitle", "terminalTitleStack",
        "terminalIconStack", "visibilityReportsEnabled", "inBandSizeReportsEnabled",
        "kittyPasteEventsEnabled",
        // CSI 20 h/l (LNM) and CSI ? 4 h/l (DECSCLM) write them; DECRQM answers both.
        "lineFeedMode", "smoothScroll",
        // Named holders: their own properties are listed in carriedHolder.
        "cold", "reportedOnly",
    ]

    static let carriedHolder: Set<String> = [
        "cold.moreFix", "cold.foregroundOverride", "cold.backgroundOverride",
        "reportedOnly.decModes", "reportedOnly.attributeChangeExtent",
    ]

    static let carriedBuffer: Set<String> = [
        "_yDisp", "_x", "_y", "_yBase", "linesTop", "_scrollBottom", "_scrollTop",
        "tabStops", "savedX", "savedY", "savedOriginMode", "savedMarginMode", "savedCharacterProtection",
        "savedPendingWrap", "_marginLeft", "_marginRight", "savedAttr", "savedCharset",
        "_cols", "_rows", "insertMode", "characterProtection", "bulkInsertBlocked",
        "marginMode", "wraparound", "semanticContent", "semanticInput", "semanticClickMode",
        "semanticUsesSpecialCursorKeys", "pendingWrap", "semanticGroupCounter", "activeSemanticGroupID",
        "defaultBidiState",
    ]

    /// The third class (lead 15, 03:17Z): construction parameters. No parsed byte writes
    /// them, but import BUILDS the replica's buffers from them, so they are carried and
    /// digested: the replica matches the owner whatever its own options say.
    static let constructionTerminal: Set<String> = []
    static let constructionBuffer = Set(Terminal.replicationConstructionBufferParameters.keys)

    static let carriedLine: Set<String> = [
        "isWrappedValue", "bidiStateValue", "renderModeValue", "semanticMarksValue",
        "semanticHardContinuationGroupValue",
    ]

    static func reflectedHolderPaths(_ terminal: Terminal) -> [String] {
        var paths: [String] = []
        for child in Terminal.terminalMirror(terminal).children {
            guard let label = child.label, Terminal.digestHolders.contains(label) else { continue }
            for field in Mirror(reflecting: child.value).children {
                if let name = field.label { paths.append("\(label).\(name)") }
            }
        }
        return paths
    }

    private static func check(_ what: String, reflected: [String], carried: Set<String>, excluded: Set<String>,
                              construction: Set<String> = []) {
        let names = Set(reflected)
        #expect(names.count == reflected.count, "\(what): a label appears twice")
        #expect(carried.isDisjoint(with: excluded), "\(what) both carried and excluded: \(carried.intersection(excluded).sorted())")
        #expect(construction.isDisjoint(with: excluded), "\(what) both construction and excluded: \(construction.intersection(excluded).sorted())")
        #expect(construction.isDisjoint(with: carried), "\(what) both construction and carried: \(construction.intersection(carried).sorted())")
        let missing = names.subtracting(carried).subtracting(excluded).subtracting(construction)
        #expect(missing.isEmpty, "\(what) neither carried nor excluded: \(missing.sorted())")
        let stale = carried.union(excluded).union(construction).subtracting(names)
        #expect(stale.isEmpty, "\(what) census names that are not stored properties: \(stale.sorted())")
    }

    @Test func theCensusClassifiesEveryStoredPropertyBothWays() {
        let terminal = Terminal(delegate: Sink())
        let mirror = Terminal.terminalMirror(terminal)
        Self.check("Terminal", reflected: mirror.children.compactMap(\.label), carried: Self.carriedTerminal,
                   excluded: Set(Terminal.digestExcludedTerminalPropertiesOnThisBuild.keys),
                   construction: Self.constructionTerminal)
        Self.check("holders", reflected: Self.reflectedHolderPaths(terminal), carried: Self.carriedHolder,
                   excluded: Set(Terminal.digestExcludedHolderProperties.keys))
        Self.check("Buffer", reflected: Mirror(reflecting: terminal.buffer).children.compactMap(\.label),
                   carried: Self.carriedBuffer, excluded: Set(Terminal.digestExcludedBufferPropertiesOnThisBuild.keys),
                   construction: Self.constructionBuffer)
        Self.check("BufferLine", reflected: Mirror(reflecting: terminal.buffer.lines[0]).children.compactMap(\.label),
                   carried: Self.carriedLine, excluded: Set(Terminal.digestExcludedLineProperties.keys))
        // A named holder must be there, as a class instance, when the digest reflects it.
        for holder in Terminal.digestHolders {
            let value = mirror.children.first { $0.label == holder }?.value
            #expect(value.map { Mirror(reflecting: $0).displayStyle == .class } == true, "holder \(holder) is missing or not a class")
        }
    }

    // MARK: Coverage

    /// The digest's per-field lines as `census path -> values`. Buffer and line values carry
    /// their buffer's name, so a field that differs only on the alternate screen counts.
    static func fields(_ digest: [String]) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for line in digest {
            if line.hasPrefix("terminal.") {
                guard let eq = line.range(of: " = ") else { continue }
                out["terminal." + line[line.index(line.startIndex, offsetBy: 9)..<eq.lowerBound], default: []]
                    .insert(String(line[eq.upperBound...]))
                continue
            }
            for buffer in ["normal", "alt"] where line.hasPrefix(buffer + ".") {
                let rest = line.dropFirst(buffer.count + 1)
                if rest.hasPrefix("line[") {
                    guard !rest.contains("].cells "), let space = rest.firstIndex(of: " ") else { break }
                    for part in rest[rest.index(after: space)...].components(separatedBy: Terminal.digestLinePartSeparator) {
                        guard let eq = part.firstIndex(of: "=") else { continue }
                        out["line." + part[..<eq], default: []].insert(buffer + ":" + part[part.index(after: eq)...])
                    }
                } else if let eq = rest.range(of: " = ") {
                    out["buffer." + rest[..<eq.lowerBound], default: []].insert(buffer + ":" + rest[eq.upperBound...])
                }
            }
        }
        return out
    }

    static var carriedPaths: Set<String> {
        Set(carriedTerminal.subtracting(Terminal.digestHolders).map { "terminal." + $0 })
            .union(carriedHolder.map { "terminal." + $0 })
            .union(carriedBuffer.map { "buffer." + $0 })
            .union(carriedLine.map { "line." + $0 })
    }

    /// Terminal holds its delegate weakly: a `Sink()` made inline is gone at once, and then
    /// OSC 6 (isProcessTrusted ?? false) and XTWINOPS (`guard let tdel`) do nothing.
    nonisolated(unsafe) private static let sink = Sink()

    static func fresh() -> Terminal {
        let terminal = Terminal(delegate: Self.sink, options: TerminalOptions(cols: 30, rows: 8, scrollback: 50))
        terminal.synchronizedOutputTimeout = nil
        return terminal
    }

    static func changed(_ terminal: Terminal, against base: [String: Set<String>]) -> Set<String> {
        let now = fields(terminal.replicationDigest())
        return Set(now.keys.filter { now[$0] != base[$0] })
    }

    /// The carried fields the every-cut corpus changes at a cut whose import gave equal digests.
    static func corpusCoverage() -> (covered: Set<String>, failures: [String]) {
        let base = fields(fresh().replicationDigest())
        var covered: Set<String> = []
        var failures: [String] = []
        let streams = TerminalStateSnapshotTests.corpus.map { ($0.0, $0.1) }
            + ParserBoundaryTests.clauses.map { ($0.0, [TerminalStateSnapshotTests.Step.bytes($0.1)]) }
        for (name, steps) in streams {
            if let failure = TerminalStateSnapshotTests.replicate(steps, atEqualSnapshot: { owner in
                covered.formUnion(changed(owner, against: base))
            }) {
                failures.append("\(name): \(failure.prefix(200))")
            }
        }
        return (covered.intersection(carriedPaths), failures)
    }

    private static func b(_ text: String) -> @Sendable (Terminal) -> Void { { $0.feed(text: text) } }

    /// One row per carried field the corpus does not change: how to change it on a fresh terminal.
    static let handRows: [String: @Sendable (Terminal) -> Void] = [
        "terminal.keyboardActionMode": b("\u{1b}[2h"),
        "terminal.sendReceiveMode": b("\u{1b}[12l"),
        "terminal.backarrowKeyMode": b("\u{1b}[?67h"),
        "terminal.characterProtectionMode": b("\u{1b}[1\"q"),
        "terminal.characterProtection": b("\u{1b}[1\"q"),
        "terminal.reverseWraparoundExtended": b("\u{1b}[?1045h"),
        "terminal.noClearOnColumnChange": b("\u{1b}[?95h"),
        "terminal.reportedOnly.decModes": b("\u{1b}[?18h"),
        "terminal.reportedOnly.attributeChangeExtent": b("\u{1b}[2*x"),
        "terminal.cold.moreFix": b("\u{1b}[?41h"),
        "terminal.cold.foregroundOverride": b("\u{1b}]10;rgb:11/22/33\u{7}"),
        "terminal.foregroundColor": b("\u{1b}]10;rgb:11/22/33\u{7}"),
        "terminal.cold.backgroundOverride": b("\u{1b}]11;rgb:44/55/66\u{7}"),
        "terminal.backgroundColor": b("\u{1b}]11;rgb:44/55/66\u{7}"),
        "terminal.cursorColor": b("\u{1b}]12;rgb:77/88/99\u{7}"),
        "buffer.savedPendingWrap": b(String(repeating: "x", count: 30) + "\u{1b}7"),
        "buffer.savedCharacterProtection": b("\u{1b}[1\"q\u{1b}7"),
        "buffer.characterProtection": b("\u{1b}[1\"q"),
        // v1 fields the corpus does not reach
        "buffer.defaultBidiState": b("\u{1b}[?2500h"),
        "terminal._currentBidiState": b("\u{1b}[?2500h"),
        "terminal.bidiArrowKeySwap": b("\u{1b}[?1243h"),
        "buffer.savedAttr": b("\u{1b}[1m\u{1b}7\u{1b}[m"),
        "buffer.savedCharset": b("\u{1b}(0\u{1b}7\u{1b}(B"),
        "buffer.savedMarginMode": b("\u{1b}[?69h\u{1b}7\u{1b}[?69l"),
        "buffer.savedOriginMode": b("\u{1b}[?6h\u{1b}7\u{1b}[?6l"),
        "buffer.semanticUsesSpecialCursorKeys": b("\u{1b}]133;A;special_key=1\u{7}"),
        "buffer.wraparound": b("\u{1b}[?7l"),
        "terminal.wraparound": b("\u{1b}[?7l"),
        "terminal.allow80To132": b("\u{1b}[?40h"),
        "terminal.alternateScrollMode": b("\u{1b}[?1007l"),
        "terminal.cc": b("\u{1b} G"),
        "terminal.colorScheme": { $0.updateColorScheme(.light) },
        "terminal.colorSchemeUpdatesEnabled": b("\u{1b}[?2031h"),
        "terminal.conformance": b("\u{1b}[61\"p"),
        // OSC 6 (oscSetCurrentDocument) needs a trusting delegate: the default isProcessTrusted is true.
        "terminal.hostCurrentDocument": b("\u{1b}]6;file://host/doc\u{7}"),
        "terminal.inBandSizeReportsEnabled": b("\u{1b}[?2048h"),
        "terminal.kittyPasteEventsEnabled": b("\u{1b}[?5522h"),
        "terminal.visibilityReportsEnabled": b("\u{1b}[?2033h"),
        "terminal.mouseShiftCapture": b("\u{1b}[>1s"),
        "terminal.reverseColors": b("\u{1b}[?5h"),
        "terminal.reverseWraparound": b("\u{1b}[?45h"),
        // XTSAVE (cmdSavePrivateModes) saves only modes readDECPrivateMode knows: 2004 is one.
        "terminal.savedPrivateModes": b("\u{1b}[?2004h\u{1b}[?2004s"),
        // terminalIconStack: no hand row since the digest quotes strings (builder #10). The
        // corpus pushes the empty icon title, and [""] used to describe as [] did.
        "terminal.lineFeedMode": b("\u{1b}[20h"),
        "terminal.smoothScroll": b("\u{1b}[?4h"),
        "terminal.xtermTitleSetHex": b("\u{1b}[>0t"),
        "terminal.xtermTitleQueryHex": b("\u{1b}[>1t"),
        "terminal.xtermTitleSetUtf": b("\u{1b}[>2t"),
        "terminal.xtermTitleQueryUtf": b("\u{1b}[>3t"),
    ]

    @Test func everyCarriedFieldIsCoveredByTheCorpusOrOneHandRow() {
        let (covered, failures) = Self.corpusCoverage()
        #expect(failures.isEmpty, "corpus streams that do not replicate: \(failures)")
        let needed = Self.carriedPaths.subtracting(covered)
        let rows = Set(Self.handRows.keys)
        #expect(rows.subtracting(needed).isEmpty, "hand rows the corpus already covers (delete them): \(rows.subtracting(needed).sorted())")
        #expect(needed.subtracting(rows).isEmpty, "carried fields in neither the corpus nor a hand row: \(needed.subtracting(rows).sorted())")
        print("CENSUS carried=\(Self.carriedPaths.count) corpus=\(covered.count) hand=\(rows.count)")
    }

    /// A construction parameter: a replica built with OTHER options (the app's viewer, a
    /// smaller scrollback) gets the owner's after import, and the digest compares it.
    @Test func aConstructionParameterIsTheOwnersAfterImport() throws {
        let owner = Terminal(delegate: Self.sink, options: TerminalOptions(cols: 30, rows: 8, scrollback: 50))
        owner.synchronizedOutputTimeout = nil
        owner.feed(text: (0..<20).map { "line \($0)\r\n" }.joined())
        let replica = Terminal(delegate: Self.sink, options: TerminalOptions(cols: 30, rows: 8, scrollback: 10))
        replica.synchronizedOutputTimeout = nil
        replica.respondsToQueries = false
        let differing = Self.fields(owner.replicationDigest()).filter { Self.fields(replica.replicationDigest())[$0.key] != $0.value }
        #expect(differing["buffer.scrollback"] != nil, "the digest does not compare scrollback")
        replica.importState(try TerminalStateSnapshot(encoded: try #require(owner.exportState()).encoded()))
        #expect(replica.normalBuffer.replicationScrollback == 50)
        #expect(replica.altBuffer.replicationScrollback == owner.altBuffer.replicationScrollback)
        #expect(owner.replicationDigest() == replica.replicationDigest())
    }

    /// tabStopWidth is EXCLUDED, not a construction parameter, because it is 8 on every
    /// terminal: upstream never reads TerminalOptions.tabStopWidth (IT-2023). This pin FAILS
    /// the day upstream honours the option; then tabStopWidth must become a construction
    /// parameter like scrollback (carried, census third class), not stay excluded.
    @Test func tabStopWidthIgnoresTheOptionSoItCarriesNothing() {
        let four = Terminal(delegate: Self.sink, options: TerminalOptions(cols: 30, rows: 8, scrollback: 50, tabStopWidth: 4))
        let eight = Terminal(delegate: Self.sink, options: TerminalOptions(cols: 30, rows: 8, scrollback: 50, tabStopWidth: 8))
        // Read by reflection: the format and its accessors no longer name the field.
        func width(_ terminal: Terminal) -> Int? {
            Terminal.terminalMirror(terminal).children.first { $0.label == "tabStopWidth" }?.value as? Int
        }
        #expect(width(four) == 8 && width(eight) == 8,
                "upstream now honours options.tabStopWidth: reclassify tabStopWidth as a construction parameter")
    }

    /// A hand row changes its field on a fresh terminal (two terminals differing there digest
    /// differently), and export then import makes the replica's digest equal the owner's.
    @Test(arguments: handRows.keys.sorted())
    func aHandRowReplicates(_ path: String) throws {
        let base = Self.fields(Self.fresh().replicationDigest())
        let owner = Self.fresh()
        Self.handRows[path]!(owner)
        #expect(Self.changed(owner, against: base).contains(path), "\(path): the row does not change its field")
        let snapshot = try #require(owner.exportState())
        let replica = Self.fresh()
        replica.respondsToQueries = false
        replica.importState(try TerminalStateSnapshot(encoded: snapshot.encoded()))
        let ownerFields = Self.fields(owner.replicationDigest())
        let replicaFields = Self.fields(replica.replicationDigest())
        #expect(ownerFields[path] == replicaFields[path], "\(path): owner \(ownerFields[path] ?? []) replica \(replicaFields[path] ?? [])")
        #expect(owner.replicationDigest() == replica.replicationDigest(), "\(path): the digests differ elsewhere")
    }
}
#endif
