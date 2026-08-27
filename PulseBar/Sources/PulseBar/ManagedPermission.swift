import Foundation

// 6.0-β — the permission channel (docs/plan-6.0.md, scene BJ).
//
// Headless turns silently deny any tool the project's own settings don't
// allow — which made 5.0's managed sessions "demoable, not workable". Claude
// Code's sanctioned escape is `--permission-prompt-tool mcp__<srv>__<tool>`:
// the CLI asks an MCP tool to decide. Pulse points that flag at ITSELF —
// `PulseBar --permission-server` speaks a minimal MCP stdio dialect, writes
// each ask into a spool the app watches, and blocks until the user's verdict
// file appears.
//
// The verdict card obeys every Respond rule: the FULL input is what Allow
// sits next to (an over-budget input loses the Allow button, never the Deny),
// deny is always available, a verdict is single-use. And because a headless
// run has no vendor prompt to fall back to, **timeout and every failure deny**
// — here fail-open would mean fail-permissive, which is the one direction
// this product never fails in.
enum ManagedPermission {

    static let timeoutMs: Int64 = 120_000
    static let maxInputBytes = 64 * 1024

    // MARK: - Spool shapes

    struct Request: Codable, Equatable {
        var id: String
        var managedID: String
        var toolName: String
        /// The tool input, JSON-encoded, exactly as the CLI sent it — this
        /// is the text Allow is approving.
        var inputJSON: String
        /// The input exceeded the budget and was cut: Allow is withdrawn
        /// (approving a truncated request is the blind approve).
        var truncated: Bool
        var createdMs: Int64

        var canOfferAllow: Bool { !truncated }
    }

    struct Verdict: Codable, Equatable {
        var id: String
        var allow: Bool
        var message: String
    }

    /// 8.0-β: the ask in one honest line — `Bash: npm run build` — for the
    /// waiting row's message and its notification. "权限" alone never
    /// satisfies the notification rule (say the requested thing itself), so
    /// the field order follows the vendor's own permission titles
    /// (command → file_path → url), the same order the hook path uses.
    /// Credentials go through the sanitizer like every other surfaced string.
    static func summary(toolName: String, inputJSON: String) -> String {
        let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = name.isEmpty ? "tool" : name
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return fallback }
        for key in ["command", "file_path", "url", "pattern", "path", "prompt"] {
            guard let value = object[key] as? String else { continue }
            let flat = value
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !flat.isEmpty else { continue }
            return ContentSanitizer.redact("\(fallback): \(String(flat.prefix(120)))")
        }
        return fallback
    }

    // MARK: - Spool layout

    static var spoolDirectoryOverride: URL?
    static func spoolDirectory() -> URL {
        if let spoolDirectoryOverride { return spoolDirectoryOverride }
        return ManagedSession.stateDirectory().appendingPathComponent("permissions", isDirectory: true)
    }
    static func requestsDirectory() -> URL {
        spoolDirectory().appendingPathComponent("requests", isDirectory: true)
    }
    static func verdictsDirectory() -> URL {
        spoolDirectory().appendingPathComponent("verdicts", isDirectory: true)
    }

    @discardableResult
    static func writeRequest(_ request: Request) -> Bool {
        try? FileManager.default.createDirectory(
            at: requestsDirectory(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(request) else { return false }
        return PrivateFile.write(data, to: requestsDirectory().appendingPathComponent(request.id + ".json"))
    }

    /// Filename decides identity (the spool rule); mismatches are refused.
    static func readRequests() -> [Request] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: requestsDirectory().path
        ) else { return [] }
        var out: [Request] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = requestsDirectory().appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder().decode(Request.self, from: data),
                  name == request.id + ".json"
            else { continue }
            out.append(request)
        }
        return out
    }

    static func removeRequest(id: String) {
        try? FileManager.default.removeItem(
            at: requestsDirectory().appendingPathComponent(id + ".json"))
    }

    @discardableResult
    static func writeVerdict(_ verdict: Verdict) -> Bool {
        try? FileManager.default.createDirectory(
            at: verdictsDirectory(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(verdict) else { return false }
        return PrivateFile.write(data, to: verdictsDirectory().appendingPathComponent(verdict.id + ".json"))
    }

    /// Single use: reading a verdict consumes its file.
    static func takeVerdict(id: String) -> Verdict? {
        let url = verdictsDirectory().appendingPathComponent(id + ".json")
        guard let data = try? Data(contentsOf: url),
              let verdict = try? JSONDecoder().decode(Verdict.self, from: data),
              verdict.id == id
        else { return nil }
        try? FileManager.default.removeItem(at: url)
        return verdict
    }

    /// The per-session MCP config the runner hands the CLI: Pulse's own
    /// binary as the server, the spool and the session identity in env.
    static func ensureConfig(managedID: String) -> String? {
        guard let executable = Bundle.main.executablePath else { return nil }
        try? FileManager.default.createDirectory(
            at: ManagedSession.stateDirectory(), withIntermediateDirectories: true
        )
        let url = ManagedSession.stateDirectory().appendingPathComponent(managedID + "-mcp.json")
        let config: [String: Any] = ["mcpServers": ["pulse": [
            "command": executable,
            "args": ["--permission-server"],
            "env": [
                "PULSE_PERMISSION_DIR": spoolDirectory().path,
                "PULSE_MANAGED_ID": managedID,
            ],
        ]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              PrivateFile.write(data, to: url)
        else { return nil }
        return url.path
    }

    // MARK: - The MCP dialect (pure; the CLI loop injects the decision)

    /// Line-delimited JSON-RPC, the three methods the permission flag needs.
    /// `decide` is injected: production blocks on the spool, tests answer
    /// instantly. Returns the response line, or nil for notifications.
    static func handle(
        line: String,
        managedID: String,
        nowMs: Int64,
        decide: (Request) -> Verdict
    ) -> String? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let method = (object["method"] as? String) ?? ""
        let id = object["id"]
        // A notification (no id) never gets a response, whatever the method.
        guard id != nil else { return nil }

        switch method {
        case "initialize":
            return respond(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: String]()],
                "serverInfo": ["name": "pulse-permission", "version": PulseVersion.semver],
            ])
        case "tools/list":
            return respond(id: id, result: [
                "tools": [[
                    "name": "approve",
                    "description": "Ask the Pulse user to approve or deny a tool use.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "tool_name": ["type": "string"],
                            "input": ["type": "object"],
                        ],
                    ],
                ]],
            ])
        case "tools/call":
            let params = (object["params"] as? [String: Any]) ?? [:]
            let arguments = (params["arguments"] as? [String: Any]) ?? [:]
            let toolName = (arguments["tool_name"] as? String) ?? "unknown"
            let input = arguments["input"] ?? [String: Any]()
            var inputJSON = "{}"
            var truncated = false
            if let inputData = try? JSONSerialization.data(
                withJSONObject: input, options: [.sortedKeys]
            ) {
                if inputData.count > maxInputBytes {
                    truncated = true
                    inputJSON = String(decoding: inputData.prefix(maxInputBytes), as: UTF8.self) + "…"
                } else {
                    inputJSON = String(decoding: inputData, as: UTF8.self)
                }
            }
            let request = Request(
                id: UUID().uuidString,
                managedID: managedID,
                toolName: String(toolName.prefix(120)),
                inputJSON: inputJSON,
                truncated: truncated,
                createdMs: nowMs
            )
            let verdict = decide(request)
            // The documented contract: the tool's text content carries a
            // JSON payload with behavior allow/deny. Allow echoes the
            // original input unchanged.
            let payload: [String: Any] = verdict.allow
                ? ["behavior": "allow", "updatedInput": input]
                : ["behavior": "deny", "message": verdict.message.isEmpty ? "denied" : verdict.message]
            let payloadText = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? #"{"behavior":"deny","message":"encode failed"}"#
            return respond(id: id, result: [
                "content": [["type": "text", "text": payloadText]],
            ])
        default:
            return respond(id: id, error: "method not found: \(method)")
        }
    }

    /// Production decision: publish the ask, block on the verdict file,
    /// deny on timeout — and clean the request away whatever happened.
    static func blockingDecide(
        _ request: Request,
        pollMs: UInt32 = 200,
        timeoutMs: Int64 = ManagedPermission.timeoutMs
    ) -> Verdict {
        guard writeRequest(request) else {
            return Verdict(id: request.id, allow: false, message: "spool write failed")
        }
        defer { removeRequest(id: request.id) }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let verdict = takeVerdict(id: request.id) {
                return verdict
            }
            usleep(pollMs * 1000)
        }
        return Verdict(id: request.id, allow: false, message: "timeout")
    }

    private static func respond(id: Any?, result: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private static func respond(id: Any?, error: String) -> String {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(),
                "error": ["code": -32601, "message": error]])
    }

    private static func encode(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? #"{"jsonrpc":"2.0"}"#
    }

    // MARK: - The subcommand's loop

    /// `PulseBar --permission-server`: stdin lines in, response lines out.
    /// Runs before any AppKit exists; exits with the pipe.
    static func runServer() -> Int32 {
        let managedID = ProcessInfo.processInfo.environment["PULSE_MANAGED_ID"] ?? ""
        if let dir = ProcessInfo.processInfo.environment["PULSE_PERMISSION_DIR"] {
            spoolDirectoryOverride = URL(fileURLWithPath: dir, isDirectory: true)
        }
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            if let response = handle(
                line: line, managedID: managedID, nowMs: nowMs,
                decide: { blockingDecide($0) }
            ) {
                print(response)
                // stdout must flush per message — the CLI is waiting on it.
                fflush(stdout)
            }
        }
        return 0
    }
}
