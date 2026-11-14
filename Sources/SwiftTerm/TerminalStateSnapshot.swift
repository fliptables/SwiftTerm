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
//  Kitty keyboard stacks; titles and their stacks; the colours an application
//  set with OSC 10, 11 and 12; and the program status records. It is taken
//  only at ground, so no parser state travels.
//
//  Which fields: the census (ReplicationCensusTests). A field is carried when
//  a reader of the replica can observe it: what is drawn, what the next byte
//  does, what a query would answer, what a key at the viewer sends.
//
//  What it does not carry, by design (each is listed in `notCarried`):
//  - Kitty graphics and sixel images: declared lost until the application
//    redraws. An import clears the importer's images.
//  - Host configuration the importing view owns: the installed palette and
//    default colours (an OSC colour is installed over the importer's own), the
//    options it was created with (only the cursor style, which an application
//    changes, is carried), selection, scroll position chosen by the user,
//    focus, visibility and pixel geometry.
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
    /// The version of ``encoded()`` and of ``TerminalHistoryChunk/encoded()``
    /// (one constant for both). A decoder refuses any other, version 1 included.
    public static let formatVersion: UInt32 = 2
    /// Decode's memory bounds. A host must keep scrollback ≤ `maximumScrollback` and
    /// (scrollback + rows) × cols, plus the alternate screen's rows × cols, ≤ `maximumCells`;
    /// beyond either, its snapshots fail to decode (an error, never a crash).
    public static let maximumScrollback = 1 << 24
    /// See ``maximumScrollback``: the cells of both buffers' lines together (8 bytes each).
    public static let maximumCells = 1 << 26
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
    /// Cells whose payload was dropped because it was not a `String`.
    public internal(set) var droppedPayloadCount: Int
}

// MARK: - The model images

struct RGB16: Equatable, Sendable {
    var red: UInt16, green: UInt16, blue: UInt16
}

extension RGB16 {
    init(_ color: Color) { self.init(red: color.red, green: color.green, blue: color.blue) }
    var color: Color { Color(red: red, green: green, blue: blue) }
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
    // Format v2
    var cursorStartsNewGrapheme: Bool
    var keyboardActionMode: Bool
    var sendReceiveMode: Bool
    var backarrowKeyMode: Bool
    /// `Terminal.CharacterProtectionMode`: 0 off, 1 dec, 2 iso.
    var characterProtectionMode: UInt8
    var characterProtection: Bool
    var reverseWraparoundExtended: Bool
    var noClearOnColumnChange: Bool
    var reportedDECModes: [Int]
    var attributeChangeExtent: Int
    var moreFix: Bool
    /// The colours set by OSC 10, 11 and 12, without the host colour under them.
    var oscForeground: RGB16?
    var oscBackground: RGB16?
    var cursorColor: RGB16?
    /// Oldest update first.
    var programStatus: [TerminalProgramStatus]
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
    var savedCharacterProtection: Bool
    var savedPendingWrap: Bool
    var savedAttr: Attribute
    var savedCharset: [UInt8: String]?
    var insertMode: Bool
    var marginMode: Bool
    var wraparound: Bool
    var characterProtection: Bool
    /// Restored last: a cursor move clears it.
    var pendingWrap: Bool
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
    ///
    /// Returns `nil`, reading and changing nothing, while
    /// ``hasPendingSequence`` is true: the parser is inside a sequence, or a
    /// UTF-8 character is cut, and a snapshot taken now would put a replica's
    /// parser in ground. The caller must wait; the next feed that returns the
    /// parser to ground ends the wait.
    public func exportState() -> TerminalStateSnapshot? {
        exportState(skippingHistory: false)
    }

    func exportState(skippingHistory: Bool) -> TerminalStateSnapshot? {
        guard !hasPendingSequence else { return nil }
        var dropped = 0
        let modes = TerminalModesImage(
            cols: cols, rows: rows,
            altActive: isCurrentBufferAlternate,
            cursorStyle: options.cursorStyle,
            synchronizedOutputActive: synchronizedOutputActive,
            applicationKeypad: replicationApplicationKeypad,
            applicationCursor: applicationCursor,
            reverseColors: replicationReverseColors,
            kittyNormal: KittyKeyboardImage(flags: replicationKeyboardModeNormal.flags.rawValue,
                                            stack: replicationKeyboardModeNormal.stack.map { $0.rawValue }),
            kittyAlt: KittyKeyboardImage(flags: replicationKeyboardModeAlt.flags.rawValue,
                                         stack: replicationKeyboardModeAlt.stack.map { $0.rawValue }),
            sendFocus: replicationSendFocus,
            currentBidiState: replicationCurrentBidiState,
            bidiArrowKeySwap: bidiArrowKeySwap,
            savedPrivateModes: replicationSavedPrivateModes,
            cursorHidden: replicationCursorHidden,
            originMode: replicationOriginMode,
            marginMode: replicationMarginMode,
            insertMode: replicationInsertMode,
            wraparound: replicationWraparound,
            bracketedPasteMode: bracketedPasteMode,
            alternateScrollMode: alternateScrollMode,
            colorSchemeUpdatesEnabled: colorSchemeUpdatesEnabled,
            colorSchemeIsLight: colorScheme == .light,
            charset: replicationCharset,
            gCharsets: replicationGCharsets,
            reverseWraparound: replicationReverseWraparound,
            currentAttribute: currentAttribute,
            gLevel: replicationGLevel,
            cursorBlink: replicationCursorBlink,
            allow80To132: replicationAllow80To132,
            lineFeedMode: replicationLineFeedMode,
            smoothScroll: replicationSmoothScroll,
            paletteOverrides: paletteOverrides(),
            send8bit: replicationSend8bit,
            hostCurrentDirectory: hostCurrentDirectory,
            hostCurrentDocument: hostCurrentDocument,
            mouseProtocol: replicationMouseProtocol,
            mouseMode: mouseMode,
            mouseShiftCapture: mouseShiftCapture,
            xtermTitleSetUtf: replicationXtermTitleSetUtf,
            xtermTitleSetHex: replicationXtermTitleSetHex,
            xtermTitleQueryUtf: replicationXtermTitleQueryUtf,
            xtermTitleQueryHex: replicationXtermTitleQueryHex,
            conformance: replicationConformance,
            activeHyperlink: activeHyperlinkImage(),
            terminalTitle: replicationTerminalTitle,
            iconTitle: replicationIconTitle,
            terminalTitleStack: replicationTerminalTitleStack,
            terminalIconStack: replicationTerminalIconStack,
            visibilityReportsEnabled: visibilityReportsEnabled,
            inBandSizeReportsEnabled: inBandSizeReportsEnabled,
            kittyPasteEventsEnabled: kittyPasteEventsEnabled,
            cursorStartsNewGrapheme: replicationCursorStartsNewGrapheme,
            keyboardActionMode: replicationKeyboardActionMode,
            sendReceiveMode: replicationSendReceiveMode,
            backarrowKeyMode: replicationBackarrowKeyMode,
            characterProtectionMode: replicationCharacterProtectionModeCode,
            characterProtection: replicationCharacterProtection,
            reverseWraparoundExtended: replicationReverseWraparoundExtended,
            noClearOnColumnChange: replicationNoClearOnColumnChange,
            reportedDECModes: replicationReportedDECModes.sorted(),
            attributeChangeExtent: replicationAttributeChangeExtent,
            moreFix: replicationMoreFix,
            oscForeground: replicationOscForeground.map(RGB16.init),
            oscBackground: replicationOscBackground.map(RGB16.init),
            cursorColor: cursorColor.map(RGB16.init),
            programStatus: replicationProgramStatusRecords)
        let normalImage = Terminal.bufferImage(replicationNormalBuffer, dropped: &dropped, skippingHistory: skippingHistory)
        let altImage = Terminal.bufferImage(replicationAltBuffer, dropped: &dropped, skippingHistory: skippingHistory)
        return TerminalStateSnapshot(
            modes: modes, normal: normalImage, alt: altImage,
            droppedPayloadCount: dropped)
    }

    private func paletteOverrides() -> [Int: RGB16] {
        var result: [Int: RGB16] = [:]
        let ansiColors = replicationAnsiColors
        let defaultAnsiColors = replicationDefaultAnsiColors
        for index in 0..<min(ansiColors.count, defaultAnsiColors.count)
        where ansiColors[index] != defaultAnsiColors[index] {
            let color = ansiColors[index]
            result[index] = RGB16(red: color.red, green: color.green, blue: color.blue)
        }
        return result
    }

    private func activeHyperlinkImage() -> HyperlinkImage {
        switch replicationActiveHyperlinkTarget(missingTarget: "") {
        case nil: return .none
        case .some(.some(let target)): return .open(target)
        case .some(nil): return .unavailable
        }
    }

    static func bufferImage(_ buffer: Buffer, dropped: inout Int, skippingHistory: Bool = false) -> BufferImage {
        // History streams only for a buffer with scrollback; the alternate buffer's few lines
        // above yBase go whole in the screen part.
        let history = skippingHistory && buffer.replicationHasScrollback
            ? min(buffer.replicationYBase, buffer.replicationLines.count) : 0
        var lines: [LineImage] = []
        lines.reserveCapacity(buffer.replicationLines.count - history)
        for index in history..<buffer.replicationLines.count {
            lines.append(lineImage(buffer.replicationLines[index], dropped: &dropped))
        }
        var startRow: Int? = nil
        if let start = buffer.replicationSemanticPromptStartLine, let row = buffer.replicationAbsoluteRow(of: start) {
            startRow = row >= history ? row - history : nil
        }
        return BufferImage(
            cols: buffer.replicationCols, rows: buffer.replicationRows, scrollback: buffer.replicationScrollback,
            lineCapacity: buffer.replicationLines.maxLength,
            pendingHistoryLines: history,
            lines: lines,
            x: buffer.x, y: buffer.y, yBase: buffer.replicationYBase - history, yDisp: max(0, buffer.yDisp - history),
            linesTop: buffer.replicationLinesTop,
            scrollTop: buffer.scrollTop, scrollBottom: buffer.scrollBottom,
            marginLeft: buffer.marginLeft, marginRight: buffer.marginRight,
            tabStops: buffer.replicationTabStops,
            savedX: buffer.savedX, savedY: buffer.savedY,
            savedOriginMode: buffer.replicationSavedOriginMode,
            savedMarginMode: buffer.replicationSavedMarginMode,
            savedCharacterProtection: buffer.replicationSavedCharacterProtection,
            savedPendingWrap: buffer.replicationSavedPendingWrap,
            savedAttr: buffer.savedAttr, savedCharset: buffer.savedCharset,
            insertMode: buffer.replicationInsertMode, marginMode: buffer.replicationMarginMode,
            wraparound: buffer.replicationWraparound,
            characterProtection: buffer.replicationCharacterProtection,
            pendingWrap: buffer.replicationPendingWrap,
            semanticContent: buffer.replicationSemanticContent,
            semanticInput: buffer.replicationSemanticInput,
            semanticClickMode: buffer.replicationSemanticClickMode,
            semanticUsesSpecialCursorKeys: buffer.replicationSemanticUsesSpecialCursorKeys,
            semanticPromptStartRow: startRow,
            semanticGroupCounter: buffer.replicationSemanticGroupCounter,
            activeSemanticGroupID: buffer.replicationActiveSemanticGroupID,
            defaultBidiState: buffer.replicationDefaultBidiState)
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
            renderMode: LineImage.code(line.replicationRenderMode), semanticMarks: line.replicationSemanticMarks,
            hardContinuationGroup: line.replicationSemanticHardContinuationGroup,
            tailAttribute: line.replicationTailAttribute, cells: cells)
    }
}

// MARK: - Import

extension Terminal {
    /// Replaces this terminal's emulator state with `snapshot`. Call under
    /// `terminalLock`, on a terminal whose palette strategy matches the
    /// exporter's; the buffers are rebuilt with the exporter's scrollback, whatever
    /// this terminal's options say. A replica sets ``respondsToQueries`` to
    /// `false` first.
    ///
    /// The importer's images are cleared (images are not carried), and the
    /// colours an application set with OSC 10, 11 and 12 are installed over the
    /// importer's own host colours, telling the delegate as those sequences do.
    /// `cursorColor` is carried as set: a host that writes it directly (not
    /// through the view's caret colour) loses that value at import.
    /// Delegate notifications during import (program status, the three colours)
    /// see the new modes and buffers; the screen is refreshed after.
    public func importState(_ snapshot: TerminalStateSnapshot) {
        let modes = snapshot.modes
        var payloads: [String: TinyAtom] = [:]

        // Upstream's own clear, as RIS does: nothing stale is drawn over the import.
        replicationClearImages()

        replicationCols = modes.cols
        replicationRows = modes.rows
        options.cols = modes.cols
        options.rows = modes.rows

        let normal = makeBuffer(snapshot.normal, payloads: &payloads)
        let alt = makeBuffer(snapshot.alt, payloads: &payloads)
        replicationNormalBuffer = normal
        replicationAltBuffer = alt
        replicationActiveBuffer = modes.altActive ? alt : normal
        replicationKittyGraphicsActiveIsAlternate = modes.altActive

        options.cursorStyle = modes.cursorStyle
        replicationApplicationKeypad = modes.applicationKeypad
        applicationCursor = modes.applicationCursor
        replicationReverseColors = modes.reverseColors
        replicationKeyboardModeNormal = (
            flags: KittyKeyboardFlags(rawValue: modes.kittyNormal.flags),
            stack: modes.kittyNormal.stack.map(KittyKeyboardFlags.init(rawValue:)))
        replicationKeyboardModeAlt = (
            flags: KittyKeyboardFlags(rawValue: modes.kittyAlt.flags),
            stack: modes.kittyAlt.stack.map(KittyKeyboardFlags.init(rawValue:)))
        replicationSendFocus = modes.sendFocus
        replicationCurrentBidiState = modes.currentBidiState
        bidiArrowKeySwap = modes.bidiArrowKeySwap
        replicationSavedPrivateModes = modes.savedPrivateModes
        replicationCursorHidden = modes.cursorHidden
        replicationOriginMode = modes.originMode
        replicationMarginMode = modes.marginMode
        replicationInsertMode = modes.insertMode
        replicationWraparound = modes.wraparound
        replicationBracketedPasteMode = modes.bracketedPasteMode
        replicationAlternateScrollMode = modes.alternateScrollMode
        replicationColorSchemeUpdatesEnabled = modes.colorSchemeUpdatesEnabled
        replicationColorScheme = modes.colorSchemeIsLight ? .light : .dark
        replicationCharset = modes.charset
        replicationGCharsets = modes.gCharsets
        replicationReverseWraparound = modes.reverseWraparound
        replicationSetCurrentAttribute(modes.currentAttribute)
        replicationGLevel = modes.gLevel
        replicationCursorBlink = modes.cursorBlink
        replicationAllow80To132 = modes.allow80To132
        replicationLineFeedMode = modes.lineFeedMode
        replicationSmoothScroll = modes.smoothScroll
        // Built in a local and stored once, so the palette is not copied per override.
        var ansiColors = replicationDefaultAnsiColors
        for (index, rgb) in modes.paletteOverrides where index < ansiColors.count {
            ansiColors[index] = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
        replicationAnsiColors = ansiColors
        replicationSend8bit = modes.send8bit
        replicationHostCurrentDirectory = modes.hostCurrentDirectory
        replicationHostCurrentDocument = modes.hostCurrentDocument
        replicationMouseProtocol = modes.mouseProtocol
        replicationMouseMode = modes.mouseMode
        replicationMouseShiftCapture = modes.mouseShiftCapture
        replicationXtermTitleSetUtf = modes.xtermTitleSetUtf
        replicationXtermTitleSetHex = modes.xtermTitleSetHex
        replicationXtermTitleQueryUtf = modes.xtermTitleQueryUtf
        replicationXtermTitleQueryHex = modes.xtermTitleQueryHex
        replicationConformance = modes.conformance
        switch modes.activeHyperlink {
        case .none: replicationSetActiveHyperlink(nil)
        case .open(let payload): replicationSetActiveHyperlink(.some(payload))
        case .unavailable: replicationSetActiveHyperlink(.some(nil))
        }
        replicationTerminalTitle = modes.terminalTitle
        replicationIconTitle = modes.iconTitle
        replicationTerminalTitleStack = modes.terminalTitleStack
        replicationTerminalIconStack = modes.terminalIconStack
        replicationVisibilityReportsEnabled = modes.visibilityReportsEnabled
        replicationInBandSizeReportsEnabled = modes.inBandSizeReportsEnabled
        replicationKittyPasteEventsEnabled = modes.kittyPasteEventsEnabled
        replicationKeyboardActionMode = modes.keyboardActionMode
        replicationSendReceiveMode = modes.sendReceiveMode
        replicationBackarrowKeyMode = modes.backarrowKeyMode
        replicationCharacterProtectionModeCode = modes.characterProtectionMode
        // The flag only: each buffer's own protection is restored with the buffer.
        replicationCharacterProtection = modes.characterProtection
        replicationReverseWraparoundExtended = modes.reverseWraparoundExtended
        replicationNoClearOnColumnChange = modes.noClearOnColumnChange
        replicationReportedDECModes = Set(modes.reportedDECModes)
        replicationAttributeChangeExtent = modes.attributeChangeExtent
        replicationMoreFix = modes.moreFix
        replicationSetProgramStatusRecords(modes.programStatus)

        replicationResetParser()
        if modes.synchronizedOutputActive {
            replicationBeginSynchronizedOutput()
        } else if synchronizedOutputActive {
            replicationEndSynchronizedOutput()
        }
        replicationSetOscColors(foreground: modes.oscForeground?.color, background: modes.oscBackground?.color,
                                cursor: modes.cursorColor?.color)
        replicationCursorStartsNewGrapheme = modes.cursorStartsNewGrapheme
        // Last: anything that moves the cursor clears it.
        normal.replicationPendingWrap = snapshot.normal.pendingWrap
        alt.replicationPendingWrap = snapshot.alt.pendingWrap
        refresh(startRow: 0, endRow: rows - 1)
        replicationNotifyBufferActivated()
    }

    private func makeBuffer(_ image: BufferImage, payloads: inout [String: TinyAtom]) -> Buffer {
        let buffer = Buffer.replicationMake(cols: image.cols, rows: image.rows, tabWidth: replicationTabStopWidth,
                                            scrollback: image.scrollback, bidiState: image.defaultBidiState,
                                            arena: replicationCellArena)
        buffer.replicationTerminal = self
        if buffer.replicationLines.maxLength != image.lineCapacity {
            buffer.replicationLines.maxLength = image.lineCapacity
        }
        for lineImage in image.lines {
            buffer.replicationLines.push(makeImportedLine(lineImage, arena: buffer.replicationCellArena, payloads: &payloads))
        }
        buffer.x = image.x
        buffer.y = image.y
        buffer.replicationYBase = image.yBase
        buffer.yDisp = image.yDisp
        buffer.replicationLinesTop = image.linesTop
        buffer.scrollTop = image.scrollTop
        buffer.scrollBottom = image.scrollBottom
        buffer.marginLeft = image.marginLeft
        buffer.marginRight = image.marginRight
        buffer.replicationTabStops = image.tabStops
        buffer.savedX = image.savedX
        buffer.savedY = image.savedY
        buffer.replicationSavedOriginMode = image.savedOriginMode
        buffer.replicationSavedMarginMode = image.savedMarginMode
        buffer.replicationSavedCharacterProtection = image.savedCharacterProtection
        buffer.replicationSavedPendingWrap = image.savedPendingWrap
        buffer.savedAttr = image.savedAttr
        buffer.savedCharset = image.savedCharset
        buffer.replicationSetInsertMode(image.insertMode)
        buffer.replicationSetMarginMode(image.marginMode)
        buffer.replicationSetWraparound(image.wraparound)
        buffer.replicationSetCharacterProtection(image.characterProtection)
        buffer.replicationSemanticContent = image.semanticContent
        buffer.replicationSemanticInput = image.semanticInput
        buffer.replicationSemanticClickMode = image.semanticClickMode
        buffer.replicationSemanticUsesSpecialCursorKeys = image.semanticUsesSpecialCursorKeys
        if let row = image.semanticPromptStartRow, row >= 0, row < buffer.replicationLines.count {
            buffer.replicationSemanticPromptStartLine = buffer.replicationLines[row]
            buffer.replicationSemanticPromptStartRowCache = row
        }
        buffer.replicationSemanticGroupCounter = image.semanticGroupCounter
        buffer.replicationActiveSemanticGroupID = image.activeSemanticGroupID
        return buffer
    }

    func makeImportedLine(_ image: LineImage, arena: CellArena,
                          payloads: inout [String: TinyAtom]) -> BufferLine {
        guard let blank = arena.pack(attribute: image.tailAttribute, scalar: 0, widthState: .narrow) else {
            preconditionFailure("The snapshot holds an attribute this arena cannot store")
        }
        let line = BufferLine.replicationMake(cols: image.cols, packedFill: blank, blankTailCell: blank,
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
        line.replicationRenderMode = LineImage.renderMode(image.renderMode)
        line.replicationSetSemanticMarks(image.semanticMarks)
        line.replicationSemanticHardContinuationGroup = image.hardContinuationGroup
        return line
    }
}
