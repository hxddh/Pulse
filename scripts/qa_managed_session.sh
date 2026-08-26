#!/bin/bash
# 5.0-β real-machine verification — one full managed-session chain.
#
# What CI already proves: the stream state machine, argv construction, NDJSON
# reassembly, worktree creation against a real repo, row mapping. What ONLY
# this pass proves: a real `claude` binary driven turn-by-turn over pipes on
# a real Mac, and process reaping.
#
# Needs: Pulse.app running, `claude` CLI logged in, a git repo the fleet has
# touched (so it appears in the dispatch picker).
set -u

step() { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$2"; read -r -p "  [enter when done / Ctrl-C to abort] "; }

echo "Pulse 5.0-β managed-session verification."

step "1. Dispatch (managed)" \
"  - Workbench (⌘⇧W) → 派活. Pick a repo, task: '在 README 末尾加一行 hello，然后停下'.
  - Keep 「在 Pulse 里运行（受管）」 and 「独立 worktree」 ON. Start.
  EXPECT: a new Pulse-run row appears within a second; its inspector shows the
  live conversation (your task as the first line, tool lines as they happen);
  cost/turns appear when the turn ends with 「回合已结束 —— 下一句是你的」."

step "2. The worktree boundary" \
"  - In the inspector: the path is under ~/Library/Application Support/Pulse/worktrees/.
  - Click the diff card's button.
  EXPECT: the README change shows in the worktree diff; \`git status\` in your own
  checkout shows NOTHING — your working copy never moved."

step "3. A real second turn" \
"  - Reply: '再把那行改成 hello world'. Send.
  EXPECT: the same session continues (session id unchanged in claude's own
  /resume list), the diff updates, cost accumulates across turns."

step "4. Cancel and reap" \
"  - Send a long task ('把每个文件读一遍并总结'), then press 终止本回合 mid-run.
  EXPECT: status 「回合已终止」 within ~2s; \`pgrep -f 'claude -p'\` finds nothing.
  - Start another turn, then Quit Pulse from the tray while it runs.
  EXPECT: \`pgrep -f 'claude -p'\` finds nothing after quit."

step "5. Honesty exits" \
"  - Temporarily rename the claude binary (or 'chmod -x'), dispatch again.
  EXPECT: the sheet says 本机未找到 claude CLI, nothing half-starts. Restore it.
  - Dispatch into a non-repo folder with worktree ON (pick via a fleet row in
    a plain directory, if any).
  EXPECT: 不是 git 仓库 message, nothing created."

echo
echo "All five held → 5.0-β verified on this machine."
echo "Anything failed → copy the step number and what happened instead."
