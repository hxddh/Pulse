#!/bin/bash
# 4.0-β real-machine verification — the ten-minute pass for the two verbs
# only a real Mac can prove: typed delivery and dispatch.
#
# What CI already proves: escaping, collapsing, command construction, and
# channel routing (WorkbenchActuationTests). What ONLY this pass proves:
# that AppleScript tab-select + System Events keystroke actually land in the
# right tab on a real macOS with real TCC grants.
#
# Run on a Mac with Pulse.app installed and an agent session in Terminal/iTerm:
#   bash scripts/qa_workbench_actuation.sh
set -u

step() { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$2"; read -r -p "  [enter when done / Ctrl-C to abort] "; }

echo "Pulse 4.0-β actuation verification — follow each step, watch the outcome."

step "0. Preconditions" \
"  - Pulse running, Settings → Waiting signals → 「允许指挥台敲入终端」 ON.
  - A claude session running in Terminal.app (a real tty tab), visible in the tray."

step "1. Delivery precision (scene BE)" \
"  - In the session, get claude to ask a question (e.g. prompt: '问我一个问题再继续').
  - Open the Workbench (⌘⇧W), select that row: the wait card must show a reply
    box with 「发送到终端」 (not the copy button).
  - Put a DIFFERENT window in front (e.g. a browser). Type a reply in Pulse and
    press Send.
  EXPECT: the terminal comes forward, the correct tab is selected, the reply is
  typed THERE (never into the browser), Return is pressed, the card says 已送达.
  First run may show the Automation/Accessibility TCC prompt — grant and redo."

step "2. Delivery honesty" \
"  - Close the session's terminal tab entirely. Send again from Pulse.
  EXPECT: card says 没找到该会话的终端标签页 —— 什么都没敲. Nothing typed anywhere.
  - System Settings → Privacy → Accessibility: revoke Pulse. Send again.
  EXPECT: card says 敲入失败 —— 检查自动化权限 (tab may focus; no text appears).
  Re-grant afterwards."

step "3. Non-tty rows keep the old path" \
"  - Select a session running inside an IDE (Cursor/VS Code) or with the
    actuation toggle OFF.
  EXPECT: the wait card shows the copy-command button (3.0 fallback), not Send."

step "4. Dispatch (scene BF)" \
"  - Workbench sidebar → 派活. Pick a repository, type a small task, Start.
  EXPECT: a NEW Terminal window opens, cd's into that root, claude starts with
  the task as its prompt. Within a minute the session appears as a row.
  - Quoting check: use a task containing a single quote, e.g. it's a test.
  EXPECT: claude receives the words verbatim; nothing else executes."

step "5. The kill switch" \
"  - Turn 「允许指挥台敲入终端」 OFF.
  EXPECT: Send buttons and the 派活 button disappear immediately."

echo
echo "All five held → 4.0-β verified on this machine."
echo "Anything failed → copy the step number and what happened instead."
