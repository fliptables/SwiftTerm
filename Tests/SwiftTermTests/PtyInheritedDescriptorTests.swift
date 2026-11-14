#if os(macOS) || os(Linux)
import Foundation
import Testing
import SwiftTerm

/// IT-2001: the child of `PseudoTerminalHelpers.fork(andExec:…)` closes every
/// descriptor >= 3 it inherited before exec.
///
/// On every platform the existing close loop (fd 3 ..< fdLimit, fdLimit sampled
/// in the parent) closes a leaked descriptor below the limit; that assertion holds
/// on both paths and both platforms. On Linux the child calls close_range(3, ~0U, 0)
/// first (resolved with dlsym in the parent) and keeps the loop as the fallback for
/// any non-zero return. Measured on Linux CI (RLIMIT_NOFILE 65536): the loop costs
/// ~20 ms per session start, close_range ~0.2 ms.
///
/// WHICH PATH RAN, reported by the child itself and without a single extra byte from
/// the product: the two paths differ on a descriptor at or above fdLimit. The loop
/// stops at fdLimit; close_range closes everything. So the Linux test opens a
/// descriptor at 20000, lowers the soft RLIMIT_NOFILE to 10240 (fdLimit's floor)
/// for the moment of the fork, and the child's shell reports whether fd 20000 is
/// still open: "closed" = close_range ran, "open" = the loop ran. The soft limit is
/// restored right after the fork returns; the descriptors are closed after the child
/// exits. (Lowering the soft limit below an open descriptor is allowed; it only
/// stops new allocations above it. This is the only setrlimit in the repository and
/// it is test-only.)
///
/// The Mac run is meaningful for the loop (the leak below fdLimit); the Linux CI run
/// is the real test of the close_range path.
@Suite(.serialized)
struct PtyInheritedDescriptorTests {
    private static let lowDescriptor: Int32 = 200
    private static let highDescriptor: Int32 = 20_000

#if os(macOS)
    private static let descriptorDirectory = "/dev/fd"
#else
    private static let descriptorDirectory = "/proc/self/fd"
#endif

    /// Opens a pipe WITHOUT close-on-exec and moves its write end to `number`.
    private static func leak(at number: Int32) -> Int32? {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return nil }
        defer {
            close(ends[0])
            close(ends[1])
        }
        guard dup2(ends[1], number) == number else { return nil }
        // dup2 clears FD_CLOEXEC on the new descriptor: it is inheritable.
        return number
    }

    /// Runs `/bin/sh -c script` under a pty and returns what it printed and its exit status.
    private static func run(_ script: String) -> (output: String, status: Int32)? {
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard let (pid, master) = PseudoTerminalHelpers.fork(
            andExec: "/bin/sh", args: ["sh", "-c", script], env: ["PATH=/usr/bin:/bin"],
            desiredWindowSize: &size) else {
            return nil
        }
        return collect(pid: pid, master: master)
    }

    private static func collect(pid: pid_t, master: Int32) -> (output: String, status: Int32) {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = read(master, &buffer, buffer.count)
            if count > 0 {
                bytes.append(contentsOf: buffer[0..<count])
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break // 0 or EIO: the child closed the slave
            }
        }
        close(master)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let output = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output, status)
    }

    /// The probe: prints "<name>:open" or "<name>:closed" for each descriptor.
    private static func probe(_ descriptors: [(String, Int32)]) -> String {
        // `$$` is the shell itself, so the Linux path names the child's own table.
        let directory = descriptorDirectory == "/proc/self/fd" ? "/proc/$$/fd" : descriptorDirectory
        return descriptors.map { name, number in
            "if [ -e \(directory)/\(number) ]; then printf '\(name):open '; else printf '\(name):closed '; fi"
        }.joined(separator: "; ")
    }

    @Test func aLeakedDescriptorBelowTheLimitIsClosedInTheChild() throws {
        let low = try #require(Self.leak(at: Self.lowDescriptor), "dup2 to \(Self.lowDescriptor) failed")
        defer { close(low) }
        // The parent really holds it: the probe must not pass vacuously.
        #expect(fcntl(low, F_GETFD) >= 0)
        // fd 0 (the pty) is the probe's control: it must read "open".
        let result = try #require(Self.run(Self.probe([("tty", 0), ("low", low)])), "fork(andExec:) failed")
        #expect(result.output == "tty:open low:closed", "the child inherited fd \(low): \(result.output)")
#if os(macOS)
        print("IT-2001 Pty close path: loop (macOS has no close_range); child said \"\(result.output)\"")
#endif
    }

#if os(Linux)
    typealias CloseRange = @convention(c) (UInt32, UInt32, Int32) -> Int32

    // Glibc imports RLIMIT_NOFILE as a case of `enum __rlimit_resource`; getrlimit takes an Int32.
#if canImport(Glibc)
    private static let nofile = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
#else
    private static let nofile = RLIMIT_NOFILE
#endif

    /// close_range as this process's libc exports it (independent of SwiftTerm's own lookup).
    private static func libcCloseRange() -> CloseRange? {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "close_range") else { return nil }
        return unsafeBitCast(symbol, to: CloseRange.self)
    }

    @Test func theChildReportsWhichPathClosedItsDescriptors() throws {
        // Can this kernel (and any seccomp filter on this runner) run close_range at all?
        // Asked in-process on a scratch descriptor; a child inherits the same filter.
        var probeReturn: Int32 = -1
        var probeErrno: Int32 = 0
        let closeRange = Self.libcCloseRange()
        if let closeRange {
            let scratch = open("/dev/null", O_RDONLY)
            try #require(scratch >= 0)
            probeReturn = closeRange(UInt32(scratch), UInt32(scratch), 0)
            probeErrno = errno
            if probeReturn != 0 { close(scratch) }
        }

        var limit = rlimit()
        try #require(getrlimit(Self.nofile, &limit) == 0)
        let original = limit
        guard limit.rlim_max > rlim_t(Self.highDescriptor) else {
            print("IT-2001 Pty close path: untestable, RLIMIT_NOFILE hard limit \(limit.rlim_max) <= \(Self.highDescriptor)")
            return
        }
        if limit.rlim_cur <= rlim_t(Self.highDescriptor) {
            limit.rlim_cur = rlim_t(Self.highDescriptor) + 1
            try #require(setrlimit(Self.nofile, &limit) == 0)
        }
        let low = try #require(Self.leak(at: Self.lowDescriptor))
        defer { close(low) }
        let high = try #require(Self.leak(at: Self.highDescriptor))
        defer { close(high) }

        // fdLimit = max(getdtablesize(), 10240) = 10240 for this one fork.
        var lowered = original
        lowered.rlim_cur = 10_240
        try #require(setrlimit(Self.nofile, &lowered) == 0)
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        let forked = PseudoTerminalHelpers.fork(
            andExec: "/bin/sh", args: ["sh", "-c", Self.probe([("tty", 0), ("low", low), ("high", high)])],
            env: ["PATH=/usr/bin:/bin"], desiredWindowSize: &size)
        var restore = original
        #expect(setrlimit(Self.nofile, &restore) == 0)
        let (pid, master) = try #require(forked, "fork(andExec:) failed")
        let result = Self.collect(pid: pid, master: master)

        // Both paths close a descriptor below fdLimit.
        #expect(result.output.hasPrefix("tty:open low:closed"),"the child inherited fd \(low): \(result.output)")
        let path = result.output.hasSuffix("high:closed") ? "close_range" : "loop"
        // Printed on EVERY run, pass included: the CI log is where the path is read.
        print("IT-2001 Pty close path: \(path) (libc close_range \(closeRange == nil ? "absent" : "present"); "
              + "in-process rc=\(probeReturn) errno=\(probeErrno); child said \"\(result.output)\")")
        if closeRange != nil && probeReturn == 0 {
            // The kernel accepts it here, so a fallback would be a silent regression.
            #expect(path == "close_range", "close_range is available but the child ran the loop: \(result.output)")
        }
    }
#endif
}
#endif
