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
