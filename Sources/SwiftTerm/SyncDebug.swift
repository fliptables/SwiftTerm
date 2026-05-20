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
//  Default-off: the upstream call sites fire on every paint / feedFinish
//  / queue-schedule — once per ~16 ms during active terminal output —
//  which drowns Xcode's console in unparseable spam. Enable on demand
//  for synchronized-output (DEC 2026) diagnostics via the env var
//  `SCAPE_SWIFTTERM_SYNC_DEBUG=1` on the Xcode scheme's "Run" env list
//  (or `launchctl setenv` for an Archive build). When enabled, logs
//  land at `.notice` on subsystem `com.scape.swiftterm` / category
//  `SyncDebug`, queryable via:
//      log show --predicate 'subsystem == "com.scape.swiftterm" AND
//                            category == "SyncDebug"' --last 5m
//

import Foundation
import os

private let syncDebugLogger = Logger(subsystem: "com.scape.swiftterm", category: "SyncDebug")

enum SyncDebug {
    /// One-time read on first access (avoids per-call env lookup).
    static let enabled: Bool = {
        ProcessInfo.processInfo.environment["SCAPE_SWIFTTERM_SYNC_DEBUG"] == "1"
    }()

    @inline(__always)
    static func log(_ message: String) {
        guard enabled else { return }
        syncDebugLogger.notice("\(message, privacy: .public)")
    }
}
