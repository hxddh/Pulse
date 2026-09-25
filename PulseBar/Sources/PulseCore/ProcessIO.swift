import Foundation

/// Bounded, deadlock-safe subprocess I/O for the small system probes Pulse
/// runs outside the harvest child. Reading stdout and stderr one after the
/// other can block forever when either pipe fills; keep both drains live and
/// put a deadline around the child itself.
public enum ProcessIO {
    public struct Result {
        public var stdout: Data
        public var stderr: Data
        public var status: Int32
        public var timedOut: Bool
        /// Stopped by the user through a `CheckControl`, not by the deadline.
        public var cancelled = false
    }

    /// Which end of an over-long output survives. Probes parse from the
    /// start; a check's verdict — the failing test, the summary — is at the
    /// end, which is what 11.0.3's head-only buffer threw away.
    public enum Keep { case head, tail }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int
        private let keep: Keep

        public init(limit: Int, keep: Keep = .head) {
            self.limit = limit
            self.keep = keep
        }

        public func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            switch keep {
            case .head:
                let remaining = max(0, limit - data.count)
                guard remaining > 0 else { return }
                data.append(chunk.prefix(remaining))
            case .tail:
                data.append(chunk)
                if data.count > limit { data = Data(data.suffix(limit)) }
            }
        }

        public var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        timeout: TimeInterval = 1.5,
        outputLimit: Int = 4 * 1024 * 1024
    ) -> Result? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        if let environment { task.environment = environment }
        if let currentDirectory {
            task.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }

        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        let outBuffer = Buffer(limit: outputLimit)
        let errBuffer = Buffer(limit: outputLimit)
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        let exitDone = DispatchSemaphore(value: 0)

        do {
            try task.run()
        } catch {
            return nil
        }

        Thread.detachNewThread {
            while true {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                outBuffer.append(chunk)
            }
            outDone.signal()
        }
        Thread.detachNewThread {
            while true {
                let chunk = err.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                errBuffer.append(chunk)
            }
            errDone.signal()
        }
        Thread.detachNewThread {
            task.waitUntilExit()
            exitDone.signal()
        }

        let timedOut = exitDone.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            task.terminate()
            if exitDone.wait(timeout: .now() + 0.5) == .timedOut {
                // SIGTERM is a request. A child blocked in the kernel — `lsof`
                // on a dead network mount is the textbook case — may never
                // answer it, and leaving it running leaks a process for the
                // lifetime of the app.
                kill(task.processIdentifier, SIGKILL)
                _ = exitDone.wait(timeout: .now() + 0.5)
            }
        }
        _ = outDone.wait(timeout: .now() + 0.5)
        _ = errDone.wait(timeout: .now() + 0.5)

        // `terminationStatus` is only defined once the child has exited;
        // asking a still-running Process for it raises. Every caller here
        // already treats `timedOut` as the failure signal, so report a status
        // that cannot be mistaken for a clean exit instead.
        return Result(
            stdout: outBuffer.value,
            stderr: errBuffer.value,
            status: task.isRunning ? -1 : task.terminationStatus,
            timedOut: timedOut
        )
    }

    /// A user's check: `/bin/sh -lc <command>` in its **own process group**,
    /// output kept from the tail, and the whole group killed when the shell
    /// ends or the deadline passes.
    ///
    /// 11.0.3 ran checks through `run`, whose SIGKILL reached only the shell:
    /// a test runner's children survived the timeout and could keep changing
    /// the worktree the evidence had just been measured against.
    /// The way to stop a running check from outside: its whole process
    /// group, the same as the deadline does. Safe from any thread.
    public final class CheckControl: @unchecked Sendable {
        private let lock = NSLock()
        private var group: pid_t = 0
        private var stopped = false

        public init() {}

        public var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }

        public func cancel() {
            lock.lock()
            stopped = true
            let target = group
            lock.unlock()
            if target > 0 { kill(-target, SIGKILL) }
        }

        /// A check that was cancelled before it started is killed the moment
        /// it has a group to kill.
        fileprivate func attach(_ pid: pid_t) {
            lock.lock()
            group = pid
            let already = stopped
            lock.unlock()
            if already { kill(-pid, SIGKILL) }
        }

        fileprivate func detach() {
            lock.lock(); group = 0; lock.unlock()
        }
    }

    public static func runCheck(
        command: String,
        currentDirectory: String,
        timeout: TimeInterval,
        outputLimit: Int,
        control: CheckControl? = nil
    ) -> Result? {
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else { return nil }
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            return nil
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
        for fd in [stdoutPipe[0], stdoutPipe[1], stderrPipe[0], stderrPipe[1]] {
            posix_spawn_file_actions_addclose(&actions, fd)
        }
        posix_spawn_file_actions_addchdir_np(&actions, currentDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let arguments = ["/bin/sh", "-lc", command]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { for pointer in envp { free(pointer) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
        close(stdoutPipe[1])
        close(stderrPipe[1])
        guard spawned == 0 else {
            close(stdoutPipe[0]); close(stderrPipe[0])
            return nil
        }
        let child = pid
        control?.attach(child)
        defer { control?.detach() }
        let stdoutRead = stdoutPipe[0]
        let stderrRead = stderrPipe[0]

        let outBuffer = Buffer(limit: outputLimit, keep: .tail)
        let errBuffer = Buffer(limit: outputLimit, keep: .tail)
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        let exitDone = DispatchSemaphore(value: 0)
        let status = CheckStatus()
        func drain(_ fd: Int32, into buffer: Buffer, done: DispatchSemaphore) {
            Thread.detachNewThread {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    buffer.append(chunk)
                }
                done.signal()
            }
        }
        drain(stdoutRead, into: outBuffer, done: outDone)
        drain(stderrRead, into: errBuffer, done: errDone)
        Thread.detachNewThread {
            var raw: Int32 = 0
            while waitpid(child, &raw, 0) == -1, errno == EINTR {}
            status.value = decodeWaitStatus(raw)
            exitDone.signal()
        }

        let timedOut = exitDone.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            kill(-child, SIGTERM)
            if exitDone.wait(timeout: .now() + 2) == .timedOut {
                kill(-child, SIGKILL)
                _ = exitDone.wait(timeout: .now() + 2)
            }
        }
        // The check is over when its shell is. Anything it left running in
        // its group is not part of the evidence and must not outlive it.
        kill(-child, SIGKILL)
        _ = outDone.wait(timeout: .now() + 2)
        _ = errDone.wait(timeout: .now() + 2)
        return Result(
            stdout: outBuffer.value,
            stderr: errBuffer.value,
            status: timedOut ? -1 : status.value,
            timedOut: timedOut,
            cancelled: control?.isCancelled ?? false
        )
    }

    /// `WIFEXITED` / `WEXITSTATUS` / `WTERMSIG`, which Swift cannot import
    /// as macros. A signal death reads as `128 + signal`, the shell's own
    /// convention, so it is never mistaken for a clean exit.
    public static func decodeWaitStatus(_ raw: Int32) -> Int32 {
        let signal = raw & 0x7f
        if signal == 0 { return (raw >> 8) & 0xff }
        return 128 + signal
    }

    private final class CheckStatus: @unchecked Sendable {
        public var value: Int32 = -1
    }
}
