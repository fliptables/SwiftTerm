//
//  TerminalReplicationDigest.swift
//
//  An independent comparator for replication tests (IT-1149 T3): a
//  reflective listing of every stored property of the terminal, both buffers
//  and every line, except a named exclusion list. It does not use the
//  snapshot code, so a field the snapshot forgets shows up as a difference;
//  a stored property added to SwiftTerm later is compared automatically.
//

import Foundation

extension Terminal {
    /// Stored properties of `Terminal` the digest leaves out, with the reason.
    /// A test pins that every entry still names a real property.
    @_spi(Replication)
    public static let digestExcludedTerminalProperties: [String: String] = [
        "MINIMUM_COLS": "constant",
        "MINIMUM_ROWS": "constant",
        "terminalLock": "synchronisation",
        "selections": "view selection",
        "activeSelectionCount": "view selection",
        "cellArena": "storage identity (cells are compared by value)",
        "normalBuffer": "compared as a buffer",
        "altBuffer": "compared as a buffer",
        "_buffer": "compared as altActive",
        "synchronizedOutputGeneration": "watchdog counter",
        "synchronizedOutputWatchdogDirty": "watchdog bookkeeping",
        "synchronizedOutputTimeoutItem": "watchdog timer",
        "synchronizedOutputWatchdogCounters": "watchdog diagnostics",
        "synchronizedOutputTimeoutSeconds": "the host's choice of valve, not emulator state",
        "tdel": "delegate",
        "curStyleID": "storage identity of curAttr",
        "currentEraseBlankCell": "storage identity of the erase attribute",
        "currentEraseSpaceCell": "storage identity of the erase attribute",
        "parser": "compared as hasPendingSequence and its state between feeds (export only at ground)",
        "readingBuffer": "compared as hasPendingSequence (export only at ground)",
        "oscEventDispatcher": "observer plumbing",
        "parseDepth": "re-entrancy counter, zero between feeds",
        "hasPendingScrollNotification": "delegate notification bookkeeping",
        "kittyGraphicsState": "not carried: images are lost until redraw",
        "hasKittyPlacements": "not carried: images are lost until redraw",
        "kittyAnimationTimerSerial": "not carried: images are lost until redraw",
        "refreshStart": "render dirty range",
        "refreshEnd": "render dirty range",
        "scrollInvariantRefreshStart": "render dirty range",
        "scrollInvariantRefreshEnd": "render dirty range",
        "userScrolling": "view scroll state",
        "reportedFocusState": "host focus",
        "pressureStage": "pointer input",
        "pressure": "pointer input",
        "primaryPointerPressLocation": "pointer input",
        "lastBufferCol": "unused",
        "semanticScanState": "not carried: input-side scanner",
        "semanticScanInPaste": "not carried: input-side scanner",
        "semanticScanParams": "not carried: input-side scanner",
        "activeHyperlink": "compared by target",
        "silentLog": "logging",
        "reportedVisibility": "host visibility",
        "pixelGeometry": "host geometry",
        "kittyClipboardProtocol": "not carried: clipboard transactions",
        "kittyClipboardTokenGenerator": "clipboard plumbing",
        "kittyClipboardClock": "clipboard plumbing",
        // IT-2001 format v2 census: state no reader of the replica can observe.
        "_options": "the host's configuration: a replica is made with the owner's options (the cursor style an application changes is carried)",
        "defaultCursorStyle": "the host's configuration, fixed at construction",
        "semanticPromptClickBehavior": "the view's choice of click routing, set by the host",
        "installedColors": "the host's palette",
        "defaultAnsiColors": "the host's palette, derived from installedColors",
        "settingFgColor": "re-entrancy guard, false between feeds",
        "settingBgColor": "re-entrancy guard, false between feeds",
        "settingCursorColor": "re-entrancy guard, false between feeds",
        "portableRenderMetadata": "render cache",
        "portableRenderCursor": "render cache",
        "portableRenderCells": "render cache",
        "lineChanges": "render change tracking",
        "payloads": "atom identity, slots and collection thresholds (payloads are compared by target)",
        "tabStopWidth": "always 8: upstream never reads options.tabStopWidth (IT-2023); reset and resize rebuild tab stops from it (setup, resize), so the day upstream honours the option it becomes a construction parameter like scrollback",
        "gcharset": "no parsed byte writes it: 0 at init and at reset, read nowhere",
    ]
    #if DEBUG
    static let debugExcludedTerminalProperties: [String: String] = [
        "testingInsertLineIterations": "test counter, DEBUG only",
        "testingImplicitLinkCandidates": "test counter, DEBUG only",
    ]
    #else
    static let debugExcludedTerminalProperties: [String: String] = [:]
    #endif
    #if os(WASI) && !SWIFTTERM_EMBEDDED
    static let platformExcludedTerminalProperties: [String: String] = ["hostEventQueue": "host callback plumbing"]
    #else
    static let platformExcludedTerminalProperties: [String: String] = [:]
    #endif

    /// Every stored property of `Terminal` the digest leaves out, on this build.
    @_spi(Replication)
    public static var digestExcludedTerminalPropertiesOnThisBuild: [String: String] {
        digestExcludedTerminalProperties.merging(debugExcludedTerminalProperties) { a, _ in a }
            .merging(platformExcludedTerminalProperties) { a, _ in a }
    }

    /// Class-typed stored properties of `Terminal` whose own stored properties the digest
    /// compares, as `holder.property` (plan P3: the digest descends only into named holders).
    @_spi(Replication)
    public static let digestHolders: [String] = ["cold", "reportedOnly"]

    /// Properties of the named holders the digest leaves out, as `holder.property`.
    @_spi(Replication)
    public static let digestExcludedHolderProperties: [String: String] = [
        "cold.respondsToQueries": "the replica's role, not emulator state",
        "cold.synchronizedOutputTimeoutDisabled": "the host's choice of valve, not emulator state",
    ]

    /// Stored properties of `Buffer` the digest leaves out, with the reason.
    @_spi(Replication)
    public static let digestExcludedBufferProperties: [String: String] = [
        "_lines": "compared line by line",
        "cellArena": "storage identity",
        "selfRef": "identity",
        "terminal": "back reference",
        "_linesWithImagesCount": "not carried: images",
        "semanticPromptStartLine": "compared as a row",
        "semanticPromptStartRowCache": "search hint",
        "semanticPromptRowScanCount": "diagnostic counter",
        "xBase": "no parsed byte writes it: 0 at init and in clear(); SwiftTerm has no horizontal scroll",
        "xDisp": "no parsed byte writes it: 0 at init; SwiftTerm has no horizontal scroll",
        "hasScrollback": "derived from scrollback (init, changeHistorySize), which is carried",
    ]

    /// The third census class: construction parameters. No parsed byte writes them, but
    /// import BUILDS the replica's buffers from them, so they are carried and compared: the
    /// replica matches the owner whatever its own options say (the app's viewer replica is
    /// built with app options; a smaller scrollback would silently drop history).
    @_spi(Replication)
    public static let replicationConstructionBufferParameters: [String: String] = [
        "scrollback": "the history capacity import builds each buffer with",
    ]

    /// Every stored property of `Buffer` the digest leaves out, on this build.
    @_spi(Replication)
    public static var digestExcludedBufferPropertiesOnThisBuild: [String: String] {
        #if DEBUG
        digestExcludedBufferProperties.merging(["testingSemanticPromptRowVisits": "test counter, DEBUG only"]) { a, _ in a }
        #else
        digestExcludedBufferProperties
        #endif
    }

    /// Separates the `label=value` parts of a digest line row, so a test can split them.
    @_spi(Replication)
    public static let digestLinePartSeparator = " ¦ "

    /// Stored properties of `BufferLine` the digest leaves out, with the reason.
    @_spi(Replication)
    public static let digestExcludedLineProperties: [String: String] = [
        "renderIdentity": "render cache identity",
        "owningBufferRef": "back reference",
        "recycleGeneration": "storage recycling counter",
        "storage": "compared cell by cell",
        "usedLength": "storage optimisation (cells are compared to the full width)",
        "tailBlankCell": "compared as the tail attribute",
        "imagesValue": "not carried: images",
        "_generation": "render change counter",
        "usedStart": "storage bound (cells are compared to the full width)",
    ]

    /// One line per compared fact, `path = value`, in a stable order. Two
    /// terminals in the same state give equal digests. Call under
    /// `terminalLock`, between feeds.
    @_spi(Replication)
    public func replicationDigest() -> [String] {
        var out: [String] = []
        let excluded = Terminal.digestExcludedTerminalPropertiesOnThisBuild
        for child in Terminal.terminalMirror(self).children {
            guard let label = child.label, excluded[label] == nil else { continue }
            if Terminal.digestHolders.contains(label) {
                for field in Mirror(reflecting: child.value).children {
                    guard let name = field.label else { continue }
                    let path = "\(label).\(name)"
                    guard Terminal.digestExcludedHolderProperties[path] == nil else { continue }
                    out.append("terminal.\(path) = \(DigestDescriber.describe(field.value))")
                }
                continue
            }
            out.append("terminal.\(label) = \(DigestDescriber.describe(child.value))")
        }
        out.append("terminal.altActive = \(isCurrentBufferAlternate)")
        out.append("terminal.activeHyperlink = \(describeActiveHyperlink())")
        out.append("terminal.hasPendingSequence = \(hasPendingSequence)")
        out.append("terminal.parser = \(replicationParserState.joined(separator: "; "))")
        // Attributes are numbered in order of first appearance and listed once at the end, so a
        // cell costs a table lookup instead of a reflective description; two states with equal
        // cells number their attributes identically.
        var attributes = DigestAttributes()
        Terminal.digest(buffer: replicationNormalBuffer, name: "normal", attributes: &attributes, into: &out)
        Terminal.digest(buffer: replicationAltBuffer, name: "alt", attributes: &attributes, into: &out)
        for (index, attribute) in attributes.list.enumerated() {
            out.append("attribute[\(index)] = \(attribute)")
        }
        return out
    }

    /// The mirror of `terminal`'s `Terminal` part: a subclass's mirror lists only the
    /// subclass's own stored properties.
    @_spi(Replication)
    public static func terminalMirror(_ subject: Terminal) -> Mirror {
        var mirror = Mirror(reflecting: subject)
        while mirror.subjectType != Terminal.self, let parent = mirror.superclassMirror { mirror = parent }
        return mirror
    }

    private func describeActiveHyperlink() -> String {
        // A resolved atom with no String target prints as `open(?)`, as before
        // IT-2001 PR A; the snapshot exports `""` for it.
        switch replicationActiveHyperlinkTarget(missingTarget: "?") {
        case nil: return "none"
        case .some(.some(let target)): return "open(\(target))"
        case .some(nil): return "unavailable"
        }
    }

    private static func digest(buffer: Buffer, name: String, attributes: inout DigestAttributes,
                               into out: inout [String]) {
        let excluded = digestExcludedBufferPropertiesOnThisBuild
        for child in Mirror(reflecting: buffer).children {
            guard let label = child.label, excluded[label] == nil else { continue }
            out.append("\(name).\(label) = \(DigestDescriber.describe(child.value))")
        }
        let startRow = buffer.replicationSemanticPromptStartLine.flatMap { buffer.replicationAbsoluteRow(of: $0) }
        out.append("\(name).semanticPromptStartRow = \(startRow.map(String.init) ?? "nil")")
        out.append("\(name).lines.count = \(buffer.replicationLines.count)")
        out.append("\(name).lines.capacity = \(buffer.replicationLines.maxLength)")
        for row in 0..<buffer.replicationLines.count {
            let line = buffer.replicationLines[row]
            var parts: [String] = []
            for child in Mirror(reflecting: line).children {
                guard let label = child.label, digestExcludedLineProperties[label] == nil else { continue }
                parts.append("\(label)=\(DigestDescriber.describe(child.value))")
            }
            parts.append("cols=\(line.count)")
            parts.append("tail=a\(attributes.id(line.replicationTailAttribute))")
            out.append("\(name).line[\(row)] \(parts.joined(separator: Terminal.digestLinePartSeparator))")
            // One cell: its scalars, width, width state, attribute number, hyperlink target,
            // semantic content code and protection, as bytes.
            var cells: [UInt8] = Array("\(name).line[\(row)].cells ".utf8)
            cells.reserveCapacity(cells.count + line.count * 12)
            for column in 0..<line.count {
                let data = line[column]
                if column > 0 { cells.append(0x7c) }
                if let graphemes = data.packedGraphemeScalars {
                    for (i, scalar) in graphemes.enumerated() {
                        if i > 0 { cells.append(0x2b) }
                        DigestAttributes.appendDecimal(UInt64(scalar), to: &cells)
                    }
                } else {
                    DigestAttributes.appendDecimal(UInt64(UInt32(bitPattern: data.code)), to: &cells)
                }
                cells.append(0x2f)
                DigestAttributes.appendDecimal(UInt64(UInt8(bitPattern: data.width)), to: &cells)
                cells.append(0x2f)
                DigestAttributes.appendDecimal(UInt64(data.packedWidthStateCode), to: &cells)
                cells.append(0x2f)
                DigestAttributes.appendDecimal(UInt64(attributes.id(data.attribute)), to: &cells)
                cells.append(0x2f)
                if data.payload.code != 0 {
                    cells.append(contentsOf: Array((data.payload.target as? String ?? "<non-string>").utf8))
                }
                cells.append(0x2f)
                DigestAttributes.appendDecimal(UInt64(CellArena.semanticContentCode(for: data.semanticContent)), to: &cells)
                cells.append(data.isProtected ? 0x50 : 0x2d)
            }
            out.append(String(decoding: cells, as: UTF8.self))
        }
    }
}

/// Numbers attributes in order of first appearance for the digest.
struct DigestAttributes {
    var list: [Attribute] = []
    var index: [Attribute: Int] = [:]

    mutating func id(_ attribute: Attribute) -> Int {
        if let existing = index[attribute] { return existing }
        list.append(attribute)
        index[attribute] = list.count - 1
        return list.count - 1
    }

    static func appendDecimal(_ value: UInt64, to bytes: inout [UInt8]) {
        if value < 10 { bytes.append(0x30 + UInt8(value)); return }
        var digits: [UInt8] = []
        var v = value
        while v > 0 { digits.append(0x30 + UInt8(v % 10)); v /= 10 }
        bytes.append(contentsOf: digits.reversed())
    }
}

/// Describes a value by reflection, sorting unordered collections so equal
/// states describe equally.
enum DigestDescriber {
    /// Written where a value nests deeper than the digest describes. A replication test
    /// fails on any digest line holding it, instead of comparing a truncated value.
    static let depthExceeded = "<digest-depth-exceeded>"

    static func describe(_ value: Any, depth: Int = 0) -> String {
        if depth > 8 { return depthExceeded }
        if let color = value as? Color {
            return "rgb(\(color.red),\(color.green),\(color.blue))"
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            guard let wrapped = mirror.children.first else { return "nil" }
            return describe(wrapped.value, depth: depth + 1)
        case .dictionary, .set:
            let items = mirror.children.map { describe($0.value, depth: depth + 1) }.sorted()
            return "{" + items.joined(separator: ", ") + "}"
        case .collection:
            return "[" + mirror.children.map { describe($0.value, depth: depth + 1) }.joined(separator: ", ") + "]"
        case .struct, .tuple:
            if mirror.children.isEmpty { return String(describing: value) }
            let items = mirror.children.map { "\($0.label ?? "_"):\(describe($0.value, depth: depth + 1))" }
            return "(" + items.joined(separator: " ") + ")"
        default:
            return String(describing: value)
        }
    }
}
