import Foundation

/// Bounded, deadlock-safe subprocess I/O for the small system probes Pulse
/// runs outside the harvest child. Reading stdout and stderr one after the
/// other can block forever when either pipe fills; keep both drains live and
/// put a deadline around the child itself.
enum ProcessIO {
    struct Result {
        var stdout: Data
        var stderr: Data
        var status: Int32
        var timedOut: Bool
    }

    private final class Buffer {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            let remaining = max(0, limit - data.count)
            guard remaining > 0 else { return }
            data.append(chunk.prefix(remaining))
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 1.5,
        outputLimit: Int = 4 * 1024 * 1024
    ) -> Result? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        if let environment { task.environment = environment }

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
            _ = exitDone.wait(timeout: .now() + 0.5)
        }
        _ = outDone.wait(timeout: .now() + 0.5)
        _ = errDone.wait(timeout: .now() + 0.5)

        return Result(
            stdout: outBuffer.value,
            stderr: errBuffer.value,
            status: task.terminationStatus,
            timedOut: timedOut
        )
    }
}
