import CryptoKit
import Darwin
import Foundation

/// File protocol (v1) for carrying permission requests off a remote machine
/// and verdicts back. Pulse writes no network code and runs no server:
/// exactly like `attention.d/`, whatever the user already uses to move files
/// (rsync, syncthing, a mounted volume) is the transport.
///
/// A Mac can stand at either end — or both. Layout under
/// `~/Library/Application Support/Pulse/respond.d/`:
///
/// **Answering end** (the user sits here; requests arrive, verdicts leave):
///
///   requests.d/<host>/<request_id>.json   — written by the remote hook,
///                                            synced *to* this machine
///   verdicts.d/<host>/<request_id>.json   — written by Pulse, synced *back*
///   secrets/<host>.key                    — user-provisioned shared key;
///                                            its existence is the per-host
///                                            Respond opt-in
///
/// **Answered end** (the agent runs here; the hook holds for a verdict).
/// Byte-for-byte the same protocol as `src/pulse_hook.py`'s Respond section,
/// so a remote Mac needs no legacy Python hook to take part — that would
/// break the native promise:
///
///   requests/<request_id>.json            — written by the local hook (flat,
///                                            not per-host: every request here
///                                            is this machine's own)
///   verdicts/<request_id>.json            — arrives via the user's sync
///                                            tool; claimed by rename → .used
///   ../respond-secret.key                 — the shared key, deliberately
///                                            *beside* respond.d rather than
///                                            inside it, so a sync scoped to
///                                            respond.d never carries the key
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

    /// One permission request, ready for the decision store.
    struct InboundRequest: Equatable {
        var request: PermissionRequest
        var toolName: String
        var expiresAtMs: Int64
        /// Raised by an agent on **this** Mac, and read back out of the flat
        /// outbound tree rather than arriving through a sync tool. It attaches
        /// to a local row, and its verdict is signed with the local key.
        var isLocal: Bool = false
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

    /// This Mac's own held requests, read back out of the flat outbound tree.
    ///
    /// The hook writes here whether the answer will come from this Mac or
    /// another one — it cannot know, and does not need to. What makes these
    /// *local* is that nothing carried them anywhere: the same machine wrote
    /// them and is now reading them. Until 2.4 nobody read this directory at
    /// all, which is why Respond did nothing on a single-Mac install.
    ///
    /// Same bounds as the inbound tree, and the same refusal to guess: a file
    /// claiming a host that is not this one is skipped rather than adopted.
    static func readLocalRequests(nowMs: Int64, host: String) -> [InboundRequest] {
        guard !host.isEmpty else { return [] }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: outboundRequestsDirectory.path)
        else { return [] }
        var found: [InboundRequest] = []
        var touched = 0
        for name in names.sorted() where name.hasSuffix(".json") {
            if touched >= maxFilesPerHost { break }
            touched += 1
            let url = outboundRequestsDirectory.appendingPathComponent(name)
            guard var inbound = parseRequestFile(at: url, hostDirectory: host, nowMs: nowMs)
            else { continue }
            inbound.isLocal = true
            found.append(inbound)
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

    private static func secret(for host: String) -> Data? {
        guard !host.isEmpty else { return nil }
        return keyBytes(
            at: secretsDirectory.appendingPathComponent(sanitizeComponent(host) + ".key")
        )
    }

    /// Raw key bytes with trailing newlines trimmed — users create these with
    /// `echo`/editors that add a final `\n`, and a key that silently differs
    /// by one byte from the other machine's copy would make every verdict
    /// unverifiable. Same trim as `pulse_hook.py`'s `load_respond_key`.
    private static func keyBytes(at url: URL) -> Data? {
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
    /// - Parameter local: the request was raised by an agent on this Mac and
    ///   read back out of the flat outbound tree. The verdict then goes back
    ///   into the flat tree the waiting hook is already polling, signed with
    ///   the local key.
    ///
    ///   It is signed rather than trusted, and that is not ceremony: `verdicts/`
    ///   is exactly the directory a partner Mac's answers **sync into**, so an
    ///   unsigned file accepted there would let a compromised share inject an
    ///   allow — weakening the remote path to add the local one. The local key
    ///   never leaves this machine, so nothing arriving over a share can carry
    ///   its signature. An attacker who can read it already runs as this user
    ///   and could simply start the agent.
    @discardableResult
    static func writeVerdict(_ verdict: RespondVerdict, local: Bool = false) -> Bool {
        guard !verdict.host.isEmpty else { return false }
        if local { return writeLocalVerdict(verdict) }
        // No key, no verdict on disk — fail closed (see the type doc).
        guard let key = secret(for: verdict.host) else { return false }
        guard let data = signedVerdictData(verdict, key: key) else { return false }
        let directory = verdictsDirectory
            .appendingPathComponent(sanitizeComponent(verdict.host), isDirectory: true)
        // A verdict can cause an agent to act; the whole tree stays user-only.
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = directory
            .appendingPathComponent(sanitizeComponent(verdict.requestID) + ".json")
        return atomicWrite0600(data, to: destination)
    }

    /// The same record, the same canonical message, the same 0600 atomic
    /// write — only the key and the destination differ.
    private static func writeLocalVerdict(_ verdict: RespondVerdict) -> Bool {
        guard let key = localKey() else { return false }
        guard let data = signedVerdictData(verdict, key: key) else { return false }
        try? FileManager.default.createDirectory(
            at: outboundVerdictsDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = outboundVerdictsDirectory
            .appendingPathComponent(sanitizeComponent(verdict.requestID) + ".json")
        return atomicWrite0600(data, to: destination)
    }

    private static func signedVerdictData(_ verdict: RespondVerdict, key: Data) -> Data? {
        let message = canonicalMessage(
            requestID: verdict.requestID, digest: verdict.digest,
            agent: verdict.agent, host: verdict.host, allow: verdict.allow,
            decidedAtMs: verdict.decidedAtMs, expiresAtMs: verdict.expiresAtMs
        )
        let mac = HMAC<SHA256>.authenticationCode(
            for: message, using: SymmetricKey(data: key)
        )
        let body = VerdictFile(
            v: 1,
            requestID: verdict.requestID,
            digest: verdict.digest,
            agent: verdict.agent,
            host: verdict.host,
            allow: verdict.allow,
            decidedAtMs: verdict.decidedAtMs,
            expiresAtMs: verdict.expiresAtMs,
            hmac: mac.map { String(format: "%02x", $0) }.joined()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(body)
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

    // MARK: - Answered end (the agent runs on THIS machine; the hook holds)
    //
    // Mac-to-Mac parity: a remote Mac running the native receiver must speak
    // the same v1 protocol as `src/pulse_hook.py`, or the "native promise"
    // quietly requires the legacy Python hook on exactly the machines that
    // should need it least. Every constant and semantic below is frozen with
    // the Python side — change both or neither.

    static var outboundRequestsDirectory: URL {
        root.appendingPathComponent("requests", isDirectory: true)
    }
    static var outboundVerdictsDirectory: URL {
        root.appendingPathComponent("verdicts", isDirectory: true)
    }
    /// `<pulse_dir>/respond-secret.key` — see the type doc for why it lives
    /// beside `respond.d`, not inside it.
    static var outboundSecretURL: URL {
        root.deletingLastPathComponent().appendingPathComponent("respond-secret.key")
    }

    /// Verdict timestamps come from another machine's clock. Tolerance is
    /// ±5 min, chosen in the direction that keeps a genuinely fresh verdict
    /// usable: unexpired while `now < expires + skew`, plausibly decided
    /// while `decided - skew <= now`. The cost is a verdict outliving its
    /// stated expiry by up to 5 minutes against a fast local clock — bounded,
    /// and the exactly-once `.used` rename means even that verdict can only
    /// answer this one held request. The strict alternative would silently
    /// reject every verdict from a Mac whose clock runs a few minutes behind,
    /// failing the user constantly to defend against a replay the single-use
    /// rename already prevents. (= RESPOND_CLOCK_SKEW_MS)
    static let respondClockSkewMs: Int64 = 300_000
    /// `.used` remnants older than an hour are removed. (= RESPOND_USED_TTL_MS)
    static let usedVerdictTtlMs: Int64 = 3_600_000
    /// Cap per spool directory, oldest deleted first. (= RESPOND_DIR_MAX_FILES)
    static let outboundMaxFilesPerDirectory = 64

    /// This machine's Respond opt-in: the shared key exists and is non-empty.
    static func outboundHasSecret() -> Bool {
        outboundKey() != nil
    }

    private static func outboundKey() -> Data? {
        keyBytes(at: outboundSecretURL)
    }

    /// `<pulse_dir>/respond-local.key` — beside the shared key, and **never
    /// carried anywhere**. Where `respond-secret.key` is provisioned by the
    /// user and copied to a partner Mac, this one is generated here and stays
    /// here.
    static var localSecretURL: URL {
        root.deletingLastPathComponent().appendingPathComponent("respond-local.key")
    }

    /// Answering this Mac's own agents is opt-in, and the key file's existence
    /// *is* the switch — the same shape as the per-host opt-in, and the same
    /// kill switch: no key, no hold, so an install that never turns this on
    /// sees no change in agent behaviour at all.
    static func localHasSecret() -> Bool {
        localKey() != nil
    }

    private static func localKey() -> Data? {
        keyBytes(at: localSecretURL)
    }

    /// The hook holds only if it can verify *some* verdict.
    static func hasAnyKey() -> Bool {
        outboundHasSecret() || localHasSecret()
    }

    /// Turn local answering on or off by creating or removing the key.
    ///
    /// Written as hex text on purpose: `keyBytes` trims trailing newline bytes
    /// so a user's `echo`-created key still matches its copy on the other Mac,
    /// and raw random bytes ending in 0x0A would be silently trimmed into a
    /// different key than the one written.
    @discardableResult
    static func setLocalAnsweringEnabled(_ enabled: Bool) -> Bool {
        guard enabled else {
            try? FileManager.default.removeItem(at: localSecretURL)
            return !localHasSecret()
        }
        if localHasSecret() { return true }
        let hex = (0..<32)
            .map { _ in String(format: "%02x", UInt8.random(in: UInt8.min...UInt8.max)) }
            .joined()
        return PrivateFile.write(Data(hex.utf8), to: localSecretURL)
    }

    /// Write this machine's own permission request for the answering Mac,
    /// mirroring `pulse_hook.py respond_decision_json`'s record: the payload
    /// is the **verbatim** hook stdin (base64), the digest is over those
    /// exact bytes, and `truncated` is false because nothing was cut.
    /// Housekeeping (`cleanupOutbound`) runs alongside every write, exactly
    /// like the Python side.
    @discardableResult
    static func writeOutboundRequest(
        requestID: String,
        agent: String,
        host: String,
        session: String,
        cwd: String,
        toolName: String,
        payload: Data,
        nowMs: Int64,
        expiresAtMs: Int64
    ) -> Bool {
        // No id → a verdict could not be bound; no bytes → nothing the user
        // could actually review. Either way there is nothing to hold for.
        guard !requestID.isEmpty, !payload.isEmpty else { return false }
        let fm = FileManager.default
        for directory in [root, outboundRequestsDirectory, outboundVerdictsDirectory] {
            try? fm.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let record = RequestFile(
            v: 1,
            requestID: requestID,
            agent: agent,
            host: host,
            session: session,
            cwd: cwd,
            toolName: toolName,
            raisedAtMs: nowMs,
            expiresAtMs: expiresAtMs,
            payloadB64: payload.base64EncodedString(),
            digest: RespondDigest.of(payload),
            truncated: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return false }
        let destination = outboundRequestsDirectory
            .appendingPathComponent(sanitizeComponent(requestID) + ".json")
        let written = atomicWrite0600(data, to: destination)
        cleanupOutbound(nowMs: nowMs)
        return written
    }

    /// One poll of the verdict spool — the hold loop's sleep lives in the
    /// caller so tests can run on a fake clock.
    ///
    /// Exactly-once, frozen with `pulse_hook.py hold_for_verdict`: the file
    /// is claimed by renaming it to `.used` **before** it is read, and only a
    /// successful rename may be read and acted on. A rename that fails (file
    /// absent, or another process claimed it) is no verdict. A claimed
    /// verdict that fails verification stays consumed — the caller keeps
    /// waiting for a fresh file rather than re-reading a bad one.
    ///
    /// Returns the verdict's `allow`, or nil for "keep waiting". An allow for
    /// a truncated request is refused here as well: deny stays available, but
    /// approving something not fully captured must be impossible end to end.
    static func claimVerdict(
        requestID: String,
        digest: String,
        agent: String,
        host: String,
        truncated: Bool = false,
        nowMs: Int64
    ) -> Bool? {
        let name = sanitizeComponent(requestID) + ".json"
        let verdictURL = outboundVerdictsDirectory.appendingPathComponent(name)
        let usedURL = outboundVerdictsDirectory.appendingPathComponent(name + ".used")
        // The rename IS the claim. rename(2) atomically replaces an existing
        // `.used` remnant, so a fresh verdict can still land after a bad one.
        guard rename(verdictURL.path, usedURL.path) == 0 else { return nil }
        // From here on, every failure leaves the file consumed on purpose.
        //
        // Two keys may be held: the shared one this Mac was provisioned with
        // for its partner, and the local one Pulse generated for answering
        // this Mac's own agents. Either proves the verdict was minted by
        // someone holding a key that lives on this machine; neither can be
        // forged from a synced directory alone.
        let keys = [outboundKey(), localKey()].compactMap { $0 }
        guard !keys.isEmpty else { return nil }
        guard let data = boundedRead(usedURL, limit: maxBytesPerFile),
              let verdict = try? JSONDecoder().decode(VerdictFile.self, from: data),
              verdict.v == 1,
              verdict.requestID == requestID,
              verdict.digest == digest,
              verdict.agent == agent,
              verdict.host == host
        else { return nil }
        // Clock-skew windows — see respondClockSkewMs for the direction.
        guard nowMs < verdict.expiresAtMs + respondClockSkewMs else { return nil }
        guard verdict.decidedAtMs - respondClockSkewMs <= nowMs else { return nil }
        // Constant-time MAC check: decode the claimed hex and let CryptoKit
        // compare, rather than comparing hex strings ourselves. Undecodable
        // hex is a refusal, not an error.
        guard let mac = hexBytes(verdict.hmac) else { return nil }
        let message = canonicalMessage(
            requestID: verdict.requestID, digest: verdict.digest,
            agent: verdict.agent, host: verdict.host, allow: verdict.allow,
            decidedAtMs: verdict.decidedAtMs, expiresAtMs: verdict.expiresAtMs
        )
        let verified = keys.contains { key in
            HMAC<SHA256>.isValidAuthenticationCode(
                mac, authenticating: message, using: SymmetricKey(data: key)
            )
        }
        guard verified else { return nil }
        if verdict.allow && truncated { return nil }
        return verdict.allow
    }

    /// What became of a verdict this Mac wrote for one of its own agents.
    ///
    /// Not a guess: `claimVerdict` collects a verdict by **renaming** it to
    /// `<id>.json.used` before reading it, so the claim leaves a mark on disk.
    /// Reading that mark is the difference between Pulse reporting what it
    /// did and Pulse reporting what happened.
    ///
    /// Only meaningful for a **local** verdict. A remote one is written into
    /// `verdicts.d/<host>/`, carried away by the user's sync tool, and
    /// renamed on the *other* machine — whether that rename ever comes back
    /// depends on a tool Pulse does not control, so there is nothing here to
    /// read and nothing honest to say beyond "written".
    enum VerdictFate: Equatable {
        /// Written, still sitting there, still in time.
        case waiting
        /// The hook took it. This is the receipt.
        case taken
        /// Its deadline passed with the file untouched — the agent fell back
        /// to the vendor's own prompt, which is the designed failure.
        case expired
        /// Nothing on disk under that id: never written here, or swept.
        case unknown
    }

    static func localVerdictFate(requestID: String, nowMs: Int64) -> VerdictFate {
        let fm = FileManager.default
        let name = sanitizeComponent(requestID) + ".json"
        let pending = outboundVerdictsDirectory.appendingPathComponent(name)
        // `.used` first: a fresh verdict can land while an older `.used`
        // remnant is still around, and "taken" is the newer fact only when
        // nothing is waiting.
        if !fm.fileExists(atPath: pending.path) {
            let used = outboundVerdictsDirectory.appendingPathComponent(name + ".used")
            return fm.fileExists(atPath: used.path) ? .taken : .unknown
        }
        guard let expiry = expiryMs(of: pending) else { return .waiting }
        return nowMs >= expiry ? .expired : .waiting
    }

    /// Housekeeping for the answered end, frozen with
    /// `pulse_hook.py cleanup_respond_dirs`: requests go one hour past their
    /// own expiry (mtime fallback for the unreadable), `.used` remnants go
    /// after an hour, and each directory is capped at 64 files oldest-first.
    static func cleanupOutbound(nowMs: Int64) {
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: outboundRequestsDirectory.path) {
            for name in names where name.hasSuffix(".json") {
                let url = outboundRequestsDirectory.appendingPathComponent(name)
                if let expiry = expiryMs(of: url) {
                    if nowMs > expiry + cleanupGraceMs { try? fm.removeItem(at: url) }
                } else if nowMs - modificationMs(of: url) > cleanupGraceMs {
                    try? fm.removeItem(at: url)
                }
            }
        }
        if let names = try? fm.contentsOfDirectory(atPath: outboundVerdictsDirectory.path) {
            for name in names where name.hasSuffix(".used") {
                let url = outboundVerdictsDirectory.appendingPathComponent(name)
                if nowMs - modificationMs(of: url) > usedVerdictTtlMs {
                    try? fm.removeItem(at: url)
                }
            }
        }
        pruneOldest(outboundRequestsDirectory, keep: outboundMaxFilesPerDirectory)
        pruneOldest(outboundVerdictsDirectory, keep: outboundMaxFilesPerDirectory)
    }

    private static func pruneOldest(_ directory: URL, keep: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        var files: [(url: URL, modifiedMs: Int64)] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }
            files.append((url, modificationMs(of: url)))
        }
        guard files.count > keep else { return }
        files.sort { $0.modifiedMs < $1.modifiedMs }
        for file in files.prefix(files.count - keep) {
            try? fm.removeItem(at: file.url)
        }
    }

    // MARK: - Shared plumbing

    /// Protocol-v1 canonical string the verdict HMAC is computed over.
    /// Frozen with `pulse_hook.py canonical_verdict_message` — do not reorder
    /// or reformat.
    private static func canonicalMessage(
        requestID: String,
        digest: String,
        agent: String,
        host: String,
        allow: Bool,
        decidedAtMs: Int64,
        expiresAtMs: Int64
    ) -> Data {
        Data((
            "v1\n" + requestID + "\n" + digest + "\n" + agent + "\n" + host + "\n"
                + (allow ? "allow" : "deny") + "\n"
                + String(decidedAtMs) + "\n" + String(expiresAtMs)
        ).utf8)
    }

    /// Temp-then-rename in the destination's own directory: a sync tool
    /// watching the spool must never pick up a half-written file, and
    /// rename(2) is atomic only within one filesystem. 0600 is set at
    /// creation, not after — there is no window where another local user
    /// could read the content.
    private static func atomicWrite0600(_ data: Data, to destination: URL) -> Bool {
        let fm = FileManager.default
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
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

    /// Hex → bytes, case-insensitive; nil for odd length or a non-hex digit.
    private static func hexBytes(_ hex: String) -> Data? {
        let cleaned = Array(hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = 0
        while index < cleaned.count {
            guard let high = nibble(cleaned[index]), let low = nibble(cleaned[index + 1])
            else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    private static func nibble(_ character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x30...0x39: return ascii - 0x30 // 0-9
        case 0x61...0x66: return ascii - 0x57 // a-f
        default: return nil
        }
    }

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
