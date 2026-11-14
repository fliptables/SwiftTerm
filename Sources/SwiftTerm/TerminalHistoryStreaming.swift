//
//  TerminalHistoryStreaming.swift
//
//  A snapshot sent in two parts (IT-1149 S2.1, Lloyd's ruling on the T3 budget): the SCREEN
//  PART first (modes, cursor, both buffers' visible grids and everything but their history),
//  which a replica imports and paints at once, then the HISTORY in chunks, nearest the screen
//  first, which the replica inserts above what it already holds while it keeps applying live
//  output. The total history has no size cap; it is proportional to content.
//
//  The rule a host must keep: a chunk is valid only while its buffer keeps the grid it was
//  exported at. A resize, or leaving the alternate screen when the hidden normal buffer was left
//  at an older grid (SwiftTerm reflows it then), reflows history the replica does not hold yet.
//  `importHistoryChunk` refuses such a chunk and the host resends the history (a resync).
//  Live output between chunks is fine: output only ever adds lines below the history.
//

import Foundation

/// A run of history lines of one buffer, top to bottom. Chunk 0 is the one nearest the screen.
public struct TerminalHistoryChunk: Equatable, Sendable {
    /// The snapshot's one format version (IT-2001 format v2).
    public static let formatVersion: UInt32 = TerminalStateSnapshot.formatVersion
    static let magic: [UInt8] = Array("STSH".utf8)

    /// Which buffer the lines belong to.
    public internal(set) var isAlternateBuffer: Bool
    /// 0 for the chunk nearest the screen; a replica applies them in index order.
    public internal(set) var index: Int
    /// How many chunks this buffer's history has.
    public internal(set) var count: Int
    /// The buffer's grid when the chunk was exported; the chunk is refused at any other.
    public internal(set) var bufferCols: Int
    public internal(set) var bufferRows: Int
    var lines: [LineImage]
    /// The row, within `lines`, of the buffer's OSC 133 prompt start, if it is in this chunk.
    var semanticPromptStartRow: Int?

    /// The number of lines in this chunk.
    public var lineCount: Int { lines.count }
}

extension TerminalStateSnapshot {
    /// History lines the screen part left out, over both buffers.
    public var pendingHistoryLineCount: Int { normal.pendingHistoryLines + alt.pendingHistoryLines }
}

/// A snapshot taken for streaming: the screen part, ready now, and the history as line copies
/// in a snapshot arena, so the chunks can be built and encoded off the terminal lock.
public final class TerminalStreamingExport: @unchecked Sendable {
    /// Send first; the replica imports it and paints.
    public let screen: TerminalStateSnapshot
    /// Keeps the snapshot arena the copied lines decode through.
    private let arena: CellArena
    private let history: [(isAlternate: Bool, cols: Int, rows: Int, lines: [BufferLine], promptRow: Int?)]

    init(screen: TerminalStateSnapshot, arena: CellArena,
         history: [(isAlternate: Bool, cols: Int, rows: Int, lines: [BufferLine], promptRow: Int?)]) {
        self.screen = screen
        self.arena = arena
        self.history = history
    }

    /// The history chunks, nearest the screen first, normal buffer before alternate. Call off
    /// the terminal lock, from one thread.
    public func historyChunks(linesPerChunk: Int = 500) -> [TerminalHistoryChunk] {
        precondition(linesPerChunk > 0)
        var chunks: [TerminalHistoryChunk] = []
        var dropped = 0
        for buffer in history {
            var bufferChunks: [TerminalHistoryChunk] = []
            var end = buffer.lines.count
            while end > 0 {
                let start = max(0, end - linesPerChunk)
                var promptRow: Int? = nil
                if let row = buffer.promptRow, row >= start, row < end { promptRow = row - start }
                let images = buffer.lines[start..<end].map { Terminal.lineImage($0, dropped: &dropped) }
                bufferChunks.append(TerminalHistoryChunk(
                    isAlternateBuffer: buffer.isAlternate, index: bufferChunks.count, count: 0,
                    bufferCols: buffer.cols, bufferRows: buffer.rows,
                    lines: images, semanticPromptStartRow: promptRow))
                end = start
            }
            for i in bufferChunks.indices { bufferChunks[i].count = bufferChunks.count }
            chunks.append(contentsOf: bufferChunks)
        }
        return chunks
    }
}

extension Terminal {
    /// Exports the screen part and copies the history for ``TerminalStreamingExport``. Call
    /// under `terminalLock`, between feeds; the cost under the lock is the screen part plus a
    /// packed copy of each history line.
    ///
    /// Returns `nil`, like ``exportState()`` and from the same guard, when
    /// ``hasPendingSequence`` is true: the caller must wait; the next feed that
    /// returns the parser to ground ends the wait.
    public func exportForStreaming() -> TerminalStreamingExport? {
        guard let screen = exportState(skippingHistory: true) else { return nil }
        let arena = replicationCellArena.snapshotCopy()
        var history: [(isAlternate: Bool, cols: Int, rows: Int, lines: [BufferLine], promptRow: Int?)] = []
        for (isAlternate, buffer) in [(false, replicationNormalBuffer), (true, replicationAltBuffer)] {
            let count = min(buffer.replicationYBase, buffer.replicationLines.count)
            guard count > 0 else { continue }
            var copies: [BufferLine] = []
            copies.reserveCapacity(count)
            for index in 0..<count { copies.append(buffer.replicationLines[index].replicationCopy(arena: arena)) }
            var promptRow: Int? = nil
            if let start = buffer.replicationSemanticPromptStartLine, let row = buffer.replicationAbsoluteRow(of: start), row < count {
                promptRow = row
            }
            history.append((isAlternate, buffer.replicationCols, buffer.replicationRows, copies, promptRow))
        }
        return TerminalStreamingExport(screen: screen, arena: arena, history: history)
    }

    /// Inserts a history chunk above the lines this replica holds. Apply a buffer's chunks in
    /// index order after ``importState(_:)`` of its screen part; live output may be fed between
    /// chunks. Lines past the buffer's capacity are trimmed, oldest first, as the owner did.
    /// Returns `false`, changing nothing, when the buffer's grid is no longer the one the chunk
    /// was exported at; the host must then resend the history. Call under `terminalLock`.
    @discardableResult
    public func importHistoryChunk(_ chunk: TerminalHistoryChunk) -> Bool {
        let buffer = chunk.isAlternateBuffer ? replicationAltBuffer : replicationNormalBuffer
        guard buffer.replicationCols == chunk.bufferCols, buffer.replicationRows == chunk.bufferRows else { return false }
        var payloads: [String: TinyAtom] = [:]
        let lines = chunk.lines.map { makeImportedLine($0, arena: buffer.replicationCellArena, payloads: &payloads) }
        guard !lines.isEmpty else { return true }
        let capacity = buffer.replicationLines.maxLength
        let kept = max(0, min(lines.count, capacity - buffer.replicationLines.count))
        let trimmed = lines.count - kept
        if kept > 0 {
            buffer.replicationLines.splice(start: 0, deleteCount: 0, items: Array(lines[trimmed...]), change: { _ in })
        }
        buffer.replicationLinesTop += trimmed
        buffer.replicationYBase += kept
        buffer.yDisp += kept
        if let row = chunk.semanticPromptStartRow, row >= trimmed {
            buffer.replicationSemanticPromptStartLine = lines[row]
            buffer.replicationSemanticPromptStartRowCache = row - trimmed
        } else if buffer.replicationSemanticPromptStartLine != nil {
            buffer.replicationSemanticPromptStartRowCache += kept
        }
        refresh(startRow: 0, endRow: rows - 1)
        return true
    }
}

// MARK: - Encoding

extension TerminalHistoryChunk {
    /// The binary form: "STSH", a little-endian UInt32 version, then the chunk.
    public func encoded() -> [UInt8] {
        var w = SnapshotWriter()
        w.bytes.append(contentsOf: TerminalHistoryChunk.magic)
        withUnsafeBytes(of: TerminalHistoryChunk.formatVersion.littleEndian) { w.bytes.append(contentsOf: $0) }
        var attributes = AttributeTable()
        var payloads = PayloadTable()
        var body = SnapshotWriter()
        body.bool(isAlternateBuffer); body.uint(index); body.uint(count)
        body.uint(bufferCols); body.uint(bufferRows)
        body.optional(semanticPromptStartRow) { $0.uint($1) }
        body.uint(lines.count)
        for line in lines { line.encode(&body, attributes: &attributes, payloads: &payloads) }
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
        guard Array(bytes[0..<4]) == TerminalHistoryChunk.magic else { throw TerminalStateSnapshotError.badMagic }
        let version = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        guard version == TerminalHistoryChunk.formatVersion else {
            throw TerminalStateSnapshotError.unsupportedVersion(version)
        }
        var r = SnapshotReader(bytes: bytes, position: 8)
        let attributeCount = try r.count(max: bytes.count, "attribute table")
        var attributes: [Attribute] = []
        for _ in 0..<attributeCount { attributes.append(try SnapshotCodec.readAttribute(&r)) }
        let payloadCount = try r.count(max: bytes.count, "payload table")
        var payloads: [String] = []
        for _ in 0..<payloadCount { payloads.append(try r.string()) }
        isAlternateBuffer = try r.bool()
        index = try r.uint()
        count = try r.uint()
        guard index < count else { throw TerminalStateSnapshotError.invalid("chunk index") }
        bufferCols = try r.count(max: 65535, "chunk cols")
        bufferRows = try r.count(max: 65535, "chunk rows")
        semanticPromptStartRow = try r.optional { try $0.uint() }
        let lineCount = try r.count(max: bytes.count, "lines")
        var decoded: [LineImage] = []
        decoded.reserveCapacity(lineCount)
        for _ in 0..<lineCount { decoded.append(try LineImage(&r, attributes: attributes, payloads: payloads)) }
        lines = decoded
        if let row = semanticPromptStartRow, row >= lines.count { throw TerminalStateSnapshotError.invalid("prompt row") }
        guard r.position == bytes.count else { throw TerminalStateSnapshotError.invalid("trailing bytes") }
    }
}
