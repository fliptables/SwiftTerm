//
//  TerminalReplayStream.swift
//
//  Candidate (a) of IT-1149 T3: a snapshot as a byte stream. The stream is
//  ordinary terminal input (SGR runs, cursor moves, mode sets, OSC strings)
//  that a fresh terminal of the same size feeds to reach the exporter's
//  state, followed by the exporter's pending parser bytes. It is built from
//  the same model the state export reads, as faithfully as escape sequences
//  can express it; T3 measures where it falls short.
//

import Foundation

/// A snapshot as terminal input: resize a fresh terminal to `cols` × `rows`,
/// then feed `bytes`.
public struct TerminalReplayStream: Sendable {
    public let cols: Int
    public let rows: Int
    public let bytes: [UInt8]
}

extension Terminal {
    /// Exports the emulator state as a byte stream a fresh terminal replays.
    /// Call under `terminalLock`, between feeds.
    public func exportReplayStream() -> TerminalReplayStream {
        let snapshot = exportState()
        var out = ReplayWriter()
        let modes = snapshot.modes

        // The normal screen, its history first.
        out.renderBuffer(snapshot.normal, cols: modes.cols)
        out.kittyStack(modes.kittyNormal)
        if modes.altActive {
            // Save the normal cursor the way 1049 would, then switch without
            // clearing or saving again.
            out.savedCursor(snapshot.normal)
            out.csi("?47h")
            out.renderBuffer(snapshot.alt, cols: modes.cols)
            out.kittyStack(modes.kittyAlt)
            out.savedCursor(snapshot.alt)
        } else {
            out.savedCursor(snapshot.normal)
        }
        let active = modes.altActive ? snapshot.alt : snapshot.normal

        // Tab stops.
        out.csi("3g")
        for (column, stop) in active.tabStops.enumerated() where stop && column < modes.cols {
            out.cup(row: 0, col: column)
            out.esc("H")
        }

        // Titles and their stacks, oldest first.
        for title in modes.terminalTitleStack { out.osc("2;" + title); out.csi("22;2t") }
        for icon in modes.terminalIconStack { out.osc("1;" + icon); out.csi("22;1t") }
        out.osc("2;" + modes.terminalTitle)
        out.osc("1;" + modes.iconTitle)
        if let directory = modes.hostCurrentDirectory { out.osc("7;" + directory) }
        for (index, rgb) in modes.paletteOverrides.sorted(by: { $0.key < $1.key }) {
            out.osc(String(format: "4;%d;rgb:%04x/%04x/%04x", index, rgb.red, rgb.green, rgb.blue))
        }

        // Saved private modes (XTSAVE): set each to its saved value, save it.
        for (mode, value) in modes.savedPrivateModes.sorted(by: { $0.key < $1.key }) {
            out.csi("?\(mode)\(value ? "h" : "l")")
            out.csi("?\(mode)s")
        }

        // Charsets: designate G0..G3, then shift.
        let finals: [UInt8] = [0x28, 0x29, 0x2a, 0x2b]
        for (index, set) in modes.gCharsets.enumerated() where index < finals.count {
            let designator = set.flatMap(ReplayWriter.designator(for:)) ?? UInt8(ascii: "B")
            out.raw([0x1b, finals[index], designator])
        }
        switch modes.gLevel {
        case 1: out.raw([0x0e])
        case 2: out.esc("n")
        case 3: out.esc("o")
        default: out.raw([0x0f])
        }

        // Modes.
        out.decset(1, modes.applicationCursor)
        out.esc(modes.applicationKeypad ? "=" : ">")
        out.decset(5, modes.reverseColors)
        out.decset(7, modes.wraparound)
        out.decset(12, modes.cursorBlink)
        out.decset(25, !modes.cursorHidden)
        out.decset(40, modes.allow80To132)
        out.decset(45, modes.reverseWraparound)
        switch modes.mouseMode {
        case .off: out.csi("?1000l")
        case .x10: out.csi("?9h")
        case .vt200: out.csi("?1000h")
        case .buttonEventTracking: out.csi("?1002h")
        case .anyEvent: out.csi("?1003h")
        }
        switch modes.mouseProtocol {
        case .x10: break
        case .utf8: out.csi("?1005h")
        case .sgr: out.csi("?1006h")
        case .urxvt: out.csi("?1015h")
        case .sgrPixel: out.csi("?1016h")
        }
        out.decset(1004, modes.sendFocus)
        out.decset(1007, modes.alternateScrollMode)
        out.decset(2004, modes.bracketedPasteMode)
        out.decset(2031, modes.colorSchemeUpdatesEnabled)
        out.decset(2048, modes.inBandSizeReportsEnabled)
        out.csi(modes.insertMode ? "4h" : "4l")
        out.csi(modes.lineFeedMode ? "20h" : "20l")
        out.csi("\(ReplayWriter.cursorStyleCode(modes.cursorStyle)) q")

        // Margins and origin, then the cursor and its pending wrap.
        out.csi("\(active.scrollTop + 1);\(active.scrollBottom + 1)r")
        out.decset(69, modes.marginMode)
        if modes.marginMode {
            out.csi("\(active.marginLeft + 1);\(active.marginRight + 1)s")
        }
        out.decset(6, false)
        out.placeCursor(active, cols: modes.cols)
        out.decset(6, modes.originMode)
        if modes.originMode {
            // DECOM homes the cursor; place it again relative to the region.
            out.cup(row: active.y - active.scrollTop, col: min(active.x, modes.cols - 1) - (modes.marginMode ? active.marginLeft : 0))
        }

        // The current attribute and open hyperlink.
        out.sgr(modes.currentAttribute)
        if case .open(let payload) = modes.activeHyperlink { out.osc("8;" + payload) }
        out.decset(2026, modes.synchronizedOutputActive)

        out.raw(snapshot.pendingParserBytes)
        return TerminalReplayStream(cols: modes.cols, rows: modes.rows, bytes: out.bytes)
    }
}

struct ReplayWriter {
    var bytes: [UInt8] = []
    var attribute: Attribute = CharData.defaultAttr
    var payload: String? = nil

    mutating func raw(_ value: [UInt8]) { bytes.append(contentsOf: value) }
    mutating func text(_ value: String) { bytes.append(contentsOf: Array(value.utf8)) }
    mutating func esc(_ value: String) { bytes.append(0x1b); text(value) }
    mutating func csi(_ value: String) { bytes.append(0x1b); bytes.append(0x5b); text(value) }
    mutating func osc(_ value: String) { bytes.append(0x1b); bytes.append(0x5d); text(value); bytes.append(0x07) }
    mutating func decset(_ mode: Int, _ on: Bool) { csi("?\(mode)\(on ? "h" : "l")") }
    mutating func cup(row: Int, col: Int) { csi("\(row + 1);\(col + 1)H") }

    static func designator(for set: [UInt8: String]) -> UInt8? {
        CharSets.all.first { $0.value == set }?.key
    }

    static func cursorStyleCode(_ style: CursorStyle) -> Int {
        switch style {
        case .blinkBlock: return 1
        case .steadyBlock: return 2
        case .blinkUnderline: return 3
        case .steadyUnderline: return 4
        case .blinkBar: return 5
        case .steadyBar: return 6
        }
    }

    mutating func sgr(_ value: Attribute) {
        var parts = ["0"]
        let style = value.style
        if style.contains(.bold) { parts.append("1") }
        if style.contains(.dim) { parts.append("2") }
        if style.contains(.italic) { parts.append("3") }
        if style.contains(.underline) {
            switch value.underlineStyle {
            case .none, .single: parts.append("4")
            case .double: parts.append("4:2")
            case .curly: parts.append("4:3")
            case .dotted: parts.append("4:4")
            case .dashed: parts.append("4:5")
            }
        }
        if style.contains(.blink) { parts.append("5") }
        if style.contains(.inverse) { parts.append("7") }
        if style.contains(.invisible) { parts.append("8") }
        if style.contains(.crossedOut) { parts.append("9") }
        if let fg = Self.color(value.fg, base: 38, defaultCode: 39) { parts.append(fg) }
        if let bg = Self.color(value.bg, base: 48, defaultCode: 49) { parts.append(bg) }
        if let underline = value.underlineColor, let code = Self.color(underline, base: 58, defaultCode: 59) {
            parts.append(code)
        }
        csi(parts.joined(separator: ";") + "m")
        attribute = value
    }

    static func color(_ color: Attribute.Color, base: Int, defaultCode: Int) -> String? {
        switch color {
        case .ansi256(let code): return "\(base);5;\(code)"
        case .trueColor(let r, let g, let b): return "\(base);2;\(r);\(g);\(b)"
        case .defaultColor: return nil
        case .defaultInvertedColor: return nil
        }
    }

    mutating func hyperlink(_ value: String?) {
        guard value != payload else { return }
        osc("8;" + (value ?? ";"))
        payload = value
    }

    /// Writes every line of a buffer from the top, so lines past the screen
    /// scroll into history, and leaves the cursor at the bottom row.
    mutating func renderBuffer(_ buffer: BufferImage, cols: Int) {
        csi("H")
        csi("2J")
        for (index, line) in buffer.lines.enumerated() {
            if index > 0 {
                let continued = line.isWrapped && (buffer.lines[index - 1].cells.count >= cols)
                if !continued {
                    hyperlink(nil)
                    text("\r\n")
                }
            }
            renderLine(line, cols: cols)
        }
        hyperlink(nil)
        sgr(CharData.defaultAttr)
    }

    mutating func renderLine(_ line: LineImage, cols: Int) {
        switch line.renderMode {
        case 1: esc("#6")
        case 2: esc("#3")
        case 3: esc("#4")
        default: break
        }
        var column = 0
        var protected = false
        for cell in line.cells where column < cols {
            if cell.width == 0 { column += 1; continue }
            if cell.attribute != attribute { sgr(cell.attribute) }
            if cell.isProtected != protected { csi(cell.isProtected ? "1\"q" : "0\"q"); protected = cell.isProtected }
            hyperlink(cell.payload)
            if let graphemes = cell.graphemes {
                for scalar in graphemes { if let u = Unicode.Scalar(scalar) { text(String(u)) } }
            } else if cell.code == 0 {
                text(" ")
            } else if let u = Unicode.Scalar(UInt32(bitPattern: cell.code)) {
                text(String(u))
            }
            column += max(1, Int(cell.width))
        }
        if protected { csi("0\"q") }
        // The rest of the line takes the tail blank's colours (BCE).
        if column < cols {
            hyperlink(nil)
            sgr(line.tailAttribute)
            csi("K")
        }
    }

    mutating func placeCursor(_ buffer: BufferImage, cols: Int) {
        let row = buffer.y
        if buffer.x >= cols, let line = buffer.lines.indices.contains(buffer.yBase + row) ? buffer.lines[buffer.yBase + row] : nil,
           let last = line.cells.last {
            // A pending wrap: rewrite the last cell so the cursor sits past it.
            cup(row: row, col: cols - 1)
            sgr(last.attribute)
            if let u = Unicode.Scalar(UInt32(bitPattern: last.code)), last.code != 0 { text(String(u)) } else { text(" ") }
        } else {
            cup(row: row, col: min(buffer.x, cols - 1))
        }
    }

    mutating func savedCursor(_ buffer: BufferImage) {
        cup(row: buffer.savedY, col: buffer.savedX)
        sgr(buffer.savedAttr)
        esc("7")
    }

    mutating func kittyStack(_ image: KittyKeyboardImage) {
        for flags in image.stack { csi(">\(flags)u") }
        csi("=\(image.flags);1u")
    }
}
