//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 3/4/20.
//

import Foundation
#if !os(iOS) && !os(tvOS) && !os(Windows)

/**
 * APIs to assist in controlling a Unix pseudo-terminal from Swift.
 *
 *This provides a wrapper for
 * the libc `forkpty`API in the form of `fork(andExec:args:env:desiredWindowSize:` method,
 * `setWinSize` and `availableBytes`
 */
public class PseudoTerminalHelpers {
    private struct CStringArray {
        let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        let count: Int
    }

    private static func allocateCStringArray(_ strings: [String]) -> CStringArray? {
        let base = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        var initializedCount = 0

        for (index, string) in strings.enumerated() {
            guard let duplicated = strdup(string) else {
                for cleanupIndex in 0..<initializedCount {
                    free(base[cleanupIndex])
                }
                base.deallocate()
                return nil
            }
            base[index] = duplicated
            initializedCount += 1
        }

        base[strings.count] = nil
        return CStringArray(base: base, count: strings.count)
    }

    private static func freeCStringArray(_ array: CStringArray) {
        for index in 0..<array.count {
            free(array.base[index])
        }
        array.base.deallocate()
    }

    /**
     * This method both forks and executes the provided command under a Pseudo Terminal (pty)
     * - Parameter andExec: the name of the executable to run
     * - Parameter args: arguments to be passed to the executable
     * - Parameter env: the environment variables for the child process
     * - Parameter desiredWindowSize: the window size that will be set on the pseudo terminal.
     *
     * - Returns: nil on error, or a tuple containing the process ID, and the file descriptor to the primary side of the newly created pseudo-terminal.
     */
    public static func fork (andExec: String, args: [String], env: [String], currentDirectory: String? = nil, desiredWindowSize: inout winsize) -> (pid: pid_t, masterFd: Int32)?
    {
        guard let cArgs = allocateCStringArray(args) else {
            return nil
        }
        guard let cEnv = allocateCStringArray(env) else {
            freeCStringArray(cArgs)
            return nil
        }
        guard let cExecutable = strdup(andExec) else {
            freeCStringArray(cEnv)
            freeCStringArray(cArgs)
            return nil
        }

        var cCurrentDirectory: UnsafeMutablePointer<CChar>?
        if let currentDirectory {
            guard let duplicatedCurrentDirectory = strdup(currentDirectory) else {
                free(cExecutable)
                freeCStringArray(cEnv)
                freeCStringArray(cArgs)
                return nil
            }
            cCurrentDirectory = duplicatedCurrentDirectory
        }

        defer {
            freeCStringArray(cArgs)
            freeCStringArray(cEnv)
            free(cExecutable)
            if let cCurrentDirectory {
                free(cCurrentDirectory)
            }
        }

        var master: Int32 = 0

        // Exclusive upper bound for the child's fd close loop, sampled BEFORE
        // fork. On Darwin getdtablesize() == min(RLIMIT_NOFILE soft limit,
        // kern.maxfilesperproc), which is the exclusive upper bound on
        // allocatable fd NUMBERS: dup2/open to any number >= it fails EBADF
        // (empirically verified — see Scape
        // docs/spikes/2026-07-19-it301-fd-hygiene-fix-findings.md).
        // Precomputed in the parent because getdtablesize() is not among the
        // portable async-signal-safe functions; the child loop below must be
        // only close() + scalar arithmetic. Floor of OPEN_MAX (10240) guards
        // a failed/absurd return. PRECONDITION: the sample is safe only in
        // the absence of ANY concurrent RLIMIT_NOFILE mutation — in either
        // direction. A LOWER after descriptors exist strands fds above the
        // sampled bound; a RAISE between this sample and forkpty lets a
        // concurrent thread allocate an fd above the sampled bound that the
        // child sweep then misses (sample 2,560 → raise → open fd 70,000 →
        // fork → sweep stops at 2,559). No setrlimit caller exists in Scape
        // or SwiftTerm (grep-verified 2026-07-19); if one is ever added,
        // revisit this bound.
        let fdLimit = max(getdtablesize(), 10240)

        let pid = forkpty(&master, nil, nil, &desiredWindowSize)
        if pid < 0 {
            return nil
        }
        if pid == 0 {
            if let cCurrentDirectory {
                _ = chdir(cCurrentDirectory)
            }

            // Close every inherited fd >= 3 before exec (fdLimit — the bound
            // on allocatable fd numbers — was sampled pre-fork above, so this
            // sweep covers every fd the parent could possibly have open).
            // forkpty's login_tty has already dup2'd the slave pty onto 0/1/2
            // and closed the master in this child, so everything >= 3 is an
            // accidental leak from the (multithreaded) parent — pipes created
            // without O_CLOEXEC anywhere in the app race this fork and, once
            // inherited by a long-lived shell, hold their write ends open
            // forever so the parent's pipe reads never EOF (Scape IT-301:
            // launch-time git fan-out wedged 6 cooperative-pool threads).
            // macOS has no pipe2()/close_range(), so the parent cannot make
            // pipe creation atomically CLOEXEC — this close loop is the only
            // race-free closure. Only async-signal-safe calls are legal here
            // between fork and exec in a multithreaded parent: the loop is
            // close() and scalar arithmetic only. Cost is paid in the CHILD
            // (~32 ms at a 245k bound), off the parent's spawn path.
            // If a deliberately-inherited fd is ever introduced (none exist
            // today), it must be allowlisted explicitly in this loop.
            var leakedFd: Int32 = 3
            while leakedFd < fdLimit {
                close(leakedFd)
                leakedFd += 1
            }

            _ = execve(cExecutable, cArgs.base, cEnv.base)
            _exit(127)
        }
        return (pid, master)
    }
    
    /**
     * Sets the window size of the underlying pseudo terminal.
     * - Parameter masterPtyDescriptor: a pseudo-terminal master file descriptor, as returned by fork(andExec:)
     * - Returns: the value from calling the ioctl
     */
    public static func setWinSize (masterPtyDescriptor: Int32, windowSize: inout winsize) -> Int32
    {
#if os(macOS)
        return ioctl(masterPtyDescriptor, TIOCSWINSZ, &windowSize)
#else
	return ioctl(masterPtyDescriptor, UInt(TIOCSWINSZ), &windowSize)
#endif
    }
    
    /**
     * Returns the number of available bytes to be read from the file descriptor
     */
    public static func availableBytes (fd: Int32) -> (status: Int32, size: Int32)
    {
        var size: Int32 = 0
        let status = ioctl (fd, 0x4004667f /* FIONREAD */, &size)
        return (status, size)
    }
}
#endif
