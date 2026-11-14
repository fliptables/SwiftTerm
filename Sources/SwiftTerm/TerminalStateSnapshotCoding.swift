//
//  TerminalStateSnapshotCoding.swift
//
//  The binary form of a TerminalStateSnapshot: "STSS", a little-endian
//  UInt32 format version, then the fields in declaration order. Integers are
//  LEB128 varints (signed ones zigzag); attributes and hyperlink targets are
//  written once into tables and cells refer to them by index. Lines carry
//  only their written prefix.
//

import Foundation

/// Why ``TerminalStateSnapshot/init(encoded:)`` refused its input.
public enum TerminalStateSnapshotError: Error, Equatable {
    case badMagic
    case unsupportedVersion(UInt32)
    case truncated
    case invalid(String)
}

struct SnapshotWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func bool(_ value: Bool) { bytes.append(value ? 1 : 0) }
    mutating func uvar(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }
    mutating func uint(_ value: Int) { uvar(UInt64(bitPattern: Int64(value))) }
    mutating func int(_ value: Int) {
        let v = Int64(value)
        uvar(UInt64(bitPattern: (v << 1) ^ (v >> 63)))
    }
    mutating func string(_ value: String) { raw(Array(value.utf8)) }
    mutating func raw(_ value: [UInt8]) {
        uint(value.count)
        bytes.append(contentsOf: value)
    }
    mutating func optional<T>(_ value: T?, _ write: (inout SnapshotWriter, T) -> Void) {
        if let value { bool(true); write(&self, value) } else { bool(false) }
    }
}

struct SnapshotReader {
    let bytes: [UInt8]
    var position = 0

    mutating func u8() throws -> UInt8 {
        guard position < bytes.count else { throw TerminalStateSnapshotError.truncated }
        defer { position += 1 }
        return bytes[position]
    }
    mutating func bool() throws -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        default: throw TerminalStateSnapshotError.invalid("boolean")
        }
    }
    mutating func uvar() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try u8()
            guard shift < 64 else { throw TerminalStateSnapshotError.invalid("varint") }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }
    mutating func uint() throws -> Int {
        let value = Int64(bitPattern: try uvar())
        guard value >= 0, value <= Int64(Int.max) else { throw TerminalStateSnapshotError.invalid("count") }
        return Int(value)
    }
    mutating func int() throws -> Int {
        let raw = try uvar()
        return Int(Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1))))
    }
    mutating func raw() throws -> [UInt8] {
        let count = try uint()
        guard count <= bytes.count - position else { throw TerminalStateSnapshotError.truncated }
        defer { position += count }
        return Array(bytes[position..<(position + count)])
    }
    mutating func string() throws -> String {
        guard let text = String(bytes: try raw(), encoding: .utf8) else {
            throw TerminalStateSnapshotError.invalid("string")
        }
        return text
    }
    mutating func optional<T>(_ read: (inout SnapshotReader) throws -> T) throws -> T? {
        try bool() ? try read(&self) : nil
    }
    /// Bytes not read yet. Every counted unit takes at least one byte, so a count
    /// bounded by this never makes decode allocate more than the input holds.
    var remaining: Int { bytes.count - position }
    mutating func count(max: Int, _ what: String) throws -> Int {
        let value = try uint()
        guard value <= max else { throw TerminalStateSnapshotError.invalid(what) }
        return value
    }
}

// MARK: - Snapshot

extension TerminalStateSnapshot {
    /// The binary form, for a replica of the same build.
    public func encoded() -> [UInt8] {
        var w = SnapshotWriter()
        w.bytes.append(contentsOf: TerminalStateSnapshot.magic)
        withUnsafeBytes(of: TerminalStateSnapshot.formatVersion.littleEndian) { w.bytes.append(contentsOf: $0) }

        var attributes = AttributeTable()
        var payloads = PayloadTable()
        // Cells first into a body, so the tables they fill precede them.
        var body = SnapshotWriter()
        modes.encode(&body, attributes: &attributes)
        normal.encode(&body, attributes: &attributes, payloads: &payloads)
        alt.encode(&body, attributes: &attributes, payloads: &payloads)
        body.uint(droppedPayloadCount)

        w.uint(attributes.list.count)
        for attribute in attributes.list { SnapshotCodec.write(attribute, &w) }
        w.uint(payloads.list.count)
        for payload in payloads.list { w.string(payload) }
        w.bytes.append(contentsOf: body.bytes)
        return w.bytes
    }

    /// Decodes ``encoded()``; refuses another magic number or format version.
    public init(encoded bytes: [UInt8]) throws {
        guard bytes.count >= 8 else { throw TerminalStateSnapshotError.truncated }
        guard Array(bytes[0..<4]) == TerminalStateSnapshot.magic else { throw TerminalStateSnapshotError.badMagic }
        let version = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        guard version == TerminalStateSnapshot.formatVersion else {
            throw TerminalStateSnapshotError.unsupportedVersion(version)
        }
        var r = SnapshotReader(bytes: bytes, position: 8)
        let attributeCount = try r.count(max: r.remaining, "attribute table")
        var attributes: [Attribute] = []
        attributes.reserveCapacity(attributeCount)
        for _ in 0..<attributeCount { attributes.append(try SnapshotCodec.readAttribute(&r)) }
        let payloadCount = try r.count(max: r.remaining, "payload table")
        var payloads: [String] = []
        for _ in 0..<payloadCount { payloads.append(try r.string()) }

        let modes = try TerminalModesImage(&r, attributes: attributes)
        let normal = try BufferImage(&r, attributes: attributes, payloads: payloads)
        let alt = try BufferImage(&r, attributes: attributes, payloads: payloads)
        let dropped = try r.uint()
        guard r.position == bytes.count else { throw TerminalStateSnapshotError.invalid("trailing bytes") }
        self.init(modes: modes, normal: normal, alt: alt, droppedPayloadCount: dropped)
        try validate()
    }

    /// The invariants the exporter guarantees and import relies on unchecked: a stream that
    /// breaks one was corrupted in transit, and must fail here rather than trap at import or
    /// at the next byte fed. Runs before import allocates anything.
    func validate() throws {
        func check(_ condition: Bool, _ what: String) throws {
            guard condition else { throw TerminalStateSnapshotError.invalid(what) }
        }
        // Terminal keeps exactly four G0-G3 sets, and gLevel indexes them.
        try check(modes.gCharsets.count == 4, "charsets")
        try check(modes.gLevel < 4, "gLevel")
        var cells = 0
        for (name, buffer) in [("normal", normal), ("alt", alt)] {
            let cols = buffer.cols, rows = buffer.rows
            let isAlt = name == "alt"
            let active = isAlt ? modes.altActive : !modes.altActive
            // Upstream resizes the alternate buffer on every resize (Terminal.resizeBuffers) and
            // defers only the normal buffer, only while the alternate screen is active (caught up
            // when it is shown again). Observed: normal 30x8 under an alt of 45x14.
            let onModesGrid = cols == modes.cols && rows == modes.rows
            try check(cols > 0 && rows > 0 && (onModesGrid || (!isAlt && modes.altActive)), "\(name) grid")
            try check(buffer.tabStops.count >= cols, "\(name) tab stops")
            try check((buffer.scrollback ?? 0) <= TerminalStateSnapshot.maximumScrollback, "\(name) scrollback")
            try check(buffer.lineCapacity >= rows && buffer.lineCapacity <= (buffer.scrollback ?? 0) + 65535
                      && buffer.lineCapacity >= buffer.lines.count, "\(name) line capacity")
            // The alternate buffer never has scrollback (Terminal setup), so only the normal
            // buffer streams history.
            try check(!isAlt || buffer.scrollback == nil, "\(name) scrollback")
            try check(buffer.pendingHistoryLines == 0 || buffer.scrollback != nil, "\(name) pending history")
            // validate accepts what import produces: a replica that has its screen part but not
            // yet its chunks holds fewer lines than rows (import builds from the lines only, never
            // from pendingHistoryLines), and survives feeds and resizes so (aScreenPart... test).
            // An alternate buffer never activated exports no lines (observed); a normal buffer,
            // or an active alternate one, is never empty.
            try check(!buffer.lines.isEmpty || (isAlt && !active), "\(name) lines")
            // A resize without reflow leaves lines wider than the grid; a narrower one trips
            // Buffer.resize's post-condition (fatalError) at the next resize.
            try check(buffer.lines.allSatisfy { $0.cols >= cols }, "\(name) line width")
            try check(buffer.x >= 0 && buffer.x <= cols && buffer.savedX >= 0 && buffer.savedX <= cols, "\(name) column")
            try check(buffer.y >= 0 && buffer.y < rows, "\(name) row")
            // savedY is not kept inside the grid by a resize (observed -3 after a resize
            // smaller); restore clamps it to 0..<rows (Terminal.restoreCursor). Do not tighten
            // it to the grid. Its other readers do plain arithmetic with operands below 2^25
            // (Terminal.resizeBuffers savedY - y, Buffer.resize savedY - amountToTrim, reflow
            // savedY + linesToAdd), so any |savedY| <= Int32.max cannot overflow them.
            try check(buffer.savedY.magnitude <= UInt(Int32.max), "\(name) saved row")
            try check(buffer.scrollTop >= 0 && buffer.scrollTop <= buffer.scrollBottom && buffer.scrollBottom < rows,
                      "\(name) scroll region")
            try check(buffer.marginLeft >= 0 && buffer.marginLeft <= buffer.marginRight && buffer.marginRight < cols,
                      "\(name) margins")
            // The line list indexes modulo its capacity, so a negative row traps. Upstream can
            // hold yBase past lines.count - rows (observed: an alternate buffer grown by a
            // resize, yBase 6 over 14 lines of 14 rows), never past the lines held.
            try check(buffer.yBase >= 0 && buffer.yBase <= buffer.lines.count
                      && buffer.yDisp >= 0 && buffer.yDisp <= buffer.lines.count, "\(name) view")
            // linesTop counts every line ever trimmed, so an honest one is not held to Int32; it
            // is added to (Terminal.swift:8761, :8893, importHistoryChunk) and to row offsets
            // (TerminalContentSnapshot.swift:565-576), so it stays far from Int.max.
            try check(buffer.linesTop >= 0 && buffer.linesTop <= 1 << 62, "\(name) linesTop")
            // What the imported buffer can come to hold with no further input from the stream:
            // every held line widened to at least W = max(cols, modes cols) (a hidden normal
            // buffer is resized to the modes' grid when shown again, and Buffer.resize widens
            // every line), and lineCapacity lines of W as output scrolls or the grid is filled
            // (fillViewportRows at activation). lineCapacity >= rows, so this covers the grid.
            // Widths are <= 65535 and the line count is bounded by the input bytes, but the
            // sums use overflow-reporting forms anyway.
            let widest = max(cols, modes.cols)
            var heldCells = 0
            for line in buffer.lines {
                let (sum, overflow) = heldCells.addingReportingOverflow(max(line.cols, widest))
                try check(!overflow && sum <= TerminalStateSnapshot.maximumCells, "cells")
                heldCells = sum
            }
            let (filled, filledOverflow) = buffer.lineCapacity.multipliedReportingOverflow(by: widest)
            let (sum, overflow) = cells.addingReportingOverflow(max(heldCells, filledOverflow ? Int.max : filled))
            try check(!filledOverflow && !overflow && sum <= TerminalStateSnapshot.maximumCells, "cells")
            cells = sum
        }
    }
}

struct AttributeTable {
    var list: [Attribute] = []
    var index: [Attribute: Int] = [:]
    mutating func id(_ attribute: Attribute) -> Int {
        if let existing = index[attribute] { return existing }
        list.append(attribute)
        index[attribute] = list.count - 1
        return list.count - 1
    }
}

struct PayloadTable {
    var list: [String] = []
    var index: [String: Int] = [:]
    mutating func id(_ payload: String) -> Int {
        if let existing = index[payload] { return existing }
        list.append(payload)
        index[payload] = list.count - 1
        return list.count - 1
    }
}

enum SnapshotCodec {
    static func write(_ color: Attribute.Color, _ w: inout SnapshotWriter) {
        switch color {
        case .ansi256(let code): w.u8(0); w.u8(code)
        case .trueColor(let r, let g, let b): w.u8(1); w.u8(r); w.u8(g); w.u8(b)
        case .defaultColor: w.u8(2)
        case .defaultInvertedColor: w.u8(3)
        }
    }

    static func readColor(_ r: inout SnapshotReader) throws -> Attribute.Color {
        switch try r.u8() {
        case 0: return .ansi256(code: try r.u8())
        case 1: return .trueColor(red: try r.u8(), green: try r.u8(), blue: try r.u8())
        case 2: return .defaultColor
        case 3: return .defaultInvertedColor
        default: throw TerminalStateSnapshotError.invalid("color")
        }
    }

    static func write(_ attribute: Attribute, _ w: inout SnapshotWriter) {
        w.u8(attribute.style.rawValue)
        w.u8(attribute.underlineStyle.rawValue)
        write(attribute.fg, &w)
        write(attribute.bg, &w)
        w.optional(attribute.underlineColor) { w, color in write(color, &w) }
    }

    static func readAttribute(_ r: inout SnapshotReader) throws -> Attribute {
        let style = CharacterStyle(rawValue: try r.u8())
        guard let underline = UnderlineStyle(rawValue: try r.u8()) else {
            throw TerminalStateSnapshotError.invalid("underline style")
        }
        let fg = try readColor(&r)
        let bg = try readColor(&r)
        let underlineColor = try r.optional { try readColor(&$0) }
        return Attribute(fg: fg, bg: bg, style: style, underlineStyle: underline, underlineColor: underlineColor)
    }

    static func attribute(_ r: inout SnapshotReader, _ table: [Attribute]) throws -> Attribute {
        let id = try r.uint()
        guard id < table.count else { throw TerminalStateSnapshotError.invalid("attribute index") }
        return table[id]
    }

    static func write(_ charset: [UInt8: String]?, _ w: inout SnapshotWriter) {
        w.optional(charset) { w, map in
            w.uint(map.count)
            for key in map.keys.sorted() { w.u8(key); w.string(map[key]!) }
        }
    }

    static func readCharset(_ r: inout SnapshotReader) throws -> [UInt8: String]? {
        try r.optional { r in
            let count = try r.count(max: 256, "charset")
            var map: [UInt8: String] = [:]
            for _ in 0..<count { map[try r.u8()] = try r.string() }
            return map
        }
    }

    static func write(_ state: BidiPresentationState, _ w: inout SnapshotWriter) {
        w.bool(state.supportMode == .explicit)
        w.bool(state.autodetectDirection)
        w.bool(state.fallbackDirection == .rightToLeft)
        w.bool(state.boxMirroring)
    }

    static func readBidi(_ r: inout SnapshotReader) throws -> BidiPresentationState {
        BidiPresentationState(supportMode: try r.bool() ? .explicit : .implicit,
                              autodetectDirection: try r.bool(),
                              fallbackDirection: try r.bool() ? .rightToLeft : .leftToRight,
                              boxMirroring: try r.bool())
    }

    static func code(_ kind: SemanticPromptKind) -> UInt8 {
        switch kind {
        case .initial: return 0
        case .right: return 1
        case .continuation: return 2
        case .secondary: return 3
        }
    }

    static func kind(_ code: UInt8) throws -> SemanticPromptKind {
        switch code {
        case 0: return .initial
        case 1: return .right
        case 2: return .continuation
        case 3: return .secondary
        default: throw TerminalStateSnapshotError.invalid("prompt kind")
        }
    }

    static func code(_ mode: Terminal.MouseMode) -> UInt8 {
        switch mode {
        case .off: return 0
        case .x10: return 1
        case .vt200: return 2
        case .buttonEventTracking: return 3
        case .anyEvent: return 4
        }
    }

    static func mouseMode(_ code: UInt8) throws -> Terminal.MouseMode {
        switch code {
        case 0: return .off
        case 1: return .x10
        case 2: return .vt200
        case 3: return .buttonEventTracking
        case 4: return .anyEvent
        default: throw TerminalStateSnapshotError.invalid("mouse mode")
        }
    }

    static func code(_ encoding: Terminal.MouseProtocolEncoding) -> UInt8 {
        switch encoding {
        case .x10: return 0
        case .utf8: return 1
        case .sgr: return 2
        case .urxvt: return 3
        case .sgrPixel: return 4
        }
    }

    static func mouseProtocol(_ code: UInt8) throws -> Terminal.MouseProtocolEncoding {
        switch code {
        case 0: return .x10
        case 1: return .utf8
        case 2: return .sgr
        case 3: return .urxvt
        case 4: return .sgrPixel
        default: throw TerminalStateSnapshotError.invalid("mouse protocol")
        }
    }

    static func code(_ conformance: Terminal.TerminalConformance) -> UInt8 {
        switch conformance {
        case .vt100: return 0
        case .vt200: return 1
        case .vt300: return 2
        case .vt400: return 3
        case .vt500: return 4
        }
    }

    static func conformance(_ code: UInt8) throws -> Terminal.TerminalConformance {
        switch code {
        case 0: return .vt100
        case 1: return .vt200
        case 2: return .vt300
        case 3: return .vt400
        case 4: return .vt500
        default: throw TerminalStateSnapshotError.invalid("conformance")
        }
    }

    static func code(_ state: SemanticInputState) -> UInt8 {
        switch state {
        case .idle: return 0
        case .prompt: return 1
        case .armed: return 2
        case .submitted: return 3
        }
    }

    static func inputState(_ code: UInt8) throws -> SemanticInputState {
        switch code {
        case 0: return .idle
        case 1: return .prompt
        case 2: return .armed
        case 3: return .submitted
        default: throw TerminalStateSnapshotError.invalid("semantic input")
        }
    }

    static func code(_ mode: SemanticPromptClickMode) -> UInt8 {
        switch mode {
        case .none: return 0
        case .clickEventsAbsolute: return 1
        case .clickEventsRelative: return 2
        case .cursorKeys(.line): return 3
        case .cursorKeys(.multiple): return 4
        case .cursorKeys(.conservativeVertical): return 5
        case .cursorKeys(.smartVertical): return 6
        }
    }

    static func clickMode(_ code: UInt8) throws -> SemanticPromptClickMode {
        switch code {
        case 0: return .none
        case 1: return .clickEventsAbsolute
        case 2: return .clickEventsRelative
        case 3: return .cursorKeys(.line)
        case 4: return .cursorKeys(.multiple)
        case 5: return .cursorKeys(.conservativeVertical)
        case 6: return .cursorKeys(.smartVertical)
        default: throw TerminalStateSnapshotError.invalid("click mode")
        }
    }

    static let cursorStyles: [CursorStyle] = CursorStyle.allCases

    static func write(_ record: TerminalProgramStatus, _ w: inout SnapshotWriter) {
        w.string(record.id); w.string(record.state.rawValue)
        w.optional(record.kind) { $0.string($1.rawValue) }
        w.optional(record.progress) { $0.int($1) }
        for text in [record.app, record.effectiveApp, record.title, record.message] {
            w.optional(text) { $0.string($1) }
        }
    }

    static func readProgramStatus(_ r: inout SnapshotReader) throws -> TerminalProgramStatus {
        let id = try r.string()
        guard let state = TerminalProgramStatusState(rawValue: try r.string()) else {
            throw TerminalStateSnapshotError.invalid("program state")
        }
        let kind = try r.optional { r -> TerminalProgramStatusKind in
            guard let kind = TerminalProgramStatusKind(rawValue: try r.string()) else {
                throw TerminalStateSnapshotError.invalid("program status kind")
            }
            return kind
        }
        let progress = try r.optional { try $0.int() }
        var texts: [String?] = []
        for _ in 0..<4 { texts.append(try r.optional { try $0.string() }) }
        return TerminalProgramStatus(id: id, state: state, kind: kind, progress: progress, app: texts[0],
                                     effectiveApp: texts[1], title: texts[2], message: texts[3])
    }
}

// MARK: - Modes

extension TerminalModesImage {
    func encode(_ w: inout SnapshotWriter, attributes: inout AttributeTable) {
        w.uint(cols); w.uint(rows); w.bool(altActive)
        w.string(cursorStyle.tagName)
        w.bool(synchronizedOutputActive)
        w.bool(applicationKeypad); w.bool(applicationCursor); w.bool(reverseColors)
        for kitty in [kittyNormal, kittyAlt] {
            w.int(kitty.flags)
            w.uint(kitty.stack.count)
            for flags in kitty.stack { w.int(flags) }
        }
        w.bool(sendFocus)
        SnapshotCodec.write(currentBidiState, &w)
        w.bool(bidiArrowKeySwap)
        w.uint(savedPrivateModes.count)
        for key in savedPrivateModes.keys.sorted() { w.int(key); w.bool(savedPrivateModes[key]!) }
        w.bool(cursorHidden); w.bool(originMode); w.bool(marginMode); w.bool(insertMode); w.bool(wraparound)
        w.bool(bracketedPasteMode); w.bool(alternateScrollMode); w.bool(colorSchemeUpdatesEnabled)
        w.bool(colorSchemeIsLight)
        SnapshotCodec.write(charset, &w)
        w.uint(gCharsets.count)
        for set in gCharsets { SnapshotCodec.write(set, &w) }
        w.bool(reverseWraparound)
        w.uint(attributes.id(currentAttribute))
        w.u8(gLevel); w.bool(cursorBlink); w.bool(allow80To132); w.bool(lineFeedMode); w.bool(smoothScroll)
        w.uint(paletteOverrides.count)
        for key in paletteOverrides.keys.sorted() {
            let rgb = paletteOverrides[key]!
            w.uint(key); w.uint(Int(rgb.red)); w.uint(Int(rgb.green)); w.uint(Int(rgb.blue))
        }
        w.bool(send8bit)
        w.optional(hostCurrentDirectory) { $0.string($1) }
        w.optional(hostCurrentDocument) { $0.string($1) }
        w.u8(SnapshotCodec.code(mouseProtocol)); w.u8(SnapshotCodec.code(mouseMode))
        w.bool(mouseShiftCapture)
        w.bool(xtermTitleSetUtf); w.bool(xtermTitleSetHex); w.bool(xtermTitleQueryUtf); w.bool(xtermTitleQueryHex)
        w.u8(SnapshotCodec.code(conformance))
        switch activeHyperlink {
        case .none: w.u8(0)
        case .open(let payload): w.u8(1); w.string(payload)
        case .unavailable: w.u8(2)
        }
        w.string(terminalTitle); w.string(iconTitle)
        for stack in [terminalTitleStack, terminalIconStack] {
            w.uint(stack.count)
            for title in stack { w.string(title) }
        }
        w.bool(visibilityReportsEnabled); w.bool(inBandSizeReportsEnabled); w.bool(kittyPasteEventsEnabled)
        w.bool(cursorStartsNewGrapheme); w.bool(keyboardActionMode); w.bool(sendReceiveMode); w.bool(backarrowKeyMode)
        w.u8(characterProtectionMode); w.bool(characterProtection)
        w.bool(reverseWraparoundExtended); w.bool(noClearOnColumnChange)
        w.uint(reportedDECModes.count)
        for mode in reportedDECModes { w.int(mode) }
        w.int(attributeChangeExtent); w.bool(moreFix)
        for color in [oscForeground, oscBackground, cursorColor] {
            w.optional(color) { w, rgb in w.uint(Int(rgb.red)); w.uint(Int(rgb.green)); w.uint(Int(rgb.blue)) }
        }
        w.uint(programStatus.count)
        for record in programStatus { SnapshotCodec.write(record, &w) }
    }

    init(_ r: inout SnapshotReader, attributes: [Attribute]) throws {
        cols = try r.count(max: 65535, "cols"); rows = try r.count(max: 65535, "rows")
        guard cols > 0, rows > 0 else { throw TerminalStateSnapshotError.invalid("grid") }
        altActive = try r.bool()
        let styleName = try r.string()
        guard let style = CursorStyle(tagName: styleName) else { throw TerminalStateSnapshotError.invalid("cursor style") }
        cursorStyle = style
        synchronizedOutputActive = try r.bool()
        applicationKeypad = try r.bool(); applicationCursor = try r.bool(); reverseColors = try r.bool()
        var kitty: [KittyKeyboardImage] = []
        for _ in 0..<2 {
            let flags = try r.int()
            let count = try r.count(max: 1024, "kitty stack")
            var stack: [Int] = []
            for _ in 0..<count { stack.append(try r.int()) }
            kitty.append(KittyKeyboardImage(flags: flags, stack: stack))
        }
        kittyNormal = kitty[0]; kittyAlt = kitty[1]
        sendFocus = try r.bool()
        currentBidiState = try SnapshotCodec.readBidi(&r)
        bidiArrowKeySwap = try r.bool()
        let savedCount = try r.count(max: 65536, "saved modes")
        var saved: [Int: Bool] = [:]
        for _ in 0..<savedCount { saved[try r.int()] = try r.bool() }
        savedPrivateModes = saved
        cursorHidden = try r.bool(); originMode = try r.bool(); marginMode = try r.bool()
        insertMode = try r.bool(); wraparound = try r.bool()
        bracketedPasteMode = try r.bool(); alternateScrollMode = try r.bool(); colorSchemeUpdatesEnabled = try r.bool()
        colorSchemeIsLight = try r.bool()
        charset = try SnapshotCodec.readCharset(&r)
        let setCount = try r.count(max: 16, "charsets")
        var sets: [[UInt8: String]?] = []
        for _ in 0..<setCount { sets.append(try SnapshotCodec.readCharset(&r)) }
        gCharsets = sets
        reverseWraparound = try r.bool()
        currentAttribute = try SnapshotCodec.attribute(&r, attributes)
        gLevel = try r.u8(); cursorBlink = try r.bool(); allow80To132 = try r.bool()
        lineFeedMode = try r.bool(); smoothScroll = try r.bool()
        let paletteCount = try r.count(max: 4096, "palette")
        var palette: [Int: RGB16] = [:]
        for _ in 0..<paletteCount {
            let key = try r.uint()
            palette[key] = RGB16(red: UInt16(truncatingIfNeeded: try r.uint()),
                                 green: UInt16(truncatingIfNeeded: try r.uint()),
                                 blue: UInt16(truncatingIfNeeded: try r.uint()))
        }
        paletteOverrides = palette
        send8bit = try r.bool()
        hostCurrentDirectory = try r.optional { try $0.string() }
        hostCurrentDocument = try r.optional { try $0.string() }
        mouseProtocol = try SnapshotCodec.mouseProtocol(try r.u8())
        mouseMode = try SnapshotCodec.mouseMode(try r.u8())
        mouseShiftCapture = try r.bool()
        xtermTitleSetUtf = try r.bool(); xtermTitleSetHex = try r.bool()
        xtermTitleQueryUtf = try r.bool(); xtermTitleQueryHex = try r.bool()
        conformance = try SnapshotCodec.conformance(try r.u8())
        switch try r.u8() {
        case 0: activeHyperlink = .none
        case 1: activeHyperlink = .open(try r.string())
        case 2: activeHyperlink = .unavailable
        default: throw TerminalStateSnapshotError.invalid("hyperlink")
        }
        terminalTitle = try r.string(); iconTitle = try r.string()
        var stacks: [[String]] = []
        for _ in 0..<2 {
            // Upstream pushes without a cap (CSI 22 t); each title takes at least its length byte.
            let count = try r.count(max: r.remaining, "title stack")
            var stack: [String] = []
            for _ in 0..<count { stack.append(try r.string()) }
            stacks.append(stack)
        }
        terminalTitleStack = stacks[0]; terminalIconStack = stacks[1]
        visibilityReportsEnabled = try r.bool(); inBandSizeReportsEnabled = try r.bool()
        kittyPasteEventsEnabled = try r.bool()
        cursorStartsNewGrapheme = try r.bool(); keyboardActionMode = try r.bool()
        sendReceiveMode = try r.bool(); backarrowKeyMode = try r.bool()
        characterProtectionMode = try r.u8()
        guard characterProtectionMode <= 2 else { throw TerminalStateSnapshotError.invalid("protection mode") }
        characterProtection = try r.bool()
        reverseWraparoundExtended = try r.bool(); noClearOnColumnChange = try r.bool()
        let modeCount = try r.count(max: 4096, "reported modes")
        var reported: [Int] = []
        for _ in 0..<modeCount { reported.append(try r.int()) }
        reportedDECModes = reported
        attributeChangeExtent = try r.int(); moreFix = try r.bool()
        var colors: [RGB16?] = []
        for _ in 0..<3 {
            colors.append(try r.optional { r in
                RGB16(red: UInt16(truncatingIfNeeded: try r.uint()), green: UInt16(truncatingIfNeeded: try r.uint()),
                      blue: UInt16(truncatingIfNeeded: try r.uint()))
            })
        }
        oscForeground = colors[0]; oscBackground = colors[1]; cursorColor = colors[2]
        let statusCount = try r.count(max: TerminalProgramStatusStore.maximumRecords, "program status")
        var records: [TerminalProgramStatus] = []
        for _ in 0..<statusCount { records.append(try SnapshotCodec.readProgramStatus(&r)) }
        programStatus = records
    }
}

// MARK: - Buffers and lines

extension BufferImage {
    func encode(_ w: inout SnapshotWriter, attributes: inout AttributeTable, payloads: inout PayloadTable) {
        w.uint(cols); w.uint(rows)
        w.optional(scrollback) { $0.uint($1) }
        w.uint(lineCapacity)
        w.uint(pendingHistoryLines)
        w.uint(lines.count)
        for line in lines { line.encode(&w, attributes: &attributes, payloads: &payloads) }
        for value in [x, y, yBase, yDisp, linesTop, scrollTop, scrollBottom, marginLeft, marginRight] {
            w.int(value)
        }
        w.uint(tabStops.count)
        var packed: UInt8 = 0
        for (index, stop) in tabStops.enumerated() {
            if stop { packed |= 1 << UInt8(index % 8) }
            if index % 8 == 7 { w.u8(packed); packed = 0 }
        }
        if tabStops.count % 8 != 0 { w.u8(packed) }
        w.int(savedX); w.int(savedY)
        w.bool(savedOriginMode); w.bool(savedMarginMode); w.bool(savedCharacterProtection); w.bool(savedPendingWrap)
        w.uint(attributes.id(savedAttr))
        SnapshotCodec.write(savedCharset, &w)
        w.bool(insertMode); w.bool(marginMode); w.bool(wraparound); w.bool(characterProtection); w.bool(pendingWrap)
        w.u8(CellArena.semanticContentCode(for: semanticContent))
        w.u8(SnapshotCodec.code(semanticInput))
        w.u8(SnapshotCodec.code(semanticClickMode))
        w.bool(semanticUsesSpecialCursorKeys)
        w.optional(semanticPromptStartRow) { $0.int($1) }
        w.uvar(semanticGroupCounter); w.uvar(activeSemanticGroupID)
        SnapshotCodec.write(defaultBidiState, &w)
    }

    init(_ r: inout SnapshotReader, attributes: [Attribute], payloads: [String]) throws {
        cols = try r.count(max: 65535, "buffer cols"); rows = try r.count(max: 65535, "buffer rows")
        scrollback = try r.optional { try $0.uint() }
        lineCapacity = try r.count(max: Int(Int32.max), "line capacity")
        guard lineCapacity > 0 else { throw TerminalStateSnapshotError.invalid("line capacity") }
        pendingHistoryLines = try r.count(max: lineCapacity, "pending history")
        let lineCount = try r.count(max: min(lineCapacity, r.remaining), "lines")
        var decoded: [LineImage] = []
        decoded.reserveCapacity(lineCount)
        for _ in 0..<lineCount { decoded.append(try LineImage(&r, attributes: attributes, payloads: payloads)) }
        lines = decoded
        x = try r.int(); y = try r.int(); yBase = try r.int(); yDisp = try r.int()
        linesTop = try r.int()
        scrollTop = try r.int(); scrollBottom = try r.int(); marginLeft = try r.int(); marginRight = try r.int()
        guard x >= 0, y >= 0, yBase >= 0, yDisp >= 0, scrollTop >= 0, scrollBottom >= 0 else {
            throw TerminalStateSnapshotError.invalid("negative cursor or region")
        }
        let stopCount = try r.count(max: min(65535, r.remaining * 8), "tab stops")
        var stops: [Bool] = []
        stops.reserveCapacity(stopCount)
        var packed: UInt8 = 0
        for index in 0..<stopCount {
            if index % 8 == 0 { packed = try r.u8() }
            stops.append(packed & (1 << UInt8(index % 8)) != 0)
        }
        tabStops = stops
        savedX = try r.int(); savedY = try r.int()
        savedOriginMode = try r.bool(); savedMarginMode = try r.bool()
        savedCharacterProtection = try r.bool(); savedPendingWrap = try r.bool()
        savedAttr = try SnapshotCodec.attribute(&r, attributes)
        savedCharset = try SnapshotCodec.readCharset(&r)
        insertMode = try r.bool(); marginMode = try r.bool(); wraparound = try r.bool()
        characterProtection = try r.bool(); pendingWrap = try r.bool()
        semanticContent = CellArena.semanticContent(for: try r.u8())
        semanticInput = try SnapshotCodec.inputState(try r.u8())
        semanticClickMode = try SnapshotCodec.clickMode(try r.u8())
        semanticUsesSpecialCursorKeys = try r.bool()
        semanticPromptStartRow = try r.optional { try $0.int() }
        semanticGroupCounter = try r.uvar(); activeSemanticGroupID = try r.uvar()
        defaultBidiState = try SnapshotCodec.readBidi(&r)
    }
}

extension LineImage {
    // Cell flag bits.
    static let newAttribute: UInt8 = 1 << 0
    static let unusualWidth: UInt8 = 1 << 1
    static let hasGraphemes: UInt8 = 1 << 2
    static let hasPayload: UInt8 = 1 << 3
    static let hasSemantic: UInt8 = 1 << 4
    static let protected: UInt8 = 1 << 5
    /// A run of plain printable ASCII cells in the current attribute: a count, then the bytes.
    static let asciiRun: UInt8 = 1 << 6

    private static func isPlainASCII(_ cell: CellImage, attribute: Int, previous: Int) -> Bool {
        attribute == previous && cell.width == 1 && cell.widthState == 0 && cell.graphemes == nil
            && cell.payload == nil && cell.semantic == 0 && !cell.isProtected
            && cell.code >= 0x20 && cell.code < 0x7f
    }

    func encode(_ w: inout SnapshotWriter, attributes: inout AttributeTable, payloads: inout PayloadTable) {
        w.uint(cols); w.bool(isWrapped)
        SnapshotCodec.write(bidiState, &w)
        w.u8(renderMode)
        w.uint(semanticMarks.count)
        for mark in semanticMarks { w.u8(SnapshotCodec.code(mark.kind)); w.int(mark.column); w.uvar(mark.group) }
        w.optional(hardContinuationGroup) { $0.uvar($1) }
        let tail = attributes.id(tailAttribute)
        w.uint(tail)
        w.uint(cells.count)
        var previous = tail
        var index = 0
        while index < cells.count {
            let cell = cells[index]
            let attribute = attributes.id(cell.attribute)
            if LineImage.isPlainASCII(cell, attribute: attribute, previous: previous) {
                var end = index + 1
                while end < cells.count,
                      LineImage.isPlainASCII(cells[end], attribute: attributes.id(cells[end].attribute), previous: previous) {
                    end += 1
                }
                if end - index >= 3 {
                    w.u8(LineImage.asciiRun)
                    w.uint(end - index)
                    for plain in cells[index..<end] { w.u8(UInt8(plain.code)) }
                    index = end
                    continue
                }
            }
            index += 1
            var flags: UInt8 = 0
            if attribute != previous { flags |= LineImage.newAttribute }
            if cell.width != 1 || cell.widthState != 0 { flags |= LineImage.unusualWidth }
            if cell.graphemes != nil { flags |= LineImage.hasGraphemes }
            if cell.payload != nil { flags |= LineImage.hasPayload }
            if cell.semantic != 0 { flags |= LineImage.hasSemantic }
            if cell.isProtected { flags |= LineImage.protected }
            w.u8(flags)
            if attribute != previous { w.uint(attribute); previous = attribute }
            w.int(Int(cell.code))
            if flags & LineImage.unusualWidth != 0 { w.int(Int(cell.width)); w.u8(cell.widthState) }
            if let graphemes = cell.graphemes {
                w.uint(graphemes.count)
                for scalar in graphemes { w.uvar(UInt64(scalar)) }
            }
            if let payload = cell.payload { w.uint(payloads.id(payload)) }
            if cell.semantic != 0 { w.u8(cell.semantic) }
        }
    }

    init(_ r: inout SnapshotReader, attributes: [Attribute], payloads: [String]) throws {
        cols = try r.count(max: 65535, "line cols")
        isWrapped = try r.bool()
        bidiState = try SnapshotCodec.readBidi(&r)
        renderMode = try r.u8()
        // One per kind per line, but a reflow joins the marks of the lines it joins.
        let markCount = try r.count(max: r.remaining, "marks")
        var marks: [SemanticMark] = []
        for _ in 0..<markCount {
            let kind = try SnapshotCodec.kind(try r.u8())
            // A reflow moves a mark by plain arithmetic (BufferLine.swift:980, column - srcCol + dstCol).
            let column = try r.int()
            guard column.magnitude <= UInt(Int32.max) else { throw TerminalStateSnapshotError.invalid("mark column") }
            marks.append(SemanticMark(kind: kind, column: column, group: try r.uvar()))
        }
        semanticMarks = marks
        hardContinuationGroup = try r.optional { try $0.uvar() }
        tailAttribute = try SnapshotCodec.attribute(&r, attributes)
        var current = tailAttribute
        let cellCount = try r.count(max: min(cols, r.remaining), "cells")
        var decoded: [CellImage] = []
        decoded.reserveCapacity(cellCount)
        while decoded.count < cellCount {
            let flags = try r.u8()
            if flags == LineImage.asciiRun {
                let run = try r.count(max: cellCount - decoded.count, "ascii run")
                for _ in 0..<run {
                    let code = try r.u8()
                    guard code >= 0x20, code < 0x7f else { throw TerminalStateSnapshotError.invalid("ascii run") }
                    decoded.append(CellImage(attribute: current, code: Int32(code), graphemes: nil, width: 1,
                                             widthState: 0, payload: nil, semantic: 0, isProtected: false))
                }
                continue
            }
            guard flags & LineImage.asciiRun == 0 else { throw TerminalStateSnapshotError.invalid("cell flags") }
            if flags & LineImage.newAttribute != 0 { current = try SnapshotCodec.attribute(&r, attributes) }
            let code = try r.int()
            // 0 (blank) or a scalar the arena stores; anything else fails import's pack.
            guard code == 0 || (code > 0 && code <= 0x10ffff && PackedCell.isValidUnicodeScalar(UInt32(code))) else {
                throw TerminalStateSnapshotError.invalid("code")
            }
            var width: Int8 = 1
            var widthState: UInt8 = 0
            if flags & LineImage.unusualWidth != 0 {
                let w = try r.int()
                guard w >= Int(Int8.min), w <= Int(Int8.max) else { throw TerminalStateSnapshotError.invalid("width") }
                width = Int8(w)
                widthState = try r.u8()
                guard PackedCell.WidthState(rawValue: widthState) != nil else {
                    throw TerminalStateSnapshotError.invalid("width state")
                }
            }
            var graphemes: [UInt32]? = nil
            if flags & LineImage.hasGraphemes != 0 {
                // A cell takes any number of combining marks; each scalar takes at least one byte.
                let count = try r.count(max: r.remaining, "grapheme")
                var scalars: [UInt32] = []
                for _ in 0..<count {
                    let scalar = try r.uvar()
                    guard scalar <= 0x10ffff, PackedCell.isValidUnicodeScalar(UInt32(scalar)) else {
                        throw TerminalStateSnapshotError.invalid("grapheme scalar")
                    }
                    scalars.append(UInt32(scalar))
                }
                graphemes = scalars
            }
            var payload: String? = nil
            if flags & LineImage.hasPayload != 0 {
                let id = try r.uint()
                guard id < payloads.count else { throw TerminalStateSnapshotError.invalid("payload index") }
                payload = payloads[id]
            }
            let semantic: UInt8 = flags & LineImage.hasSemantic != 0 ? try r.u8() : 0
            decoded.append(CellImage(attribute: current, code: Int32(code), graphemes: graphemes,
                                     width: width, widthState: widthState, payload: payload,
                                     semantic: semantic, isProtected: flags & LineImage.protected != 0))
        }
        cells = decoded
    }
}
