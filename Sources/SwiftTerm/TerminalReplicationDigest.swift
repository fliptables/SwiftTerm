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
        "respondsToQueries": "the replica's role, not emulator state",
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
        "tdel": "delegate",
        "curStyleID": "storage identity of curAttr",
        "currentEraseBlankCell": "storage identity of the erase attribute",
        "currentEraseSpaceCell": "storage identity of the erase attribute",
        "parser": "compared as pendingParserBytes",
        "readingBuffer": "compared as pendingParserBytes",
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
        "payloadCodes": "atom identity (payloads are compared by target)",
        "silentLog": "logging",
        "reportedVisibility": "host visibility",
        "pixelGeometry": "host geometry",
        "kittyClipboardProtocol": "not carried: clipboard transactions",
        "kittyClipboardTokenGenerator": "clipboard plumbing",
        "kittyClipboardClock": "clipboard plumbing",
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
    ]

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
    ]

    /// One line per compared fact, `path = value`, in a stable order. Two
    /// terminals in the same state give equal digests. Call under
    /// `terminalLock`, between feeds.
    @_spi(Replication)
    public func replicationDigest() -> [String] {
        var out: [String] = []
        let mirror = Mirror(reflecting: self)
        for child in mirror.children {
            guard let label = child.label,
                  Terminal.digestExcludedTerminalProperties[label] == nil else { continue }
            out.append("terminal.\(label) = \(DigestDescriber.describe(child.value))")
        }
        out.append("terminal.altActive = \(isCurrentBufferAlternate)")
        out.append("terminal.activeHyperlink = \(describeActiveHyperlink())")
        out.append("terminal.pendingParserBytes = \(pendingParserBytes.map { $0.map(String.init).joined(separator: ",") } ?? "overflow")")
        Terminal.digest(buffer: normalBuffer, name: "normal", into: &out)
        Terminal.digest(buffer: altBuffer, name: "alt", into: &out)
        return out
    }

    private func describeActiveHyperlink() -> String {
        switch activeHyperlink {
        case nil: return "none"
        case .pending(let payload): return "open(\(payload))"
        case .resolved(let atom): return "open(\(atom.target as? String ?? "?"))"
        case .unavailable: return "unavailable"
        }
    }

    private static func digest(buffer: Buffer, name: String, into out: inout [String]) {
        for child in Mirror(reflecting: buffer).children {
            guard let label = child.label, digestExcludedBufferProperties[label] == nil else { continue }
            out.append("\(name).\(label) = \(DigestDescriber.describe(child.value))")
        }
        let startRow = buffer.semanticPromptStartLine.flatMap { buffer.absoluteRow(of: $0) }
        out.append("\(name).semanticPromptStartRow = \(startRow.map(String.init) ?? "nil")")
        out.append("\(name).lines.count = \(buffer.lines.count)")
        for row in 0..<buffer.lines.count {
            let line = buffer.lines[row]
            var parts: [String] = []
            for child in Mirror(reflecting: line).children {
                guard let label = child.label, digestExcludedLineProperties[label] == nil else { continue }
                parts.append("\(label)=\(DigestDescriber.describe(child.value))")
            }
            parts.append("cols=\(line.count)")
            parts.append("tail=\(line.replicationTailAttribute)")
            out.append("\(name).line[\(row)] \(parts.joined(separator: " "))")
            var cells: [String] = []
            cells.reserveCapacity(line.count)
            for column in 0..<line.count {
                let data = line[column]
                let payload: String
                if data.payload.code == 0 {
                    payload = ""
                } else {
                    payload = data.payload.target as? String ?? "<non-string>"
                }
                cells.append("\(data.getText().unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "+"))/\(data.width)/\(data.packedWidthStateCode)/\(data.attribute)/\(payload)/\(data.semanticContent)/\(data.isProtected)")
            }
            out.append("\(name).line[\(row)].cells \(cells.joined(separator: "|"))")
        }
    }
}

/// Describes a value by reflection, sorting unordered collections so equal
/// states describe equally.
enum DigestDescriber {
    static func describe(_ value: Any, depth: Int = 0) -> String {
        if depth > 8 { return "…" }
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
