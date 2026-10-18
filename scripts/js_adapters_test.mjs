#!/usr/bin/env node
// The two hook modules Pulse owns whole — the Pi extension and the OpenCode
// plugin — run under Node against a stub of their vendor's API, with the
// launcher replaced by a stub that appends each call's argv to a file. Each
// scenario replays a recorded event sequence and asserts the exact, ordered
// `pulse-hook <agent> <event> <payload>` calls the module made.
//
//   node scripts/js_adapters_test.mjs [<dir with pi.js and opencode.js>]
//
// With no directory, the modules are rendered from the Swift templates by
// scripts/render_adapters.py (Linux, no Swift). On macOS CI the QA driver
// renders them from the compiled code (`PulseQA --write-adapters=<dir>`)
// and this test runs against those files too.
//
// A case marked `knownBug` states the correct behaviour of a defect not yet
// fixed: it runs and is reported XFAIL without failing the run; when it
// starts passing it is reported XPASS — drop the mark then.
// PULSE_JS_VERBOSE=1 prints an XFAIL's difference too.
//
// No network, no vendor install; everything lives in a temp folder.
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const WORK = fs.mkdtempSync(path.join(os.tmpdir(), "pulse-js-adapters-"))
const STUB = path.join(WORK, "pulse-hook")
const CALLS = path.join(WORK, "calls.jsonl")
// Long enough for the slowest runner to spawn a node child; the queue is
// drained as soon as the expected calls are there.
const DRAIN_MS = 8000
const SETTLE_MS = 400

// The launcher: one JSON line per call, the argv after the program.
fs.writeFileSync(
  STUB,
  `#!${process.execPath}\n` +
    `require("node:fs").appendFileSync(${JSON.stringify(CALLS)}, JSON.stringify(process.argv.slice(2)) + "\\n")\n`,
)
fs.chmodSync(STUB, 0o755)

function render() {
  const arg = process.argv[2]
  if (arg) return path.resolve(arg)
  const out = path.join(WORK, "rendered")
  execFileSync("python3", [path.join(ROOT, "scripts", "render_adapters.py"), out], { stdio: "inherit" })
  return out
}

const SOURCE = render()
let instance = 0

// A fresh module instance per scenario (its queue and maps are module
// state), its launcher pointed at the stub.
async function load(file) {
  const text = fs.readFileSync(path.join(SOURCE, file), "utf8")
  const line = /^const PULSE_HOOK = .*$/m
  assert.match(text, line, `${file}: no PULSE_HOOK line`)
  const copy = path.join(WORK, `${path.basename(file, ".js")}-${++instance}.mjs`)
  fs.writeFileSync(copy, text.replace(line, `const PULSE_HOOK = ${JSON.stringify(STUB)}`))
  return (await import(pathToFileURL(copy).href)).default
}

function calls() {
  if (!fs.existsSync(CALLS)) return []
  return fs
    .readFileSync(CALLS, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [agent, event, payload] = JSON.parse(line)
      return [agent, event, JSON.parse(payload)]
    })
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function drain(count) {
  const deadline = Date.now() + DRAIN_MS
  while (calls().length < count && Date.now() < deadline) await sleep(25)
  await sleep(SETTLE_MS)
  return calls()
}

// --- Pi ---------------------------------------------------------------------

const PID = process.pid

function piContext(overrides = {}) {
  return {
    mode: "interactive",
    cwd: "/w",
    sessionManager: {
      getSessionId: () => "pi-s1",
      getSessionName: () => overrides.name ?? "",
    },
    ...overrides,
  }
}

async function piRun(events, ctx = piContext()) {
  const extension = await load("pi.js")
  const handlers = new Map()
  extension({
    on(name, handler) {
      if (!handlers.has(name)) handlers.set(name, [])
      handlers.get(name).push(handler)
    },
  })
  for (const [name, event] of events) {
    for (const handler of handlers.get(name) || []) {
      const result = handler(event, ctx)
      assert.equal(result, undefined, `pi ${name}: a handler returns nothing`)
    }
  }
  return handlers
}

const base = { session_id: "pi-s1", cwd: "/w", pid: PID }
const pi = (event, extra = {}) => ["pi", event, { ...base, ...extra }]
const user = (text) => ({ message: { role: "user", content: [{ type: "text", text }] } })

const scenarios = []
function scenario(name, run, options = {}) {
  scenarios.push({ name, run, ...options })
}

scenario("pi · a turn with tools", async () => {
  await piRun([
    ["session_start", { reason: "startup" }],
    ["agent_start", {}],
    ["message_start", user("Fix the build")],
    ["message_start", { message: { role: "assistant", content: [{ type: "text", text: "On it" }] } }],
    ["tool_execution_start", { toolCallId: "c1", toolName: "bash", args: { command: "npm test", timeout: 60 } }],
    ["tool_execution_start", { toolCallId: "c2", parentToolCallId: "c1", toolName: "read", args: { path: "a.ts" } }],
    ["tool_execution_end", { toolCallId: "c2", parentToolCallId: "c1", toolName: "read", isError: false }],
    ["tool_execution_end", { toolCallId: "c1", toolName: "bash", isError: false, durationMs: 1234.4 }],
    ["tool_execution_start", { toolCallId: "c3", toolName: "edit", args: { path: "src/a.ts", oldText: "x", newText: "y" } }],
    ["tool_execution_end", { toolCallId: "c3", toolName: "edit", isError: true, durationMs: 12 }],
    ["agent_end", { messages: [user("Fix the build").message, { role: "assistant", content: [{ type: "text", text: "All green." }], stopReason: "stop" }] }],
    ["agent_settled", {}],
  ])
  return [
    pi("session_start", { session_name: "" }),
    pi("agent_start"),
    pi("message_start", { prompt: "Fix the build" }),
    pi("tool_execution_start", { tool_name: "bash", tool_input: { command: "npm test" } }),
    pi("tool_execution_end", { tool_name: "bash", tool_input: { command: "npm test" }, is_error: false, duration_ms: 1234 }),
    pi("tool_execution_start", { tool_name: "edit", tool_input: { path: "src/a.ts" } }),
    pi("tool_execution_end", { tool_name: "edit", tool_input: { path: "src/a.ts" }, is_error: true, duration_ms: 12 }),
    pi("agent_settled", { last_assistant_message: "All green." }),
  ]
})

scenario("pi · a permission ask and its answer", async () => {
  await piRun([
    ["agent_start", {}],
    ["tool_execution_start", { toolCallId: "c1", toolName: "bash", args: { command: "rm -rf dist" } }],
    ["ui_prompt_start", { reason: "ui_prompt", kind: "confirm", title: "Allow bash: rm -rf dist?" }],
    ["ui_prompt_end", { reason: "ui_prompt", kind: "confirm", title: "Allow bash: rm -rf dist?" }],
    ["tool_execution_end", { toolCallId: "c1", toolName: "bash", isError: false, durationMs: 40 }],
  ])
  return [
    pi("agent_start"),
    pi("tool_execution_start", { tool_name: "bash", tool_input: { command: "rm -rf dist" } }),
    pi("ui_prompt_start", { kind: "confirm", title: "Allow bash: rm -rf dist?" }),
    pi("ui_prompt_end", { kind: "confirm", title: "Allow bash: rm -rf dist?" }),
    pi("tool_execution_end", { tool_name: "bash", tool_input: { command: "rm -rf dist" }, is_error: false, duration_ms: 40 }),
  ]
})

scenario("pi · a question, parallel prompts, a custom view", async () => {
  await piRun([
    ["ui_prompt_start", { reason: "ui_prompt", kind: "select", title: "Which branch?" }],
    ["ui_prompt_start", { reason: "ui_prompt", kind: "input", title: "Commit message" }],
    ["ui_prompt_end", { reason: "ui_prompt", kind: "select", title: "Which branch?" }],
    ["ui_prompt_end", { reason: "ui_prompt", kind: "input", title: "Commit message" }],
    ["ui_prompt_start", { reason: "ui_prompt", kind: "custom" }],
    ["ui_prompt_end", { reason: "ui_prompt", kind: "custom" }],
  ])
  return [
    pi("ui_prompt_start", { kind: "select", title: "Which branch?" }),
    pi("ui_prompt_start", { kind: "input", title: "Commit message" }),
    pi("ui_prompt_end", { kind: "select", title: "Which branch?" }),
    pi("ui_prompt_end", { kind: "input", title: "Commit message" }),
    pi("ui_prompt_start", { kind: "custom" }),
    pi("ui_prompt_end", { kind: "custom" }),
  ]
})

scenario("pi · names, a skill prompt, an error, an abort", async () => {
  await piRun(
    [
      ["session_start", { reason: "resume" }],
      ["session_info_changed", { name: "auth refactor" }],
      ["message_start", user('<skill name="review" location="/u/.pi/skills/review/SKILL.md">\nRead the diff.\n</skill>\n\nPR 12')],
      ["agent_end", { messages: [{ role: "assistant", content: [], stopReason: "error", errorMessage: "529 overloaded" }] }],
      ["agent_settled", {}],
      ["agent_start", {}],
      ["agent_end", { messages: [{ role: "assistant", content: [{ type: "text", text: "partial" }], stopReason: "aborted" }] }],
      ["agent_settled", { aborted: true }],
    ],
    piContext({ name: "auth" }),
  )
  return [
    pi("session_start", { session_name: "auth" }),
    pi("session_info_changed", { session_name: "auth refactor" }),
    pi("message_start", { prompt: "/skill:review PR 12" }),
    pi("agent_settled", { error: "529 overloaded" }),
    pi("agent_start"),
    pi("agent_settled", { aborted: true }),
  ]
})

scenario("pi · a subagent (json mode) and a reload send nothing", async () => {
  await piRun(
    [
      ["session_start", { reason: "startup" }],
      ["agent_start", {}],
      ["ui_prompt_start", { kind: "confirm", title: "x" }],
      ["session_shutdown", { reason: "quit" }],
    ],
    piContext({ mode: "json" }),
  )
  await piRun([
    ["session_start", { reason: "reload" }],
    ["session_shutdown", { reason: "reload" }],
    ["agent_start", {}],
  ])
  return [pi("agent_start")]
})

// Everything queued when Pi goes away still goes, the shutdown last.
const shutdownEvents = [
  ["agent_start", {}],
  ["tool_execution_start", { toolCallId: "c1", toolName: "bash", args: { command: "make" } }],
  ["tool_execution_end", { toolCallId: "c1", toolName: "bash", isError: false, durationMs: 5 }],
  ["agent_end", { messages: [{ role: "assistant", content: [{ type: "text", text: "Bye" }], stopReason: "stop" }] }],
  ["agent_settled", {}],
  ["session_shutdown", { reason: "quit" }],
]
const shutdownExpected = [
  pi("agent_start"),
  pi("tool_execution_start", { tool_name: "bash", tool_input: { command: "make" } }),
  pi("tool_execution_end", { tool_name: "bash", tool_input: { command: "make" }, is_error: false, duration_ms: 5 }),
  pi("agent_settled", { last_assistant_message: "Bye" }),
  pi("session_shutdown", { reason: "quit" }),
]

scenario(
  "pi · shutdown flushes every queued event",
  async () => {
    await piRun(shutdownEvents)
    return shutdownExpected
  },
  { compare: "multiset" },
)

// Known bug (31.0): `flush()` spawns every queued event at once while the
// child before them may still be running, so the log can number the
// shutdown before the turn's end. Correct: the queue drains in order.
scenario(
  "pi · shutdown flush keeps the order",
  async () => {
    await piRun(shutdownEvents)
    return shutdownExpected
  },
  { knownBug: "Pi shutdown flush reorders the queued events" },
)

// --- OpenCode 1.x -------------------------------------------------------------

async function legacyRun(events) {
  const plugin = await load("opencode.js")
  assert.equal(plugin.id, "pulse")
  const hooks = await plugin.server({ directory: "/w" })
  assert.deepEqual(Object.keys(hooks), ["event"], "1.x: only the event hook")
  for (const [type, properties] of events) {
    const result = await hooks.event({ event: { type, properties } })
    assert.equal(result, undefined)
  }
}

const oc = (event, sessionID, extra = {}) => ["opencode", event, { sessionID, directory: "/w", ...extra }]
const S1 = "ses_1"
const part = (callID, status, extra = {}) => ({
  part: { type: "tool", callID, tool: "bash", sessionID: S1, state: { status, ...extra } },
})

scenario("opencode 1.x · a turn with tools", async () => {
  await legacyRun([
    ["session.created", { info: { id: S1, directory: "/w", title: "New session - 2026-10-18T10:00:00.000Z" } }],
    ["message.part.updated", { part: { type: "text", text: "Fix login", messageID: "msg_1", sessionID: S1 } }],
    ["message.updated", { info: { id: "msg_1", role: "user", sessionID: S1 } }],
    ["session.status", { sessionID: S1, status: { type: "busy" } }],
    ["session.status", { sessionID: S1, status: { type: "busy" } }],
    ["message.part.updated", part("call_1", "pending")],
    ["message.part.updated", part("call_1", "running", { input: { command: "npm test" } })],
    ["message.part.updated", part("call_1", "running", { input: { command: "npm test" } })],
    ["message.part.updated", part("call_1", "completed", { input: { command: "npm test" }, time: { start: 1000, end: 2500 } })],
    ["message.part.updated", part("call_1", "completed", { input: { command: "npm test" }, time: { start: 1000, end: 2500 } })],
    ["message.part.updated", { part: { type: "text", text: "Done.", messageID: "msg_2", sessionID: S1 } }],
    ["message.updated", { info: { id: "msg_2", role: "assistant", sessionID: S1 } }],
    ["session.status", { sessionID: S1, status: { type: "idle" } }],
    ["session.idle", { sessionID: S1 }],
    ["session.updated", { info: { id: S1, title: "Fix the login test" } }],
    ["session.updated", { info: { id: S1, title: "Fix the login test" } }],
  ])
  return [
    oc("session.created", S1, { session_name: "" }),
    oc("message.part.updated", S1, { phase: "prompt", prompt: "Fix login" }),
    oc("session.status", S1, { status: "busy" }),
    oc("message.part.updated", S1, { phase: "running", tool_name: "bash", target: "npm test" }),
    oc("message.part.updated", S1, { phase: "done", tool_name: "bash", target: "npm test", is_error: false, duration_ms: 1500 }),
    oc("session.idle", S1),
    oc("session.updated", S1, { session_name: "Fix the login test" }),
  ]
})

scenario("opencode 1.x · a permission ask and its answer, a question", async () => {
  await legacyRun([
    ["message.part.updated", part("call_2", "pending")],
    ["permission.asked", { id: "per_1", sessionID: S1, permission: "bash", patterns: ["rm -rf dist"], title: "rm -rf dist", tool: { callID: "call_2", messageID: "msg_3" } }],
    ["permission.replied", { sessionID: S1, requestID: "per_1", reply: "once" }],
    ["question.asked", { id: "que_1", sessionID: S1, questions: [{ question: "Which database?", header: "DB", options: [{ label: "Postgres" }] }] }],
    ["question.replied", { sessionID: S1, requestID: "que_1", answers: [["Postgres"]] }],
    ["question.asked", { id: "que_2", sessionID: S1, questions: [{ question: "Deploy now?", header: "Deploy" }] }],
    ["question.rejected", { sessionID: S1, requestID: "que_2" }],
  ])
  return [
    oc("permission.asked", S1, { permission: "bash", patterns: ["rm -rf dist"], title: "rm -rf dist", tool_name: "bash" }),
    oc("permission.replied", S1, { pending: 0 }),
    oc("question.asked", S1, { questions: [{ question: "Which database?", header: "DB" }] }),
    oc("question.replied", S1, { pending: 0 }),
    oc("question.asked", S1, { questions: [{ question: "Deploy now?", header: "Deploy" }] }),
    oc("question.rejected", S1, { pending: 0 }),
  ]
})

scenario("opencode 1.x · parallel asks keep the lamp until the last answer", async () => {
  await legacyRun([
    ["permission.asked", { id: "per_a", sessionID: S1, permission: "bash", patterns: ["git push"] }],
    ["permission.asked", { id: "per_b", sessionID: S1, permission: "edit", patterns: ["src/a.ts"] }],
    ["permission.replied", { sessionID: S1, requestID: "per_a", reply: "once" }],
    ["permission.replied", { sessionID: S1, requestID: "per_b", reply: "reject" }],
  ])
  return [
    oc("permission.asked", S1, { permission: "bash", patterns: ["git push"], title: "", tool_name: "bash" }),
    oc("permission.asked", S1, { permission: "edit", patterns: ["src/a.ts"], title: "", tool_name: "edit" }),
    oc("permission.replied", S1, { pending: 1 }),
    oc("permission.replied", S1, { pending: 0 }),
  ]
})

scenario("opencode 1.x · a subagent's asks go under the root, the rest is dropped", async () => {
  await legacyRun([
    ["session.created", { info: { id: S1, directory: "/w", title: "Port" } }],
    ["session.created", { info: { id: "ses_c", parentID: S1, directory: "/w", title: "Child session - 2026-10-18T10:00:00.000Z" } }],
    ["message.part.updated", { part: { type: "tool", callID: "call_c", tool: "read", sessionID: "ses_c", state: { status: "running", input: { filePath: "a.ts" } } } }],
    ["permission.asked", { id: "per_c", sessionID: "ses_c", permission: "webfetch", patterns: ["https://example.com"] }],
    ["permission.replied", { sessionID: "ses_c", requestID: "per_c", reply: "always" }],
    ["session.status", { sessionID: "ses_c", status: { type: "busy" } }],
    ["session.idle", { sessionID: "ses_c" }],
    ["session.deleted", { info: { id: "ses_c" } }],
    ["session.error", { sessionID: S1, error: { name: "MessageAbortedError", data: { message: "The operation was aborted." } } }],
    ["session.idle", { sessionID: S1 }],
    ["session.deleted", { info: { id: S1 } }],
  ])
  return [
    oc("session.created", S1, { session_name: "Port" }),
    oc("permission.asked", S1, { permission: "webfetch", patterns: ["https://example.com"], title: "", tool_name: "webfetch" }),
    oc("permission.replied", S1, { pending: 0 }),
    oc("session.error", S1, { error: "The operation was aborted.", error_name: "MessageAbortedError" }),
    oc("session.deleted", S1),
  ]
})

// Known bug (31.0): an ask the turn left open — the run aborted, the ask
// never replied — stays in OPEN for good, so every later answer says
// another ask is still open and the lamp never goes out. Correct: once
// the turn is over, the next ask's answer is the last one.
scenario(
  "opencode 1.x · an ask the turn abandoned does not hold later answers",
  async () => {
    await legacyRun([
      ["permission.asked", { id: "per_x", sessionID: S1, permission: "bash", patterns: ["make"] }],
      ["session.error", { sessionID: S1, error: { name: "MessageAbortedError", data: { message: "aborted" } } }],
      ["session.idle", { sessionID: S1 }],
      ["message.part.updated", { part: { type: "text", text: "Try again", messageID: "msg_9", sessionID: S1 } }],
      ["message.updated", { info: { id: "msg_9", role: "user", sessionID: S1 } }],
      ["permission.asked", { id: "per_y", sessionID: S1, permission: "bash", patterns: ["make"] }],
      ["permission.replied", { sessionID: S1, requestID: "per_y", reply: "once" }],
    ])
    return [oc("permission.replied", S1, { pending: 0 })]
  },
  { knownBug: "OpenCode stale OPEN asks are never cleared", compare: "last" },
)

// --- OpenCode 2.x -------------------------------------------------------------

async function currentRun(events) {
  const plugin = await load("opencode.js")
  let release
  const done = new Promise((resolve) => (release = resolve))
  const ctx = {
    location: { directory: "/w" },
    event: {
      subscribe({ signal }) {
        return (async function* () {
          for (const event of events) {
            await sleep(1)
            yield event
          }
          release()
          await new Promise((resolve) => signal.addEventListener("abort", resolve, { once: true }))
        })()
      },
    },
  }
  const dispose = plugin.setup(ctx)
  assert.equal(typeof dispose, "function", "2.x: setup returns its disposer")
  await done
  await sleep(5)
  dispose()
}

const S2 = "ses_2"
const ev = (type, data, extra = {}) => ({ type, data, location: { directory: "/w" }, ...extra })

scenario("opencode 2.x · a run with tools, a form, a permission", async () => {
  await currentRun([
    ev("session.created", { sessionID: S2, title: "Port the cache" }),
    ev("session.execution.started", { sessionID: S2 }),
    ev("session.inbox.enqueued", { sessionID: S2, item: { type: "user", payload: { text: " Move the cache to Redis " } } }),
    ev("session.inbox.enqueued", { sessionID: S2, item: { type: "system", payload: { text: "reminder" } } }),
    ev("session.tool.input.started", { sessionID: S2, id: "t1", name: "read" }),
    ev("session.tool.called", { sessionID: S2, id: "t1", input: { filePath: "src/cache.ts" } }, { created: 1000 }),
    ev("session.tool.success", { sessionID: S2, id: "t1" }, { created: 1030 }),
    ev("session.tool.input.started", { sessionID: S2, id: "t2", name: "bash" }),
    ev("session.tool.called", { sessionID: S2, id: "t2", input: { command: "redis-cli ping" } }, { created: 2000 }),
    ev("permission.asked", { sessionID: S2, id: "per_2", action: "bash", resources: ["redis-cli ping"], message: "Run redis-cli ping?", source: { id: "t2" } }),
    ev("permission.replied", { sessionID: S2, requestID: "per_2", reply: "once" }),
    ev("session.tool.failed", { sessionID: S2, id: "t2" }, { created: 2900 }),
    ev("form.created", { form: { id: "frm_1", sessionID: S2, title: "Question", fields: [{ title: "Host", description: "Which Redis host?" }] } }),
    ev("form.replied", { sessionID: S2, id: "frm_1" }),
    ev("session.created", { sessionID: "ses_other", title: "Elsewhere" }, { location: { directory: "/elsewhere" } }),
    ev("session.retry.scheduled", { sessionID: S2 }),
    ev("session.execution.succeeded", { sessionID: S2 }),
    ev("session.execution.interrupted", { sessionID: S2, reason: "user" }),
    ev("session.deleted", { sessionID: S2 }),
  ])
  return [
    oc("session.created", S2, { session_name: "Port the cache" }),
    oc("session.execution.started", S2),
    oc("session.inbox.enqueued", S2, { prompt: "Move the cache to Redis" }),
    oc("session.tool.called", S2, { tool_name: "read", target: "src/cache.ts" }),
    oc("session.tool.success", S2, { tool_name: "read", target: "src/cache.ts", is_error: false, duration_ms: 30 }),
    oc("session.tool.called", S2, { tool_name: "bash", target: "redis-cli ping" }),
    oc("permission.asked", S2, { permission: "bash", patterns: ["redis-cli ping"], title: "Run redis-cli ping?", tool_name: "bash" }),
    oc("permission.replied", S2, { pending: 0 }),
    oc("session.tool.failed", S2, { tool_name: "bash", target: "redis-cli ping", is_error: true, duration_ms: 900 }),
    oc("form.created", S2, { questions: [{ question: "Which Redis host?", header: "Host" }] }),
    oc("form.replied", S2, { pending: 0 }),
    oc("session.retry.scheduled", S2),
    oc("session.execution.succeeded", S2),
    oc("session.execution.interrupted", S2, { reason: "user" }),
    oc("session.deleted", S2),
  ]
})

scenario("opencode 2.x · a subagent's form goes under the root", async () => {
  await currentRun([
    ev("session.created", { sessionID: S2, title: "" }),
    ev("session.created", { sessionID: "ses_k", parentID: S2, title: "Child session - 2026-10-18T10:00:00.000Z" }),
    ev("session.execution.started", { sessionID: "ses_k" }),
    ev("session.tool.called", { sessionID: "ses_k", id: "k1", input: { pattern: "TODO" } }, { created: 10 }),
    ev("form.created", { form: { id: "frm_k", sessionID: "ses_k", fields: [{ title: "Scope", description: "Search tests too?" }] } }),
    ev("form.cancelled", { sessionID: "ses_k", id: "frm_k" }),
    ev("session.execution.succeeded", { sessionID: "ses_k" }),
    ev("session.deleted", { sessionID: "ses_k" }),
  ])
  return [
    oc("session.created", S2, { session_name: "" }),
    oc("form.created", S2, { questions: [{ question: "Search tests too?", header: "Scope" }] }),
    oc("form.cancelled", S2, { pending: 0 }),
  ]
})

// --- Run ----------------------------------------------------------------------

let failed = 0
let xfail = 0
for (const s of scenarios) {
  fs.rmSync(CALLS, { force: true })
  let outcome = "ok"
  let detail = ""
  try {
    const expected = await s.run()
    const want = s.compare === "last" ? 1 : expected.length
    let got = await drain(want)
    if (s.compare === "last") got = got.slice(-1)
    if (s.compare === "multiset") {
      const key = (call) => JSON.stringify(call)
      got = [...got].sort((a, b) => key(a).localeCompare(key(b)))
      expected.sort((a, b) => key(a).localeCompare(key(b)))
    }
    assert.deepStrictEqual(got, expected)
  } catch (error) {
    outcome = "fail"
    detail = error && error.message ? error.message : String(error)
  }
  if (s.knownBug) {
    if (outcome === "fail") {
      xfail++
      console.log(`XFAIL ${s.name} — known bug: ${s.knownBug}`)
      if (process.env.PULSE_JS_VERBOSE) console.log(detail)
    } else {
      console.log(`XPASS ${s.name} — fixed? drop the knownBug mark (${s.knownBug})`)
    }
    continue
  }
  if (outcome === "fail") {
    failed++
    console.log(`FAIL  ${s.name}\n${detail}`)
  } else {
    console.log(`ok    ${s.name}`)
  }
}
fs.rmSync(WORK, { recursive: true, force: true })
console.log(
  `${scenarios.length - failed - xfail} passed, ${failed} failed, ${xfail} known bug${xfail === 1 ? "" : "s"} (xfail)`,
)
process.exit(failed ? 1 : 0)
