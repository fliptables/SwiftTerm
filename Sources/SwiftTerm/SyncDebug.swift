//
//  SyncDebug.swift
//
//  Local stub for upstream's SyncDebug helper. Upstream commit 9446f60
//  ("Simplifies the DEC 2026 buffering support, which was causing updates
//  to not flush to the screen on time") introduced `SyncDebug.log(...)`
//  call sites in `AppleTerminalView.swift` and `Terminal.swift` without
//  committing the `SyncDebug` enum definition. The build breaks without
//  this stub. Drop this file when upstream publishes a real definition.
//
//  Wired to `os.Logger` at `.notice` level so the synchronized-output
//  path produces queryable diagnostic logs via `log show --predicate
//  'subsystem == "com.scape.swiftterm" AND category == "SyncDebug"'`.
//

import Foundation
import os

private let syncDebugLogger = Logger(subsystem: "com.scape.swiftterm", category: "SyncDebug")

enum SyncDebug {
    @inline(__always)
    static func log(_ message: String) {
        syncDebugLogger.notice("\(message, privacy: .public)")
    }
}
