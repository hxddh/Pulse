// Pulse — Pi extension (pulse-hook). Installed by Pulse; remove it from
// Pulse Settings → Hooks. It observes lifecycle events and hands each to
// pulse-hook, one at a time and in order. It never throws, never awaits
// a child, and returns nothing to Pi.
import { spawn } from "node:child_process"

const PULSE_HOOK = /*__PULSE_HOOK__*/"/tmp/pulse-hook"
const EVENTS = [/*__EVENTS__*/]

// One child at a time: the next is spawned after the one before it
// exited, or GUARD_MS passed.
const GUARD_MS = 1500
const QUEUE_MAX = 64
// Dropped from a full queue last: a block, its answer, the turn's end.
const KEEP = new Set(["ui_prompt_start", "ui_prompt_end", "agent_settled"])
const QUEUE = []
let busy = false

function spawnHook(event, payload, onDone) {
  let finished = false
  let timer = undefined
  const finish = () => {
    if (finished) return
    finished = true
    if (timer !== undefined) clearTimeout(timer)
    if (onDone) onDone()
  }
  try {
    const child = spawn(PULSE_HOOK, ["pi", event, JSON.stringify(payload)], {
      detached: true,
      stdio: "ignore",
    })
    child.on("error", finish)
    child.on("exit", finish)
    child.unref()
  } catch {
    queueMicrotask(finish)
  }
  if (onDone) {
    timer = setTimeout(finish, GUARD_MS)
    if (timer && typeof timer.unref === "function") timer.unref()
  }
}

function pump() {
  if (busy) return
  const next = QUEUE.shift()
  if (!next) return
  busy = true
  spawnHook(next[0], next[1], () => {
    busy = false
    pump()
  })
}

function send(event, payload) {
  try {
    QUEUE.push([event, payload])
    while (QUEUE.length > QUEUE_MAX) {
      let drop = QUEUE.findIndex((item) => !KEEP.has(item[0]))
      if (drop < 0) drop = 0
      QUEUE.splice(drop, 1)
    }
    pump()
  } catch {}
}

// Pi is going away: whatever is still queued is dropped — children
// spawned together take the log's lock in any order, and a line
// numbered after the session's end would revive it — and the
// shutdown goes now, without waiting on the child before it.
function shutdown(event, payload) {
  try {
    QUEUE.length = 0
    spawnHook(event, payload)
  } catch {}
}

// A subagent (`pi --mode json -p`) or a one-shot print run is nobody's
// session: it sends nothing.
function quiet(ctx) {
  try {
    return !!ctx && (ctx.mode === "json" || ctx.mode === "print")
  } catch {
    return false
  }
}

// The argument that says what a tool works on, by tool.
const TARGET_KEYS = new Map([
  ["bash", ["command"]],
  ["powershell", ["command"]],
  ["read", ["path", "file_path"]],
  ["edit", ["path", "file_path"]],
  ["write", ["path", "file_path"]],
  ["ls", ["path"]],
  ["grep", ["pattern"]],
  ["find", ["pattern"]],
])
const FALLBACK_KEYS = ["command", "path", "file_path", "pattern", "url", "query"]
// Tool call id → its one short argument (tool_execution_end has none).
const ARGS = new Map()
// The run's last assistant words or error, from agent_end.
let lastRun = {}

function oneArgument(toolName, args) {
  if (!args || typeof args !== "object") return undefined
  const keys = TARGET_KEYS.get(String(toolName || "").toLowerCase()) || FALLBACK_KEYS
  for (const key of keys) {
    if (typeof args[key] === "string" && args[key]) return { [key]: args[key].slice(0, 2000) }
  }
  return undefined
}

function text(content) {
  if (typeof content === "string") return content
  if (!Array.isArray(content)) return ""
  return content
    .filter((part) => part && part.type === "text" && typeof part.text === "string")
    .map((part) => part.text)
    .join("\n")
}

// A skill invocation is said as the person typed it: /skill:name args.
const SKILL = /^<skill name="([^"]+)" location="[^"]*">\n[\s\S]*?\n<\/skill>(?:\n\n([\s\S]+))?$/
function promptText(raw) {
  const m = SKILL.exec(raw)
  if (!m) return raw
  const args = m[2] ? m[2].trim() : ""
  return args ? "/skill:" + m[1] + " " + args : "/skill:" + m[1]
}

function sessionName(ctx) {
  try {
    const name = ctx.sessionManager.getSessionName()
    return typeof name === "string" ? name.slice(0, 2000) : ""
  } catch {
    return ""
  }
}

function context(ctx) {
  const out = { session_id: "", cwd: "", pid: process.pid }
  try { out.session_id = ctx.sessionManager.getSessionId() || "" } catch {}
  try { out.cwd = ctx.cwd || "" } catch {}
  return out
}

export default function (pi) {
  pi.on("agent_end", (event, ctx) => {
    try {
      if (quiet(ctx)) return
      lastRun = {}
      const messages = event && Array.isArray(event.messages) ? event.messages : []
      for (let i = messages.length - 1; i >= 0; i--) {
        const m = messages[i]
        if (!m || m.role !== "assistant") continue
        if (m.stopReason === "error" && typeof m.errorMessage === "string" && m.errorMessage) {
          lastRun.error = m.errorMessage.slice(0, 2000)
        } else {
          const words = text(m.content).trim()
          if (words) lastRun.last_assistant_message = words.slice(0, 2000)
        }
        break
      }
    } catch {}
  })
  for (const name of EVENTS) {
    pi.on(name, (event, ctx) => {
      try {
        if (quiet(ctx)) return
        // A reload keeps the same session running.
        if ((name === "session_start" || name === "session_shutdown") && event && event.reason === "reload") return
        // Only the person's own message is a prompt.
        if (name === "message_start" && !(event && event.message && event.message.role === "user")) return
        // A call another tool made is folded into its caller.
        if ((name === "tool_execution_start" || name === "tool_execution_end") && event && event.parentToolCallId) return
        const payload = context(ctx)
        if (name === "ui_prompt_start" || name === "ui_prompt_end") {
          if (event && typeof event.kind === "string") payload.kind = event.kind
          if (event && typeof event.title === "string") payload.title = event.title
        }
        if (name === "session_start") payload.session_name = sessionName(ctx)
        if (name === "session_info_changed") {
          payload.session_name = event && typeof event.name === "string" ? event.name.slice(0, 2000) : ""
        }
        if (name === "message_start") {
          const prompt = promptText(text(event.message.content).trim())
          if (prompt) payload.prompt = prompt.slice(0, 2000)
        }
        if (name === "tool_execution_start" && event) {
          if (typeof event.toolName === "string") payload.tool_name = event.toolName.slice(0, 64)
          const input = oneArgument(event.toolName, event.args)
          if (input) {
            payload.tool_input = input
            if (typeof event.toolCallId === "string") {
              ARGS.set(event.toolCallId, input)
              if (ARGS.size > 256) ARGS.delete(ARGS.keys().next().value)
            }
          }
        }
        if (name === "tool_execution_end" && event) {
          if (typeof event.toolName === "string") payload.tool_name = event.toolName.slice(0, 64)
          const input = ARGS.get(event.toolCallId)
          if (input) payload.tool_input = input
          ARGS.delete(event.toolCallId)
          payload.is_error = event.isError === true
          if (typeof event.durationMs === "number" && event.durationMs >= 0) payload.duration_ms = Math.round(event.durationMs)
        }
        if (name === "agent_start") lastRun = {}
        if (name === "agent_settled") {
          if (event && event.aborted === true) payload.aborted = true
          else Object.assign(payload, lastRun)
          lastRun = {}
        }
        // A reason is a shutdown's why, a start's source; on a prompt it is
        // not the ask.
        if (name === "session_shutdown" && event && typeof event.reason === "string") payload.reason = event.reason.slice(0, 40)
        if (name === "session_start" && event && typeof event.reason === "string") payload.source = event.reason.slice(0, 40)
        if (name === "session_shutdown") shutdown(name, payload)
        else send(name, payload)
      } catch {}
    })
  }
}
