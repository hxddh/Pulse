import Foundation
@testable import PulseKit

// The proof layer's command-line half: what `scripts/e2e.sh` and
// `scripts/js_adapters_test.mjs` ask of the compiled code, answered before
// AppKit starts (no WindowServer, no single-instance lock):
//
//   --install-hooks=<home> [--runner=<exe>]
//       install every agent's hook into <home> with the real installer
//       (`HooksInstaller`, its home redirected the way the tests redirect
//       it) and point the launcher at <exe> — the packaged PulseBar — instead
//       of this driver. Only agents whose vendor folder exists in <home>.
//   --dump-snapshot=<json>
//       replay the event log (`EventLog.path`: `PULSE_HOME` when set) into a
//       `SessionBook`, line by line, projecting after each as `ScanEngine`
//       does, and write the tray it ends with — lamp, counts, rows — and
//       the banners a `WaitLedger` planned and withdrew on the way.
//   --write-adapters=<dir> [--launcher=<path>]
//       write the Pi extension and the OpenCode plugin exactly as the
//       installer renders them (`pi.js`, `opencode.js`).
//
// QA only: the shipping app reads none of these flags
// (`scripts/package_check.py` fails a binary that carries one).
enum ProofDriver {
    static func value(_ flag: String, in arguments: [String]) -> String? {
        arguments.first(where: { $0.hasPrefix(flag) }).map { String($0.dropFirst(flag.count)) }
    }

    /// The exit code of the proof command these arguments name; nil when
    /// they name none and the QA driver launches the app.
    static func run(_ arguments: [String]) -> Int32? {
        if let home = value("--install-hooks=", in: arguments) {
            return installHooks(home: home, runner: value("--runner=", in: arguments))
        }
        if let path = value("--dump-snapshot=", in: arguments) {
            return dumpSnapshot(to: path)
        }
        if let directory = value("--write-adapters=", in: arguments) {
            return writeAdapters(to: directory, launcher: value("--launcher=", in: arguments) ?? "/tmp/pulse-hook")
        }
        return nil
    }

    // MARK: - Install

    static func installHooks(home: String, runner: String?) -> Int32 {
        guard !home.isEmpty else {
            print("install-hooks: name a home folder")
            return 2
        }
        HooksInstaller.homeOverride = URL(fileURLWithPath: home, isDirectory: true)
        let results: [HooksInstaller.AgentResult]
        do {
            results = try HooksInstaller.install()
        } catch {
            print("install-hooks: the launcher could not be written: \(error.localizedDescription)")
            return 1
        }
        var ok = !results.isEmpty
        for result in results {
            print("install-hooks \(result.line)")
            if result.failure != nil { ok = false }
        }
        if let runner, !runner.isEmpty {
            do {
                try (runner + "\n").write(to: HooksInstaller.runnerPathURL, atomically: true, encoding: .utf8)
            } catch {
                print("install-hooks: the runner path could not be written: \(error.localizedDescription)")
                return 1
            }
        }
        print("install-hooks launcher \(HooksInstaller.launcherURL.path)")
        return ok ? 0 : 1
    }

    // MARK: - Snapshot

    static func dumpSnapshot(to path: String) -> Int32 {
        guard let chunk = EventLog.read(after: nil) else {
            print("dump-snapshot: the event log could not be read")
            return 1
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var book = SessionBook()
        var ledger = WaitLedger()
        var previous: [SessionKey: Int64] = [:]
        var last: TrayState?
        var planned: [String] = []
        var deferred: [String] = []
        var withdrawn: [String] = []
        // One projection per line, as the engine lands each read: a wait
        // raised and answered between two dumps still leaves its banner's
        // history.
        for record in chunk.records {
            book.apply(record, nowMs: nowMs)
            book.settleHeldTurns(nowMs: nowMs)
            let state = TrayState.project(
                book: book,
                processes: [],
                context: TrayState.Context(nowMs: nowMs, previousWaits: previous)
            )
            previous = state.waitingSince
            withdrawn += ledger.reconcile(
                rows: state.rows, edges: Set(state.newlyBlocked.map(\.key)), nowMs: nowMs
            ).sorted()
            for row in state.newlyBlocked {
                let id = WaitLedger.bannerID(row.key)
                // Raised in front of the person: held, not bannered now.
                if row.wait?.inFront == true {
                    deferred.append(id)
                    continue
                }
                ledger.markNotified(row.key, nowMs: nowMs, bannerID: id)
                planned.append(id)
            }
            last = state
        }
        let rows = last?.rows ?? []
        let counts = TrayState.Counts(rows: rows)
        let open = ledger.waits.values.compactMap { $0.dismissed ? nil : $0.bannerID }.sorted()
        let snapshot: [String: Any] = [
            "lines": chunk.records.count,
            "lamp": (last?.snapshot.lamp ?? .idle).rawValue,
            "counts": [
                "blocked": counts.blocked,
                "running": counts.running,
                "stalled": counts.stalled,
                "yourTurn": counts.yourTurn,
                "processOnly": counts.processOnly,
                "recent": counts.recent,
            ],
            "rows": rows.map(describe),
            "banners": [
                "planned": planned,
                "deferred": deferred,
                "withdrawn": withdrawn,
                "open": open,
            ],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            print("dump-snapshot: \(error.localizedDescription)")
            return 1
        }
        print("dump-snapshot wrote \(path): \(chunk.records.count) lines, \(rows.count) rows")
        return 0
    }

    static func describe(_ row: AgentRow) -> [String: Any] {
        var out: [String: Any] = ["key": row.key.description, "agent": row.agent.rawValue, "task": row.task]
        switch row.status {
        case .needsYou(let block):
            out["status"] = "needsYou"
            out["kind"] = block.kind.rawValue
            out["ask"] = block.ask
            out["tool"] = block.tool
            out["inFront"] = block.inFront
        case .running(let stalled):
            out["status"] = stalled ? "stalled" : "running"
        case .yourTurn:
            out["status"] = "yourTurn"
        case .recent(let reason):
            out["status"] = "recent"
            switch reason {
            case .atPrompt: out["reason"] = "atPrompt"
            case .ended: out["reason"] = "ended"
            case .quiet: out["reason"] = "quiet"
            case .silent: out["reason"] = "silent"
            }
        case .processOnly:
            out["status"] = "processOnly"
        }
        return out
    }

    // MARK: - Modules

    static func writeAdapters(to directory: String, launcher: String) -> Int32 {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let modules: [(agent: AgentID, file: String)] = [(.pi, "pi.js"), (.opencode, "opencode.js")]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for module in modules {
                guard case .module(let render) = module.agent.spec.hooks.format else {
                    print("write-adapters: \(module.agent.rawValue) is not a module")
                    return 1
                }
                // As `HooksInstaller.ownedFile` renders it.
                let text = render(launcher, module.agent.spec.hooks.events.map(\.name))
                try text.write(to: folder.appendingPathComponent(module.file), atomically: true, encoding: .utf8)
            }
        } catch {
            print("write-adapters: \(error.localizedDescription)")
            return 1
        }
        print("write-adapters wrote pi.js and opencode.js into \(folder.path)")
        return 0
    }
}
