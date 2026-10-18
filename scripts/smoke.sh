#!/usr/bin/env bash
# The owner's ~10-minute real-Mac check, before a prerelease is promoted.
# Interactive: it checks what it can read, asks you to do what only a person
# can (a real Claude permission prompt, a real Pi prompt, the answer, a
# click), watches events.tsv for the lines each step must write, and prints
# a report in Chinese to paste into the release thread.
#
#   ./scripts/smoke.sh [/path/to/Pulse.app]
#
# Read-only: it reads the app, the hook ledger, the vendor configs and the
# event log; it writes nothing but its own temp file, and makes no network
# connection. Every question can be skipped (s).
set -uo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this script must run on macOS" >&2
  exit 2
fi

APP="${1:-/Applications/Pulse.app}"
SUPPORT="$HOME/Library/Application Support/Pulse"
LOG="$SUPPORT/events.tsv"
REPORT="$(mktemp "${TMPDIR:-/tmp}/pulse-smoke.XXXXXX")"
trap 'rm -f "$REPORT"' EXIT
WAIT_SECONDS="${PULSE_SMOKE_WAIT:-90}"

say() { printf '%s\n' "$*"; }
note() { printf '%s\n' "$*" >>"$REPORT"; }
# result <label> <ok|fail|skip> [detail]
result() {
  local mark
  case "$2" in
    ok) mark="✅" ;;
    fail) mark="❌" ;;
    *) mark="⏭️" ;;
  esac
  say "  $mark $1${3:+ — $3}"
  note "- $mark $1${3:+ — $3}"
}

# ask <question>: y / n / s, the answer in $REPLY_KIND (ok / fail / skip).
ask() {
  local answer
  while true; do
    read -r -p "$1 [y/n/s] " answer </dev/tty || answer="s"
    case "$answer" in
      y|Y|是) REPLY_KIND=ok; return ;;
      n|N|否) REPLY_KIND=fail; return ;;
      s|S|"") REPLY_KIND=skip; return ;;
    esac
  done
}

pause() {
  local answer
  read -r -p "$1 （完成后按回车，输入 s 跳过）" answer </dev/tty || answer="s"
  [[ "$answer" != "s" && "$answer" != "S" ]]
}

# The log's last seq: lines past it are this step's.
last_seq() {
  [[ -f "$LOG" ]] || { echo 0; return; }
  awk -F'\t' 'NF == 15 && $1 ~ /^[0-9]+$/ { seq = $1 } END { print seq + 0 }' "$LOG"
}

# wait_line <since-seq> <agent> <kind-regex>: the first matching line past
# <since-seq> within WAIT_SECONDS, printed as "kind event message".
wait_line() {
  local since="$1" agent="$2" kinds="$3" end=$((SECONDS + WAIT_SECONDS)) hit
  while (( SECONDS < end )); do
    if [[ -f "$LOG" ]]; then
      hit="$(awk -F'\t' -v since="$since" -v agent="$agent" -v kinds="$kinds" \
        'NF == 15 && $1 + 0 > since && $3 == agent && $4 ~ ("^(" kinds ")$") { print $4 " · " $5 " · " $15; exit }' "$LOG")"
      if [[ -n "$hit" ]]; then
        echo "$hit"
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

version="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null || echo "?")"
note "## Pulse 真机冒烟报告"
note ""
note "- 版本：$version（$APP）"
note "- macOS：$(sw_vers -productVersion 2>/dev/null)（$(uname -m)）"
note "- 时间：$(date '+%Y-%m-%d %H:%M')"
note ""

say "== 1 · 应用 =="
note "### 应用"
if [[ ! -x "$APP/Contents/MacOS/PulseBar" ]]; then
  result "找到 Pulse.app" fail "$APP 不存在"
else
  result "找到 Pulse.app" ok "$version"
  if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
    result "隔离属性 (quarantine)" skip "仍带 com.apple.quarantine：首次打开需「仍要打开」或 xattr -dr"
  else
    result "隔离属性 (quarantine)" ok "已去除"
  fi
  if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    authority="$(codesign -dv "$APP" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
    result "代码签名" ok "${authority:-ad-hoc}"
  else
    result "代码签名" fail "codesign --verify 未通过"
  fi
fi
if pgrep -x PulseBar >/dev/null 2>&1; then
  result "Pulse 正在运行" ok
else
  result "Pulse 正在运行" fail "请先打开 Pulse 再继续"
fi

say ""
say "== 2 · 钩子 =="
note ""
note "### 钩子"
LAUNCHER="$SUPPORT/pulse-hook"
if [[ -x "$LAUNCHER" ]]; then
  if xattr -p com.apple.quarantine "$LAUNCHER" >/dev/null 2>&1; then
    result "pulse-hook 启动器" fail "带隔离属性"
  else
    result "pulse-hook 启动器" ok
  fi
  runner="$(cat "$SUPPORT/hook-runner.path" 2>/dev/null)"
  if [[ -n "$runner" && -x "$runner" ]]; then
    result "启动器指向" ok "$runner"
  else
    result "启动器指向" fail "hook-runner.path 为空或不可执行"
  fi
else
  result "pulse-hook 启动器" fail "$LAUNCHER 不存在：在 设置 → 钩子 安装"
fi
if [[ -s "$SUPPORT/hook-installs.json" ]]; then
  result "安装记录 hook-installs.json" ok
else
  result "安装记录 hook-installs.json" skip "没有记录"
fi
for pair in "Claude:.claude/settings.json" "Codex:.codex/hooks.json" "Cursor:.cursor/hooks.json" \
            "Pi:.pi/agent/extensions/pulse.js" "Copilot:.copilot/hooks/pulse.json" \
            "OpenCode:.config/opencode/plugins/pulse.js"; do
  name="${pair%%:*}" file="$HOME/${pair#*:}"
  if grep -q "pulse-hook" "$file" 2>/dev/null; then
    result "$name 钩子" ok "~/${pair#*:}"
  elif [[ -e "$file" ]]; then
    result "$name 钩子" fail "~/${pair#*:} 中没有 pulse-hook"
  else
    result "$name 钩子" skip "未安装（~/${pair#*:} 不存在）"
  fi
done

say ""
say "== 3 · 真实提示 =="
say "接下来每一步请在真实的代理里操作；脚本会读取 events.tsv 中新写入的行（最多等 ${WAIT_SECONDS} 秒）。"
note ""
note "### 真实提示"

# Claude: a real permission prompt, then its answer.
mark="$(last_seq)"
if pause "① 在终端里打开 Claude Code（普通交互模式，不要 -p），让它执行一条需要你批准的命令，例如：请运行 touch /tmp/pulse-smoke 。看到 Claude 的权限提示后"; then
  if hit="$(wait_line "$mark" claude 'permission|question')"; then
    result "Claude 权限提示写入事件" ok "$hit"
  else
    result "Claude 权限提示写入事件" fail "${WAIT_SECONDS} 秒内没有 claude permission 行"
  fi
  ask "   菜单栏的灯变红了吗？"; result "Claude：灯变红" "$REPLY_KIND"
  ask "   收到「需要你」横幅了吗？（若该终端在最前面，横幅会推迟约 30 秒或不出现）"; result "Claude：横幅" "$REPLY_KIND"
  mark="$(last_seq)"
  if pause "② 在 Claude 的提示里批准这次请求"; then
    if hit="$(wait_line "$mark" claude 'tool|done|working|turn')"; then
      result "Claude 回答写入事件" ok "$hit"
    else
      result "Claude 回答写入事件" fail "批准后没有新的 claude 行"
    fi
    ask "   灯是否离开红色（运行中或熄灭），横幅是否被撤回？"; result "Claude：回答后灯与横幅" "$REPLY_KIND"
  else
    result "Claude 回答" skip
  fi
else
  result "Claude 权限提示" skip
fi

# Pi: a real ui prompt (a confirm or a select an extension raises).
mark="$(last_seq)"
if pause "③ 在 Pi（交互模式）里触发一个确认或选择提示（任何扩展的 ctx.ui.confirm / select）。看到提示后"; then
  if hit="$(wait_line "$mark" pi 'permission|question')"; then
    result "Pi 提示写入事件" ok "$hit"
  else
    result "Pi 提示写入事件" fail "${WAIT_SECONDS} 秒内没有 pi ui_prompt_start 行"
  fi
  ask "   菜单栏的灯变红了吗？"; result "Pi：灯变红" "$REPLY_KIND"
  mark="$(last_seq)"
  if pause "④ 回答 Pi 的提示"; then
    if hit="$(wait_line "$mark" pi 'done|tool|working|turn')"; then
      result "Pi 回答写入事件" ok "$hit"
    else
      result "Pi 回答写入事件" fail "回答后没有新的 pi 行"
    fi
    ask "   灯是否离开红色？"; result "Pi：回答后灯" "$REPLY_KIND"
  else
    result "Pi 回答" skip
  fi
else
  result "Pi 提示" skip
fi

# Click to land.
if pause "⑤ 再让 Claude 提一次权限请求，然后点击托盘里那一行（或横幅）"; then
  ask "   是否跳到了提出请求的那个终端标签 / 窗口？"; result "点击落地" "$REPLY_KIND"
else
  result "点击落地" skip
fi

say ""
say "== 报告（复制下面的内容）=="
say ""
cat "$REPORT"
