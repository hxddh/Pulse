// Generated from PulseKit/Agents/JS/*.js by scripts/sync_js_modules.py.
// Edit the real .js files directly, then run `python3 scripts/sync_js_modules.py`.

extension HookModules {
    package static let orderedSendTemplate = #"""
const PULSE_HOOK = /*__PULSE_HOOK__*/"/tmp/pulse-hook"
const GUARD_MS = 1500
const QUEUE_MAX = 64
const KEEP = new Set([/*__KEEP__*/])
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
    const child = spawn(PULSE_HOOK, [/*__AGENT__*/"opencode", event, JSON.stringify(payload)], {
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

"""#

    package static let piModuleTemplate = #"""
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

// A subagent (`pi --mode json -p`), a one-shot print run, or a headless RPC
// backend (`pi --mode rpc`) is nobody's interactive terminal session.
function quiet(ctx) {
  try {
    return !!ctx && (ctx.mode === "json" || ctx.mode === "print" || ctx.mode === "rpc")
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
  // Track the active session id on this Pi process so `/new`, `/resume`, or
  // `/fork` cleanly ends the superseded session before starting the next one.
  let activeSessionId = ""
  let activeCwd = ""

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
        // Skip ephemeral runs without a session id (e.g. `--no-session`).
        if (!payload.session_id) return
        if (name === "session_start") {
          if (activeSessionId && activeSessionId !== payload.session_id) {
            send("session_shutdown", {
              session_id: activeSessionId,
              cwd: activeCwd || payload.cwd,
              pid: process.pid,
              reason: "switch",
            })
          }
          activeSessionId = payload.session_id
          activeCwd = payload.cwd
        } else if (name === "session_shutdown") {
          if (activeSessionId === payload.session_id) {
            activeSessionId = ""
            activeCwd = ""
          }
        } else if (!activeSessionId) {
          activeSessionId = payload.session_id
          activeCwd = payload.cwd
        }
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

"""#

    package static let openCodePluginTemplate = #"""
// Pulse — OpenCode plugin (pulse-hook). Installed by Pulse; remove it from
// Pulse Settings → Hooks. It observes OpenCode's event bus — 1.x through
// the plugin event hook, 2.x through ctx.event.subscribe — and hands each
// event it reads to pulse-hook, one at a time and in order. It never
// throws, never awaits a child, and changes nothing OpenCode does.
import { spawn } from "node:child_process"

/*__ORDERED_SEND__*/

const EVENTS = new Set([/*__EVENTS__*/])
// Child session id → parent id (subagents).
const PARENTS = new Map()
// Root session id → the ids of its open asks.
const OPEN = new Map()
// 1.x: tool call id → tool name; 2.x: tool call id → { name, target, at }.
const NAMES = new Map()
const CALLS = new Map()
// 1.x: tool call id → the phase last sent ("running", then "done").
const PHASES = new Map()
// 1.x: user message ids, and those whose prompt was sent; a text part
// seen before its message.
const USERS = new Set()
const PROMPTED = new Set()
const EARLY = new Map()
// Root session id → the title last sent, the status last sent.
const TITLES = new Map()
const STATUS = new Map()
// 1.x: roots whose run the person stopped: the idle after it is not a turn.
const ABORTED = new Set()
// 1.x: roots whose archive was sent.
const ARCHIVED = new Set()
const TARGET_KEYS = ["command", "filePath", "file_path", "path", "pattern", "url", "query", "description"]
const DEFAULT_TITLE = /^(New session|Child session) - \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/

function remember(map, key, value, max) {
  map.set(key, value)
  if (map.size > max) map.delete(map.keys().next().value)
}

function mark(set, key, max) {
  set.add(key)
  if (set.size > max) set.delete(set.values().next().value)
}

function text(value, max) {
  return typeof value === "string" ? value.slice(0, max || 2000) : ""
}

function list(value) {
  return Array.isArray(value) ? value.filter((item) => typeof item === "string").slice(0, 4).map((item) => item.slice(0, 500)) : []
}

function title(value) {
  const name = text(value).trim()
  return name && !DEFAULT_TITLE.test(name) ? name : ""
}

// A skill is its name; any other tool its first argument that says one.
function target(input, name) {
  if (!input || typeof input !== "object") return ""
  if (name === "skill" && typeof input.name === "string" && input.name) return input.name.slice(0, 2000)
  for (const key of TARGET_KEYS) {
    if (typeof input[key] === "string" && input[key]) return input[key].slice(0, 2000)
  }
  return ""
}

function learn(id, parent) {
  if (id && parent && id !== parent) remember(PARENTS, id, parent, 512)
}

function child(id) {
  return !!id && PARENTS.has(id)
}

function rootOf(id) {
  let current = id
  for (let i = 0; i < 8 && PARENTS.has(current); i++) current = PARENTS.get(current)
  return current
}

function opened(root, id) {
  if (!root || !id) return
  let open = OPEN.get(root)
  if (!open) {
    open = new Set()
    remember(OPEN, root, open, 256)
  }
  open.add(id)
}

// How many of the root's asks are still open once this one closed.
function closed(root, id) {
  const open = OPEN.get(root)
  if (!open) return 0
  if (id) open.delete(id)
  else open.clear()
  if (open.size === 0) OPEN.delete(root)
  return open.size
}

function deliver(type, own, directory, extra) {
  if (!EVENTS.has(type)) return
  const payload = { sessionID: own ? rootOf(own) : "", directory: directory || "" }
  send(type, Object.assign(payload, extra || {}))
}

// A child session's step is its own: sent under the root, marked
// with the child's id.
function step(own, extra) {
  if (child(own)) extra.subagent_id = own
  return extra
}

function forget(id) {
  TITLES.delete(id)
  STATUS.delete(id)
  OPEN.delete(id)
  ABORTED.delete(id)
  ARCHIVED.delete(id)
}

function prompt(own, id, directory, words) {
  if (PROMPTED.has(id)) return
  mark(PROMPTED, id, 512)
  ABORTED.delete(own)
  deliver("message.part.updated", own, directory, { phase: "prompt", prompt: words })
}

// 1.x: { type, properties }.
function legacy(event, base) {
  const type = event.type
  const p = event.properties || {}
  const info = p.info || {}
  const directory = info.directory || base
  if (type === "session.created" || type === "session.updated" || type === "session.deleted") {
    const id = info.id || p.sessionID || ""
    if (info.parentID) learn(id, info.parentID)
    if (child(id)) {
      if (type === "session.deleted") PARENTS.delete(id)
      return
    }
    if (type === "session.deleted") {
      forget(id)
      return deliver(type, id, directory)
    }
    // Archived (`time.archived`): the session is over, said once.
    if (type === "session.updated" && info.time && typeof info.time.archived === "number") {
      if (ARCHIVED.has(id)) return
      mark(ARCHIVED, id, 256)
      return deliver(type, id, directory, { archived: true })
    }
    if (type === "session.updated") ARCHIVED.delete(id)
    const name = title(info.title)
    if (type === "session.updated" && (!name || TITLES.get(id) === name)) return
    if (name) remember(TITLES, id, name, 256)
    return deliver(type, id, directory, { session_name: name })
  }
  if (type === "message.updated") {
    if (!info.id) return
    const early = EARLY.get(info.id)
    EARLY.delete(info.id)
    if (info.role !== "user") return
    mark(USERS, info.id, 512)
    const own = info.sessionID || p.sessionID || ""
    if (early !== undefined && !child(own)) prompt(own, info.id, directory, early)
    return
  }
  if (type === "message.part.updated") {
    const part = p.part || {}
    const own = part.sessionID || p.sessionID || ""
    if (part.type === "text") {
      if (child(own)) return
      if (part.synthetic || part.ignored || !part.messageID || PROMPTED.has(part.messageID)) return
      const words = text(part.text).trim()
      if (!words) return
      if (USERS.has(part.messageID)) return prompt(own, part.messageID, directory, words)
      if (!EARLY.has(part.messageID)) remember(EARLY, part.messageID, words, 64)
      return
    }
    if (part.type !== "tool" || !part.callID) return
    const state = part.state || {}
    const name = text(part.tool, 64)
    if (state.status === "pending" || state.status === "running") {
      remember(NAMES, part.callID, name, 256)
      if (state.status !== "running" || PHASES.has(part.callID)) return
      remember(PHASES, part.callID, "running", 512)
      return deliver(type, own, directory, step(own, { phase: "running", tool_name: name, target: target(state.input, name) }))
    }
    if (state.status !== "completed" && state.status !== "error") return
    if (PHASES.get(part.callID) === "done") return
    remember(PHASES, part.callID, "done", 512)
    NAMES.delete(part.callID)
    // A call an abort cut short is no step: the stop says it.
    if (state.status === "error" && state.metadata && state.metadata.interrupted === true) return
    const time = state.time || {}
    const took = typeof time.start === "number" && typeof time.end === "number" && time.end >= time.start ? Math.round(time.end - time.start) : 0
    return deliver(type, own, directory, step(own, {
      phase: "done",
      tool_name: name,
      target: target(state.input, name),
      is_error: state.status === "error",
      duration_ms: took,
    }))
  }
  const own = p.sessionID || ""
  if (type === "permission.asked" || type === "question.asked") {
    opened(rootOf(own), p.id)
    if (type === "question.asked") {
      const questions = (Array.isArray(p.questions) ? p.questions : [])
        .slice(0, 1)
        .map((q) => ({ question: text(q && q.question), header: text(q && q.header, 200) }))
      return deliver(type, own, directory, { questions })
    }
    const call = p.tool && p.tool.callID
    const permission = text(p.permission || p.type, 64)
    return deliver(type, own, directory, {
      permission,
      patterns: list(p.patterns),
      title: text(p.title),
      tool_name: (call && NAMES.get(call)) || permission,
    })
  }
  if (type === "permission.replied" || type === "question.replied" || type === "question.rejected") {
    return deliver(type, own, directory, { pending: closed(rootOf(own), p.requestID) })
  }
  if (child(own)) return
  if (type === "todo.updated") {
    const todos = (Array.isArray(p.todos) ? p.todos : [])
      .slice(0, 100)
      .map((item) => ({ status: text(item && item.status, 16), content: text(item && item.content, 500) }))
    return deliver(type, own, directory, { todos })
  }
  if (type === "session.diff") {
    const diff = Array.isArray(p.diff) ? p.diff : []
    if (!diff.length) return
    const files = diff
      .map((item) => (item && typeof item.file === "string" ? item.file.slice(0, 500) : ""))
      .filter(Boolean)
      .slice(0, 16)
    return deliver(type, own, directory, { files, count: diff.length })
  }
  if (type === "session.status") {
    const kind = text(p.status && p.status.type, 16)
    if (kind === "busy") ABORTED.delete(own)
    if (kind !== "busy" && kind !== "retry") {
      STATUS.delete(own)
      return
    }
    if (kind === "busy" && STATUS.get(own) === "busy") return
    remember(STATUS, own, kind, 256)
    return deliver(type, own, directory, { status: kind })
  }
  if (type === "session.idle") {
    STATUS.delete(own)
    // The run is over: no ask of it is still open.
    OPEN.delete(own)
    if (ABORTED.has(own)) {
      ABORTED.delete(own)
      return
    }
    return deliver(type, own, directory)
  }
  if (type === "session.error") {
    const e = p.error || {}
    const name = text(e.name, 64)
    const words = (e.data && typeof e.data.message === "string" && e.data.message) || (typeof e.message === "string" && e.message) || name
    if (name === "MessageAbortedError" && own) {
      mark(ABORTED, own, 256)
      OPEN.delete(own)
    }
    return deliver(type, own, directory, { error: text(words), error_name: name })
  }
  if (type === "session.compacted") return deliver(type, own, directory)
}

// 2.x: { type, data, location }.
function current(event, base) {
  const type = event.type
  const d = event.data || {}
  const directory = (event.location && event.location.directory) || base
  const own = d.sessionID || ""
  if (type === "session.created") {
    if (d.parentID) learn(own, d.parentID)
    if (child(own)) return
    const name = title(d.title)
    if (name) remember(TITLES, own, name, 256)
    return deliver(type, own, (d.location && d.location.directory) || directory, { session_name: name })
  }
  if (type === "session.deleted") {
    if (child(own)) {
      PARENTS.delete(own)
      return
    }
    forget(own)
    return deliver(type, own, directory)
  }
  if (type === "session.tool.input.started") {
    if (d.id) remember(CALLS, d.id, { name: text(d.name, 64), target: "", at: 0 }, 256)
    return
  }
  if (type === "permission.asked") {
    opened(rootOf(own), d.id)
    const call = d.source && d.source.id && CALLS.get(d.source.id)
    const permission = text(d.action, 64)
    return deliver(type, own, directory, {
      permission,
      patterns: list(d.resources),
      title: text(d.message),
      tool_name: (call && call.name) || permission,
    })
  }
  if (type === "permission.replied") {
    return deliver(type, own, directory, { pending: closed(rootOf(own), d.requestID) })
  }
  if (type === "form.created") {
    const form = d.form || {}
    const asker = form.sessionID || ""
    opened(rootOf(asker), form.id)
    const field = (Array.isArray(form.fields) && form.fields[0]) || {}
    const question = text(field.description) || text(field.title) || text(form.title)
    return deliver(type, asker, directory, { questions: [{ question, header: text(field.title, 200) }] })
  }
  if (type === "form.replied" || type === "form.cancelled") {
    return deliver(type, own, directory, { pending: closed(rootOf(own), d.id) })
  }
  if (type === "session.tool.called") {
    const call = CALLS.get(d.id) || { name: "", target: "", at: 0 }
    call.target = target(d.input, call.name)
    call.at = typeof event.created === "number" ? event.created : Date.now()
    if (d.id) remember(CALLS, d.id, call, 256)
    return deliver(type, own, directory, step(own, { tool_name: call.name || "tool", target: call.target }))
  }
  if (type === "session.tool.success" || type === "session.tool.failed") {
    const call = CALLS.get(d.id) || { name: "", target: "", at: 0 }
    CALLS.delete(d.id)
    const now = typeof event.created === "number" ? event.created : Date.now()
    return deliver(type, own, directory, step(own, {
      tool_name: call.name || "tool",
      target: call.target,
      is_error: type === "session.tool.failed",
      duration_ms: call.at > 0 && now >= call.at ? Math.round(now - call.at) : 0,
    }))
  }
  if (child(own)) return
  if (type === "session.renamed") {
    const name = title(d.title)
    if (!name || TITLES.get(own) === name) return
    remember(TITLES, own, name, 256)
    return deliver(type, own, directory, { session_name: name })
  }
  if (type === "session.inbox.enqueued") {
    const item = d.item || {}
    if (item.type !== "user") return
    return deliver(type, own, directory, { prompt: text(item.payload && item.payload.text).trim() })
  }
  // The run is over: no ask of it is still open.
  if (type === "session.execution.succeeded" || type === "session.execution.failed" || type === "session.execution.interrupted") {
    OPEN.delete(own)
  }
  if (type === "session.execution.failed") {
    const e = d.error || {}
    return deliver(type, own, directory, { error: text(e.message), error_name: text(e.type, 64) })
  }
  if (type === "session.execution.interrupted") return deliver(type, own, directory, { reason: text(d.reason, 32) })
  if (
    type === "session.execution.started" ||
    type === "session.execution.succeeded" ||
    type === "session.retry.scheduled" ||
    type === "session.compaction.ended"
  ) {
    return deliver(type, own, directory)
  }
}

export default {
  id: "pulse",
  // 1.x: the plugin's hooks; only `event`, which returns nothing.
  server: async ({ directory }) => ({
    event: async ({ event }) => {
      try {
        if (event && typeof event.type === "string") legacy(event, directory || "")
      } catch {}
    },
  }),
  // 2.x: read the bus until OpenCode unloads the plugin. Not awaited.
  setup: (ctx) => {
    const controller = new AbortController()
    let base = ""
    try {
      base = (ctx && ctx.location && ctx.location.directory) || ""
    } catch {}
    ;(async () => {
      try {
        if (!ctx || !ctx.event || typeof ctx.event.subscribe !== "function") return
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          try {
            if (!event || typeof event.type !== "string") continue
            const where = event.location && event.location.directory
            if (base && where && where !== base) continue
            current(event, base)
          } catch {}
        }
      } catch {}
    })()
    return () => {
      try {
        controller.abort()
      } catch {}
    }
  },
}

"""#
}
