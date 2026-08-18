import Darwin
import Foundation

/// Every file Pulse writes that carries something the user typed, ran or named.
///
/// The rule is one sentence: **0600 from the first byte, never 0644 with a
/// `chmod` afterwards.** `write(to:options:.atomic)` cannot honour it — the
/// temporary file it creates takes the process umask, 0644 on a stock Mac,
/// and stays readable by every other local account for the whole write plus
/// the rename. Creating the file with the mode we want, before a byte goes
/// into it, closes the window instead of narrowing it.
///
/// 2.2 established this for the session digest, which by design stores only
/// counts and vendor tool names. The two files holding actual prose had the
/// weakest protection of anything Pulse writes: `attention-ledger.json` keeps
/// session titles — the user's own words, up to 160 characters — and project
/// names, and set no mode at all; `attention.tsv` keeps the command an agent
/// asked to run and the directory it asked from, and was created 0644. The
/// respond spool sitting in the same folder was already 0600.
enum PrivateFile {
    static let mode: mode_t = 0o600

    /// Test seam: handed the temporary file's path after it is created and
    /// filled, before it is renamed into place — so a test can prove the
    /// bytes were never readable by anyone else, rather than only that they
    /// ended up private.
    static var inspectTemporaryFileForTesting: ((String) -> Void)?

    /// Write `data` privately, then publish it atomically.
    ///
    /// `rename(2)` carries the mode across whether or not a file was already
    /// there, which is the same shape `RespondSpool.atomicWrite0600` uses for
    /// verdicts, and for the same reason.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        guard fm.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return false }
        inspectTemporaryFileForTesting?(temporary.path)
        guard rename(temporary.path, url.path) == 0 else {
            try? fm.removeItem(at: temporary)
            return false
        }
        return true
    }

    /// Bring a file written before this rule down to 0600.
    ///
    /// A creation mode only applies to files that do not exist yet, so every
    /// install that already has an `attention.tsv` would keep its 0644 for
    /// ever. Doing it through the descriptor we already hold costs one
    /// `fchmod`, cannot race a swapped path, and needs no migration step that
    /// somebody has to remember to run.
    ///
    /// A file owned by somebody else is left exactly as it is: Pulse has no
    /// business changing another account's modes, and failing quietly here is
    /// better than refusing to record a wait.
    static func tighten(fileDescriptor fd: Int32) {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return }
        guard info.st_uid == getuid() else { return }
        guard (info.st_mode & 0o777) != mode else { return }
        _ = fchmod(fd, mode)
    }
}
