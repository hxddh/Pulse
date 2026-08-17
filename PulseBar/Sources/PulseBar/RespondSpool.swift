import CryptoKit
import Darwin
import Foundation

/// File protocol (v1) for carrying permission requests off a remote machine
/// and verdicts back — this Mac is the *answering* end. Pulse writes no
/// network code and runs no server: exactly like `attention.d/`, whatever the
/// user already uses to move files (rsync, syncthing, a mounted volume) is
/// the transport. Layout under `~/Library/Application Support/Pulse/respond.d/`:
///
///   requests.d/<host>/<request_id>.json   — written by the remote hook,
///                                            synced *to* this machine
///   verdicts.d/<host>/<request_id>.json   — written by Pulse, synced *back*
///   secrets/<host>.key                    — user-provisioned shared key;
///                                            its existence is the per-host
///                                            Respond opt-in
///
/// Disciplines, in the same spirit as the AGENTS invariants:
///
/// - **A verdict is never written into `requests.d`.** That directory syncs
///   *toward* this machine; anything Pulse put there would be pushed back out
///   by tools we do not control and land where no one intended.
/// - **No key, no verdict on disk — fail closed.** A synced directory with no
///   HMAC key would mean "anyone who can write this folder can approve as
///   you". Refusing to write is the safe failure; the remote agent falls back
///   to its own prompt (plan-respond P0-0 Q3: the vendor path fails open).
/// - **Remote files are someone else's disk quota, not ours.** Reads are
///   bounded in hosts, files per host, and bytes per file, like
///   `AttentionIO.readInbox`.
/// - **`request_id` and `host` are untrusted text that becomes a file name.**
///   They are sanitized to `[A-Za-z0-9._-]`, capped, and never allowed to be
///   a pure-dot component, so a hostile id cannot climb out of the spool.
enum RespondSpool {
    /// Tests redirect the spool without touching the user's real
    /// Application Support tree — same seam as `AttentionIO.pathOverride`.
    static var rootOverride: URL?

    static var root: URL {
        if let rootOverride { return rootOverride }
        if let home = ProcessInfo.processInfo.environment["PULSE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("respond.d", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Pulse/respond.d", isDirectory: true
            )
    }

    static var requestsDirectory: URL {
        root.appendingPathComponent("requests.d", isDirectory: true)
    }
    static var verdictsDirectory: URL {
        root.appendingPathComponent("verdicts.d", isDirectory: true)
    }
    static var secretsDirectory: URL {
        root.appendingPathComponent("secrets", isDirectory: true)
    }

    /// Same bounds philosophy as `AttentionIO`: a misbehaving or hostile
    /// remote writer must not be able to make this Mac read without limit.
    static let maxHosts = 16
    static let maxFilesPerHost = 32
    static let maxBytesPerFile = 256 * 1024
    /// A shared key is dozens of bytes. A "key" the size of a document is a
    /// mistake (wrong file dropped in `secrets/`), and signing with a mistake
    /// is worse than refusing — fail closed.
    static let maxSecretBytes = 4 * 1024
    /// How long an expired file may linger before `cleanup` removes it. The
    /// grace exists so the user's sync tool has time to carry the file's fate
    /// back before the evidence disappears.
    static let cleanupGraceMs: Int64 = 60 * 60 * 1000

    /// One remote permission request, ready for the decision store.
    struct InboundRequest: Equatable {
        var request: PermissionRequest
        var toolName: String
        var expiresAtMs: Int64
    }

    // MARK: - Reading requests

    /// 有界读取：≤16 host、每 host ≤32 文件、每文件 ≤256KB；解析失败/超期的跳过。
    ///
    /// `fullRequest` is the UTF-8 text decoded from `payload_b64`. The digest
    /// is then recomputed over that text and compared with the file's own
    /// `digest` field: any mismatch — a transport that mangled bytes, a
    /// payload that was not valid UTF-8, or plain tampering — marks the
    /// request `truncated`, and a truncated request can never be Allowed
    /// (`PermissionRequest.canOfferAllow`). An agent string that matches no
    /// `AgentID` skips the file entirely: guessing who is asking is exactly
    /// how a verdict ends up answering the wrong thing.
    static func readInboundRequests(nowMs: Int64) -> [InboundRequest] {
        let fm = FileManager.default
        guard let hostNames = try? fm.contentsOfDirectory(atPath: requestsDirectory.path)
        else { return [] }
        var found: [InboundRequest] = []
        for hostName in hostNames.sorted().prefix(maxHosts) {
            let hostDir = requestsDirectory.appendingPathComponent(hostName, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: hostDir.path) else { continue }
            // The bound counts files *touched*, not files parsed — otherwise a
            // directory of garbage would defeat the bound while every file
            // "doesn't count".
            var touched = 0
            for name in names.sorted() where name.hasSuffix(".json") {
                if touched >= maxFilesPerHost { break }
                touched += 1
                let url = hostDir.appendingPathComponent(name)
                guard let inbound = parseRequestFile(at: url, hostDirectory: hostName, nowMs: nowMs)
                else { continue }
                found.append(inbound)
            }
        }
        return found
    }

    private static func parseRequestFile(
        at url: URL, hostDirectory: String, nowMs: Int64
    ) -> InboundRequest? {
        guard let data = boundedRead(url, limit: maxBytesPerFile),
              let file = try? JSONDecoder().decode(RequestFile.self, from: data),
              file.v == 1
        else { return nil }
        // The host the file *claims* must match the directory it arrived in.
        // The directory decides which secret signs the verdict, so a file in
        // devbox's folder claiming to be buildbox would get devbox's key to
        // sign a verdict addressed to a machine devbox was never trusted for.
        guard file.host == hostDirectory else { return nil }
        // Unknown agent → skip, never guess (see the method doc).
        guard let agent = AgentID(rawValue: file.agent) else { return nil }
        guard nowMs < file.expiresAtMs else { return nil }
        guard let payload = Data(base64Encoded: file.payloadB64) else { return nil }
        let fullRequest = String(decoding: payload, as: UTF8.self)
        // Recompute over the decoded *text*, not the raw bytes: the verdict's
        // digest binding (`PermissionRequest.digest`) is over the text, so
        // this comparison also catches a payload whose bytes were not valid
        // UTF-8 and changed in decoding.
        let digestMatches = RespondDigest.of(fullRequest) == file.digest.lowercased()
        let request = PermissionRequest(
            id: file.requestID,
            agent: agent,
            host: file.host,
            session: file.session,
            fullRequest: fullRequest,
            truncated: file.truncated || !digestMatches,
            // Local mtime, not the remote's clock — same reasoning as
            // `AttentionIO.Source.receivedAtMs`: the moment the bytes landed
            // on *this* disk is the only stamp that is both local and durable.
            receivedAtMs: modificationMs(of: url)
        )
        return InboundRequest(
            request: request, toolName: file.toolName, expiresAtMs: file.expiresAtMs
        )
    }

    // MARK: - Secrets

    /// 该 host 的密钥文件存在且非空。This is the per-host opt-in: no key file,
    /// no Respond for that machine.
    static func hostHasSecret(_ host: String) -> Bool {
        secret(for: host) != nil
    }

    /// Raw key bytes with trailing newlines trimmed — users create these with
    /// `echo`/editors that add a final `\n`, and a key that silently differs
    /// by one byte from the remote's copy would make every verdict unverifiable.
    private static func secret(for host: String) -> Data? {
        guard !host.isEmpty else { return nil }
        let url = secretsDirectory
            .appendingPathComponent(sanitizeComponent(host) + ".key")
        guard var data = boundedRead(url, limit: maxSecretBytes) else { return nil }
        while let last = data.last, last == 0x0A || last == 0x0D {
            data.removeLast()
        }
        return data.isEmpty ? nil : data
    }

    // MARK: - Writing verdicts

    /// 无密钥/host 为空/IO 失败 → false。写入 0600、先写临时文件再原子 rename。
    ///
    /// The HMAC covers the canonical string
    /// `"v1\n" + request_id + "\n" + digest + "\n" + agent + "\n" + host +
    ///  "\n" + ("allow"|"deny") + "\n" + decided_at_ms + "\n" + expires_at_ms`
    /// with the per-host shared key, so the remote consumer can verify both
    /// that the verdict is untampered and that it was minted by someone who
    /// holds this host's key. The verdict goes into `verdicts.d` only — never
    /// `requests.d`, which syncs the other way (see the type doc).
    @discardableResult
    static func writeVerdict(_ verdict: RespondVerdict) -> Bool {
        // An empty host is a local decision; the spool exists for machines
        // that are not this one.
        guard !verdict.host.isEmpty else { return false }
        // No key, no verdict on disk — fail closed (see the type doc).
        guard let key = secret(for: verdict.host) else { return false }
        let message = "v1\n" + verdict.requestID + "\n" + verdict.digest + "\n"
            + verdict.agent + "\n" + verdict.host + "\n"
            + (verdict.allow ? "allow" : "deny") + "\n"
            + String(verdict.decidedAtMs) + "\n" + String(verdict.expiresAtMs)
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8), using: SymmetricKey(data: key)
        )
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        let body = VerdictFile(
            v: 1,
            requestID: verdict.requestID,
            digest: verdict.digest,
            agent: verdict.agent,
            host: verdict.host,
            allow: verdict.allow,
            decidedAtMs: verdict.decidedAtMs,
            expiresAtMs: verdict.expiresAtMs,
            hmac: hex
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(body) else { return false }
        let fm = FileManager.default
        let directory = verdictsDirectory
            .appendingPathComponent(sanitizeComponent(verdict.host), isDirectory: true)
        // A verdict can cause an agent to act; the whole tree stays user-only.
        try? fm.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = directory
            .appendingPathComponent(sanitizeComponent(verdict.requestID) + ".json")
        // Temp-then-rename in the same directory: the sync tool watching
        // `verdicts.d` must never pick up a half-written verdict, and
        // rename(2) is atomic only within one filesystem. 0600 is set at
        // creation, not after — there is no window where another local user
        // could read a signed verdict.
        let temp = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        guard fm.createFile(
            atPath: temp.path, contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return false }
        guard rename(temp.path, destination.path) == 0 else {
            try? fm.removeItem(at: temp)
            return false
        }
        return true
    }

    // MARK: - Cleanup

    /// 删除超期请求与判决文件（均按 expires_at_ms + 1h 宽限）。
    ///
    /// Deliberately *not* bounded like the read path: deleting is how the
    /// read bounds recover, so cleanup must be able to reach files the reader
    /// will never touch.
    static func cleanup(nowMs: Int64) {
        cleanupTree(requestsDirectory, nowMs: nowMs)
        cleanupTree(verdictsDirectory, nowMs: nowMs)
    }

    private static func cleanupTree(_ directory: URL, nowMs: Int64) {
        let fm = FileManager.default
        guard let hostNames = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for hostName in hostNames {
            let hostDir = directory.appendingPathComponent(hostName, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: hostDir.path) else { continue }
            for name in names where name.hasSuffix(".json") {
                let url = hostDir.appendingPathComponent(name)
                guard let expiry = expiryMs(of: url) else {
                    // A file this code can never parse would otherwise sit in
                    // the spool forever; its landing time is the only honest
                    // clock left to age it by.
                    if modificationMs(of: url) + cleanupGraceMs < nowMs {
                        try? fm.removeItem(at: url)
                    }
                    continue
                }
                if expiry + cleanupGraceMs < nowMs {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    private static func expiryMs(of url: URL) -> Int64? {
        guard let data = boundedRead(url, limit: maxBytesPerFile),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let number = object["expires_at_ms"] as? NSNumber
        else { return nil }
        return number.int64Value
    }

    // MARK: - Shared plumbing

    /// Untrusted text → file name component. Only `[A-Za-z0-9._-]` survives,
    /// everything else becomes `_`, length is capped, and a component that is
    /// nothing but dots (`.`, `..`) is replaced outright — those are the two
    /// spellings that would climb out of the spool.
    static func sanitizeComponent(_ raw: String) -> String {
        let sanitized = String(raw.prefix(120).map { ch -> Character in
            let ok = ch.isASCII
                && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-")
            return ok ? ch : "_"
        })
        if sanitized.isEmpty || sanitized.allSatisfy({ $0 == "." }) { return "_" }
        return sanitized
    }

    /// Refuse oversized files up front instead of reading a prefix: a partial
    /// JSON document never parses, so a prefix read would only spend the
    /// bytes to learn nothing.
    private static func boundedRead(_ url: URL, limit: Int) -> Data? {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= limit,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return data
    }

    private static func modificationMs(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let date = attributes?[.modificationDate] as? Date
        return Int64((date?.timeIntervalSince1970 ?? 0) * 1000)
    }

    // MARK: - File schemas (v1)

    /// Written by the remote hook; read here. Extra JSON keys are ignored,
    /// missing required keys fail the decode and the file is skipped.
    private struct RequestFile: Codable {
        var v: Int
        var requestID: String
        var agent: String
        var host: String
        var session: String
        var cwd: String
        var toolName: String
        var raisedAtMs: Int64
        var expiresAtMs: Int64
        var payloadB64: String
        var digest: String
        var truncated: Bool

        enum CodingKeys: String, CodingKey {
            case v
            case requestID = "request_id"
            case agent
            case host
            case session
            case cwd
            case toolName = "tool_name"
            case raisedAtMs = "raised_at_ms"
            case expiresAtMs = "expires_at_ms"
            case payloadB64 = "payload_b64"
            case digest
            case truncated
        }
    }

    /// Written here; consumed on the remote machine.
    private struct VerdictFile: Codable {
        var v: Int
        var requestID: String
        var digest: String
        var agent: String
        var host: String
        var allow: Bool
        var decidedAtMs: Int64
        var expiresAtMs: Int64
        var hmac: String

        enum CodingKeys: String, CodingKey {
            case v
            case requestID = "request_id"
            case digest
            case agent
            case host
            case allow
            case decidedAtMs = "decided_at_ms"
            case expiresAtMs = "expires_at_ms"
            case hmac
        }
    }
}
