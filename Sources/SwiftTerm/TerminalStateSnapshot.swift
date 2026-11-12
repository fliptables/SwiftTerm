//
//  TerminalStateSnapshot.swift
//
//  An explicit export and import of a terminal's emulator state, for a host
//  that keeps the authoritative terminal in one process and replicates it to
//  views in others (IT-1149). A replica imports the snapshot, then feeds only
//  the output that followed it.
//
//  The snapshot copies the model instead of re-deriving it from bytes: both
//  buffers with every line, wrap flag, cell, grapheme, hyperlink and semantic
//  mark; the cursor, saved cursors, margins and tab stops; every mode; the
//  Kitty keyboard stacks; titles and their stacks; and the bytes of any
//  sequence the parser has only partly read.
//
//  What it does not carry, by design (each is listed in `notCarried`):
//  - Kitty graphics and sixel images: declared lost until the application
//    redraws.
//  - Host configuration the importing view owns: the installed palette and
//    default colours, the options it was created with (only the cursor style,
//    which an application changes, is carried), selection, scroll position
//    chosen by the user, focus, visibility and pixel geometry.
//  - Input-side state: the OSC 133 input scanner and clipboard transactions.
//  - A cell payload that is not a `String` (hyperlinks are strings).
//
//  The encoded form is for two processes of the same build. It starts with a
//  magic number and a format version, and `init(encoded:)` refuses any other.
//

import Foundation

/// A terminal's emulator state, exported by ``Terminal/exportState()`` and
/// applied by ``Terminal/importState(_:)``.
public struct TerminalStateSnapshot: Equatable, Sendable {
    /// The version of ``encoded()``. A decoder refuses any other.
    public static let formatVersion: UInt32 = 1
    static let magic: [UInt8] = Array("STSS".utf8)

    /// The categories of state the snapshot deliberately leaves out.
    public static let notCarried: [String] = [
        "kittyGraphicsAndSixelImages",
        "hostPaletteAndDefaultColors",
        "hostOptionsExceptCursorStyle",
        "selection",
        "userScrollPosition",
        "focusVisibilityAndPixelGeometry",
        "semanticInputScanner",
        "kittyClipboardTransactions",
        "nonStringCellPayloads",
    ]

    var modes: TerminalModesImage
    var normal: BufferImage
    var alt: BufferImage

    /// Columns of the terminal grid.
    public var cols: Int { modes.cols }
    /// Rows of the terminal grid.
    public var rows: Int { modes.rows }
    /// Whether the alternate screen was active.
    public var alternateScreenActive: Bool { modes.altActive }
    /// Bytes of a sequence the parser had only partly read. The importer feeds
    /// them last, so its parser resumes in the same state.
    public internal(set) var pendingParserBytes: [UInt8]
    /// Cells whose payload was dropped because it was not a `String`.
    public internal(set) var droppedPayloadCount: Int
}

// MARK: - The model images

struct RGB16: Equatable, Sendable {
    var red: UInt16, green: UInt16, blue: UInt16
}

struct KittyKeyboardImage: Equatable, Sendable {
    var flags: Int
    var stack: [Int]
}

enum HyperlinkImage: Equatable, Sendable {
    case none
    case open(String)
    case unavailable
}

struct TerminalModesImage: Equatable, Sendable {
    var cols: Int
    var rows: Int
    var altActive: Bool
    var tabStopWidth: Int
    var cursorStyle: CursorStyle
    var synchronizedOutputActive: Bool
    var applicationKeypad: Bool
    var applicationCursor: Bool
    var reverseColors: Bool
    var kittyNormal: KittyKeyboardImage
    var kittyAlt: KittyKeyboardImage
    var sendFocus: Bool
    var currentBidiState: BidiPresentationState
    var bidiArrowKeySwap: Bool
    var savedPrivateModes: [Int: Bool]
    var cursorHidden: Bool
    var originMode: Bool
    var marginMode: Bool
    var insertMode: Bool
    var wraparound: Bool
    var bracketedPasteMode: Bool
    var alternateScrollMode: Bool
    var colorSchemeUpdatesEnabled: Bool
    var colorSchemeIsLight: Bool
    var charset: [UInt8: String]?
    var gCharsets: [[UInt8: String]?]
    var gcharset: Int
    var reverseWraparound: Bool
    var currentAttribute: Attribute
    var gLevel: UInt8
    var cursorBlink: Bool
    var allow80To132: Bool
    var lineFeedMode: Bool
    var smoothScroll: Bool
    /// Palette entries an application changed (OSC 4), by index.
    var paletteOverrides: [Int: RGB16]
    var send8bit: Bool
    var hostCurrentDirectory: String?
    var hostCurrentDocument: String?
    var mouseProtocol: Terminal.MouseProtocolEncoding
    var mouseMode: Terminal.MouseMode
    var mouseShiftCapture: Bool
    var xtermTitleSetUtf: Bool
    var xtermTitleSetHex: Bool
    var xtermTitleQueryUtf: Bool
    var xtermTitleQueryHex: Bool
    var conformance: Terminal.TerminalConformance
    var activeHyperlink: HyperlinkImage
    var terminalTitle: String
    var iconTitle: String
    var terminalTitleStack: [String]
    var terminalIconStack: [String]
    var visibilityReportsEnabled: Bool
    var inBandSizeReportsEnabled: Bool
    var kittyPasteEventsEnabled: Bool
}

struct CellImage: Equatable, Sendable {
    var attribute: Attribute
    var code: Int32
    var graphemes: [UInt32]?
    var width: Int8
    var widthState: UInt8
    var payload: String?
    var semantic: UInt8
    var isProtected: Bool
}

struct LineImage: Equatable, Sendable {
    var cols: Int
    var isWrapped: Bool
    var bidiState: BidiPresentationState
    var renderMode: UInt8
    var semanticMarks: [SemanticMark]
    var hardContinuationGroup: UInt64?
    var tailAttribute: Attribute
    /// The written prefix of the line; every later cell is blank with
    /// `tailAttribute`.
    var cells: [CellImage]
}

struct BufferImage: Equatable, Sendable {
    var cols: Int
    var rows: Int
    var scrollback: Int?
    /// The line list's capacity. Usually `rows + scrollback`, but a buffer
    /// resized smaller keeps its larger capacity (and lines), and how many
    /// lines it holds before trimming decides later output.
    var lineCapacity: Int
    /// History lines left out of a screen part, still to arrive as chunks.
    var pendingHistoryLines: Int = 0
    var lines: [LineImage]
    var x: Int
    var y: Int
    var yBase: Int
    var yDisp: Int
    var xDisp: Int
    var xBase: Int
    var linesTop: Int
    var scrollTop: Int
    var scrollBottom: Int
    var marginLeft: Int
    var marginRight: Int
    var tabStops: [Bool]
    var savedX: Int
    var savedY: Int
    var savedOriginMode: Bool
    var savedMarginMode: Bool
    var savedWraparound: Bool
    var savedReverseWraparound: Bool
    var savedAttr: Attribute
    var savedCharset: [UInt8: String]?
    var insertMode: Bool
    var marginMode: Bool
    var wraparound: Bool
    var semanticContent: SemanticContent
    var semanticInput: SemanticInputState
    var semanticClickMode: SemanticPromptClickMode
    var semanticUsesSpecialCursorKeys: Bool
    var semanticPromptStartRow: Int?
    var semanticGroupCounter: UInt64
    var activeSemanticGroupID: UInt64
    var defaultBidiState: BidiPresentationState
}

extension LineImage {
    static func code(_ mode: BufferLine.RenderLineMode) -> UInt8 {
        switch mode {
        case .single: return 0
        case .doubleWidth: return 1
        case .doubledTop: return 2
        case .doubledDown: return 3
        }
    }

    static func renderMode(_ code: UInt8) -> BufferLine.RenderLineMode {
        switch code {
        case 1: return .doubleWidth
        case 2: return .doubledTop
        case 3: return .doubledDown
        default: return .single
        }
    }
}

extension Terminal.MouseProtocolEncoding: Equatable {}
extension Terminal.TerminalConformance: Equatable {}

// MARK: - Export

extension Terminal {
    /// Exports the emulator state. Call under `terminalLock`, between feeds.
    public func exportState() -> TerminalStateSnapshot {
        exportState(skippingHistory: false)
    }

    func exportState(skippingHistory: Bool) -> TerminalStateSnapshot {
        var dropped = 0
        let modes = TerminalModesImage(
            cols: cols, rows: rows,
            altActive: isCurrentBufferAlternate,
            tabStopWidth: tabStopWidth,
            cursorStyle: options.cursorStyle,
            synchronizedOutputActive: synchronizedOutputActive,
            applicationKeypad: applicationKeypad,
            applicationCursor: applicationCursor,
            reverseColors: reverseColors,
            kittyNormal: KittyKeyboardImage(flags: keyboardModeNormal.flags.rawValue,
                                            stack: keyboardModeNormal.stack.map { $0.rawValue }),
            kittyAlt: KittyKeyboardImage(flags: keyboardModeAlt.flags.rawValue,
                                         stack: keyboardModeAlt.stack.map { $0.rawValue }),
            sendFocus: sendFocus,
            currentBidiState: _currentBidiState,
            bidiArrowKeySwap: bidiArrowKeySwap,
            savedPrivateModes: savedPrivateModes,
            cursorHidden: cursorHidden,
            originMode: originMode,
            marginMode: marginMode,
            insertMode: insertMode,
            wraparound: wraparound,
            bracketedPasteMode: bracketedPasteMode,
            alternateScrollMode: alternateScrollMode,
            colorSchemeUpdatesEnabled: colorSchemeUpdatesEnabled,
            colorSchemeIsLight: colorScheme == .light,
            charset: charset,
            gCharsets: gCharsets,
            gcharset: gcharset,
            reverseWraparound: reverseWraparound,
            currentAttribute: curAttr,
            gLevel: gLevel,
            cursorBlink: cursorBlink,
            allow80To132: allow80To132,
            lineFeedMode: lineFeedMode,
            smoothScroll: smoothScroll,
            paletteOverrides: paletteOverrides(),
            send8bit: cc.send8bit,
            hostCurrentDirectory: hostCurrentDirectory,
            hostCurrentDocument: hostCurrentDocument,
            mouseProtocol: mouseProtocol,
            mouseMode: mouseMode,
            mouseShiftCapture: mouseShiftCapture,
            xtermTitleSetUtf: xtermTitleSetUtf,
            xtermTitleSetHex: xtermTitleSetHex,
            xtermTitleQueryUtf: xtermTitleQueryUtf,
            xtermTitleQueryHex: xtermTitleQueryHex,
            conformance: conformance,
            activeHyperlink: activeHyperlinkImage(),
            terminalTitle: terminalTitle,
            iconTitle: iconTitle,
            terminalTitleStack: terminalTitleStack,
            terminalIconStack: terminalIconStack,
            visibilityReportsEnabled: visibilityReportsEnabled,
            inBandSizeReportsEnabled: inBandSizeReportsEnabled,
            kittyPasteEventsEnabled: kittyPasteEventsEnabled)
        let normalImage = Terminal.bufferImage(normalBuffer, dropped: &dropped, skippingHistory: skippingHistory)
        let altImage = Terminal.bufferImage(altBuffer, dropped: &dropped, skippingHistory: skippingHistory)
        return TerminalStateSnapshot(
            modes: modes, normal: normalImage, alt: altImage,
            pendingParserBytes: pendingParserBytes ?? [],
            droppedPayloadCount: dropped)
    }

    private func paletteOverrides() -> [Int: RGB16] {
        var result: [Int: RGB16] = [:]
        for index in 0..<min(ansiColors.count, defaultAnsiColors.count)
        where ansiColors[index] != defaultAnsiColors[index] {
            let color = ansiColors[index]
            result[index] = RGB16(red: color.red, green: color.green, blue: color.blue)
        }
        return result
    }

    private func activeHyperlinkImage() -> HyperlinkImage {
        switch activeHyperlink {
        case nil: return .none
        case .pending(let payload): return .open(payload)
        case .resolved(let atom): return .open(atom.target as? String ?? "")
        case .unavailable: return .unavailable
        }
    }

    static func bufferImage(_ buffer: Buffer, dropped: inout Int, skippingHistory: Bool = false) -> BufferImage {
        let history = skippingHistory ? min(buffer.yBase, buffer.lines.count) : 0
        var lines: [LineImage] = []
        lines.reserveCapacity(buffer.lines.count - history)
        for index in history..<buffer.lines.count {
            lines.append(lineImage(buffer.lines[index], dropped: &dropped))
        }
        var startRow: Int? = nil
        if let start = buffer.semanticPromptStartLine, let row = buffer.absoluteRow(of: start) {
            startRow = row >= history ? row - history : nil
        }
        return BufferImage(
            cols: buffer.cols, rows: buffer.rows, scrollback: buffer.scrollback,
            lineCapacity: buffer.lines.maxLength,
            pendingHistoryLines: history,
            lines: lines,
            x: buffer.x, y: buffer.y, yBase: buffer.yBase - history, yDisp: max(0, buffer.yDisp - history),
            xDisp: buffer.xDisp, xBase: buffer.xBase, linesTop: buffer.linesTop,
            scrollTop: buffer.scrollTop, scrollBottom: buffer.scrollBottom,
            marginLeft: buffer.marginLeft, marginRight: buffer.marginRight,
            tabStops: buffer.tabStops,
            savedX: buffer.savedX, savedY: buffer.savedY,
            savedOriginMode: buffer.savedOriginMode,
            savedMarginMode: buffer.savedMarginMode,
            savedWraparound: buffer.savedWraparound,
            savedReverseWraparound: buffer.savedReverseWraparound,
            savedAttr: buffer.savedAttr, savedCharset: buffer.savedCharset,
            insertMode: buffer.insertMode, marginMode: buffer.marginMode,
            wraparound: buffer.wraparound,
            semanticContent: buffer.semanticContent,
            semanticInput: buffer.semanticInput,
            semanticClickMode: buffer.semanticClickMode,
            semanticUsesSpecialCursorKeys: buffer.semanticUsesSpecialCursorKeys,
            semanticPromptStartRow: startRow,
            semanticGroupCounter: buffer.semanticGroupCounter,
            activeSemanticGroupID: buffer.activeSemanticGroupID,
            defaultBidiState: buffer.defaultBidiState)
    }

    static func lineImage(_ line: BufferLine, dropped: inout Int) -> LineImage {
        let used = line.replicationUsedLength
        var cells: [CellImage] = []
        cells.reserveCapacity(used)
        for column in 0..<used {
            let data = line[column]
            var payload: String? = nil
            if data.payload.code != 0 {
                if let text = data.payload.target as? String {
                    payload = text
                } else {
                    dropped += 1
                }
            }
            cells.append(CellImage(
                attribute: data.attribute, code: data.code,
                graphemes: data.packedGraphemeScalars, width: data.width,
                widthState: data.packedWidthStateCode, payload: payload,
                semantic: CellArena.semanticContentCode(for: data.semanticContent),
                isProtected: data.isProtected))
        }
        return LineImage(
            cols: line.count, isWrapped: line.isWrapped, bidiState: line.bidiState,
            renderMode: LineImage.code(line.renderMode), semanticMarks: line.semanticMarks,
            hardContinuationGroup: line.semanticHardContinuationGroup,
            tailAttribute: line.replicationTailAttribute, cells: cells)
    }
}

// MARK: - Import

extension Terminal {
    /// Replaces this terminal's emulator state with `snapshot`, then feeds the
    /// snapshot's pending parser bytes. Call under `terminalLock`, on a
    /// terminal whose options match the exporter's (scrollback, palette
    /// strategy). A replica sets ``respondsToQueries`` to `false` first.
    public func importState(_ snapshot: TerminalStateSnapshot) {
        let modes = snapshot.modes
        var payloads: [String: TinyAtom] = [:]

        _cols = modes.cols
        _rows = modes.rows
        options.cols = modes.cols
        options.rows = modes.rows
        tabStopWidth = modes.tabStopWidth

        let normal = makeBuffer(snapshot.normal, payloads: &payloads)
        let alt = makeBuffer(snapshot.alt, payloads: &payloads)
        normalBuffer = normal
        altBuffer = alt
        _buffer = modes.altActive ? alt : normal
        kittyGraphicsState.activeIsAlternate = modes.altActive

        options.cursorStyle = modes.cursorStyle
        applicationKeypad = modes.applicationKeypad
        applicationCursor = modes.applicationCursor
        reverseColors = modes.reverseColors
        keyboardModeNormal = KeyboardModeState(
            flags: KittyKeyboardFlags(rawValue: modes.kittyNormal.flags),
            stack: modes.kittyNormal.stack.map(KittyKeyboardFlags.init(rawValue:)))
        keyboardModeAlt = KeyboardModeState(
            flags: KittyKeyboardFlags(rawValue: modes.kittyAlt.flags),
            stack: modes.kittyAlt.stack.map(KittyKeyboardFlags.init(rawValue:)))
        sendFocus = modes.sendFocus
        _currentBidiState = modes.currentBidiState
        bidiArrowKeySwap = modes.bidiArrowKeySwap
        savedPrivateModes = modes.savedPrivateModes
        cursorHidden = modes.cursorHidden
        originMode = modes.originMode
        marginMode = modes.marginMode
        insertMode = modes.insertMode
        wraparound = modes.wraparound
        bracketedPasteMode = modes.bracketedPasteMode
        alternateScrollMode = modes.alternateScrollMode
        colorSchemeUpdatesEnabled = modes.colorSchemeUpdatesEnabled
        colorScheme = modes.colorSchemeIsLight ? .light : .dark
        charset = modes.charset
        gCharsets = modes.gCharsets
        gcharset = modes.gcharset
        reverseWraparound = modes.reverseWraparound
        setCurrentAttribute(modes.currentAttribute)
        gLevel = modes.gLevel
        cursorBlink = modes.cursorBlink
        allow80To132 = modes.allow80To132
        lineFeedMode = modes.lineFeedMode
        smoothScroll = modes.smoothScroll
        ansiColors = defaultAnsiColors
        for (index, rgb) in modes.paletteOverrides where index < ansiColors.count {
            ansiColors[index] = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
        cc.send8bit = modes.send8bit
        hostCurrentDirectory = modes.hostCurrentDirectory
        hostCurrentDocument = modes.hostCurrentDocument
        mouseProtocol = modes.mouseProtocol
        mouseMode = modes.mouseMode
        mouseShiftCapture = modes.mouseShiftCapture
        xtermTitleSetUtf = modes.xtermTitleSetUtf
        xtermTitleSetHex = modes.xtermTitleSetHex
        xtermTitleQueryUtf = modes.xtermTitleQueryUtf
        xtermTitleQueryHex = modes.xtermTitleQueryHex
        conformance = modes.conformance
        switch modes.activeHyperlink {
        case .none: activeHyperlink = nil
        case .open(let payload): activeHyperlink = .pending(payload)
        case .unavailable: activeHyperlink = .unavailable
        }
        terminalTitle = modes.terminalTitle
        iconTitle = modes.iconTitle
        terminalTitleStack = modes.terminalTitleStack
        terminalIconStack = modes.terminalIconStack
        visibilityReportsEnabled = modes.visibilityReportsEnabled
        inBandSizeReportsEnabled = modes.inBandSizeReportsEnabled
        kittyPasteEventsEnabled = modes.kittyPasteEventsEnabled

        resetParserForImport()
        if modes.synchronizedOutputActive {
            beginSynchronizedOutput()
        } else if synchronizedOutputActive {
            endSynchronizedOutput()
        }
        if !snapshot.pendingParserBytes.isEmpty {
            feed(byteArray: snapshot.pendingParserBytes)
        }
        refresh(startRow: 0, endRow: rows - 1)
        tdel?.bufferActivated(source: self)
    }

    private func makeBuffer(_ image: BufferImage, payloads: inout [String: TinyAtom]) -> Buffer {
        let buffer = Buffer(cols: image.cols, rows: image.rows, tabStopWidth: tabStopWidth,
                            scrollback: image.scrollback, bidiState: image.defaultBidiState,
                            arena: cellArena)
        buffer.terminal = self
        if buffer.lines.maxLength != image.lineCapacity {
            buffer.lines.maxLength = image.lineCapacity
        }
        for lineImage in image.lines {
            buffer.lines.push(makeImportedLine(lineImage, arena: buffer.cellArena, payloads: &payloads))
        }
        buffer.x = image.x
        buffer.y = image.y
        buffer.yBase = image.yBase
        buffer.yDisp = image.yDisp
        buffer.xDisp = image.xDisp
        buffer.xBase = image.xBase
        buffer.linesTop = image.linesTop
        buffer.scrollTop = image.scrollTop
        buffer.scrollBottom = image.scrollBottom
        buffer.marginLeft = image.marginLeft
        buffer.marginRight = image.marginRight
        buffer.tabStops = image.tabStops
        buffer.savedX = image.savedX
        buffer.savedY = image.savedY
        buffer.savedOriginMode = image.savedOriginMode
        buffer.savedMarginMode = image.savedMarginMode
        buffer.savedWraparound = image.savedWraparound
        buffer.savedReverseWraparound = image.savedReverseWraparound
        buffer.savedAttr = image.savedAttr
        buffer.savedCharset = image.savedCharset
        buffer.setInsertMode(image.insertMode)
        buffer.setMarginMode(image.marginMode)
        buffer.setWraparound(image.wraparound)
        buffer.semanticContent = image.semanticContent
        buffer.semanticInput = image.semanticInput
        buffer.semanticClickMode = image.semanticClickMode
        buffer.semanticUsesSpecialCursorKeys = image.semanticUsesSpecialCursorKeys
        if let row = image.semanticPromptStartRow, row >= 0, row < buffer.lines.count {
            buffer.semanticPromptStartLine = buffer.lines[row]
            buffer.semanticPromptStartRowCache = row
        }
        buffer.semanticGroupCounter = image.semanticGroupCounter
        buffer.activeSemanticGroupID = image.activeSemanticGroupID
        return buffer
    }

    func makeImportedLine(_ image: LineImage, arena: CellArena,
                          payloads: inout [String: TinyAtom]) -> BufferLine {
        guard let blank = arena.pack(attribute: image.tailAttribute, scalar: 0, widthState: .narrow) else {
            preconditionFailure("The snapshot holds an attribute this arena cannot store")
        }
        let line = BufferLine(cols: image.cols, packedFill: blank, blankTailCell: blank,
                              isWrapped: image.isWrapped, bidiState: image.bidiState, arena: arena)
        var packed: [PackedCell] = []
        packed.reserveCapacity(image.cells.count)
        var lastAttribute: Attribute? = nil
        var lastStyle: UInt16 = 0
        for (column, cell) in image.cells.enumerated() where column < image.cols {
            var payloadCode: UInt16 = 0
            if let text = cell.payload {
                if let atom = payloads[text] {
                    payloadCode = atom.code
                } else if let atom = makePayload(value: text) {
                    payloads[text] = atom
                    payloadCode = atom.code
                }
            }
            // The common cell (one scalar, not blank) packs from the run's style identifier;
            // anything else takes the general path, which owns the blank and grapheme encodings.
            if cell.graphemes == nil, cell.code > 0,
               let widthState = PackedCell.WidthState(rawValue: cell.widthState) {
                if cell.attribute != lastAttribute {
                    lastStyle = arena.intern(attribute: cell.attribute) ?? 0
                    lastAttribute = cell.attribute
                }
                if let fast = arena.pack(styleID: lastStyle, scalar: UInt32(bitPattern: cell.code),
                                         widthState: widthState, payloadCode: payloadCode,
                                         semanticContentCode: cell.semantic, isProtected: cell.isProtected) {
                    packed.append(fast)
                    continue
                }
            }
            let data = CharData(
                attribute: cell.attribute, code: cell.code, graphemeScalarValues: cell.graphemes,
                size: cell.width, widthStateCode: cell.widthState, payloadCode: payloadCode,
                semanticContent: CellArena.semanticContent(for: cell.semantic),
                isProtected: cell.isProtected)
            guard let general = arena.pack(data) else {
                preconditionFailure("The snapshot holds a cell this arena cannot store")
            }
            packed.append(general)
        }
        line.replicationWritePacked(packed)
        line.renderMode = LineImage.renderMode(image.renderMode)
        line.replicationSetSemanticMarks(image.semanticMarks)
        line.semanticHardContinuationGroup = image.hardContinuationGroup
        return line
    }
}
