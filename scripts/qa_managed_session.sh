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


# ---- 6.0 additions ----
step "6. Permission channel (scene BJ)" \
"  - Dispatch a task that needs an un-allow-listed tool (e.g. '运行 git push --dry-run').
  EXPECT: an orange 权限请求 card appears at the top of the inspector with the
  FULL tool input; the turn is visibly blocked on it. Deny → the agent reports
  the denial and continues; Allow → the tool runs. Ignore one for 2 minutes →
  auto-deny with 'timeout'."

step "7. Queue and restart (scenes BI)" \
"  - Dispatch 5 quick tasks at once. EXPECT: 3 run, 2 show 排队中; finishing
  one starts the next.
  - Quit Pulse while one turn runs; relaunch.
  EXPECT: all sessions return with full conversations; the one that was
  running says 回合被中断; replying to it resumes the same claude session."

step "8. Compare and check (scene BK)" \
"  - Dispatch one task with 并行尝试: 3. EXPECT: three rows, three worktrees,
  the compare card lists all tries with status and ±lines; 查看 switches.
  - In one try, set 运行检查 to your test command and run it.
  EXPECT: exit code and output tail appear verbatim; a failing command shows
  orange, nothing pretends."


# ---- 7.0 addition ----
step "9. Popup rebirth (scenes BL/BM)" \
"  - With a managed session mid-turn, open the tray (no Workbench).
  EXPECT: the row's hero line is the agent's LATEST WORDS while fresh, not the
  static task title; waiting rows still lead with the task.
  - Click the row's chevron.
  EXPECT: the row expands in place — demoted title, full last words, plan
  (≤4 + '… N'), cost/±lines chips only where measured (no zeros invented).
  - Trigger a permission ask (e.g. 'git push --dry-run') and answer it FROM
  THE POPUP's orange card. EXPECT: same Deny/Allow rules as the workbench
  (truncated input withdraws Allow); the turn unblocks on Allow.
  - Expand an idle managed session and reply from its box (10.0: the
  in-list box appears only for blocked/dead turns).
  EXPECT: a real turn starts; 终止本回合 works from the popup too.
  - Click 「在指挥台打开」. EXPECT: the workbench opens with THIS session
  selected.
  - Let a notification arrive for a waiting row and click it.
  EXPECT: the tray opens with that row selected AND already expanded."


# ---- 8.0 addition ----
step "10. Attention cabin (scenes BN/BO/BP)" \
"  - Dispatch a managed task that needs permission (e.g. 'git push --dry-run').
  EXPECT: the tray lamp goes RED; the row moves into 需要你 with a waiting
  chip; its message says the requested thing itself ('Bash: git push
  --dry-run'); a notification arrives with the same words; the orange
  permission card is visible IN THE LIST with no chevron click.
  - Answer it from the list. EXPECT: the row returns to running, lamp clears.
  - Let a managed turn end. EXPECT: no red lamp (your-turn is not
  alarmed); expanding the row shows the reply box and the last
  conversation moves (10.0 moved the idle box behind expansion).
  - Expand ANY observed session row (busy or sparse).
  EXPECT: the panorama's work line renders every measured work fact —
  last tool (with target when the hook recorded one), tokens
  (whole-session register), skill, model, context % — measured means
  rendered; no fact appears twice on the card; a fresh error still shows
  its own words in orange on the COLLAPSED row without expanding.
  - Expand any session. EXPECT: 'how it works' block — tool timeline
  (Read → Edit → Bash), workflow skill, model, session tokens, context %."


# ---- 10.0 addition ----
step "11. Composition (scenes BS/BT/BU)" \
"  - Open the tray over five mixed sessions and glance for 3 seconds.
  EXPECT: each collapsed row is exactly: tiny identity strip (name +
  relative time right-aligned) / hero / ONE grey meta line — no stacked
  grey walls; you can say who needs you, who is moving, who produced
  what, without reading.
  - Expand any row. EXPECT: the full panorama (narrative/motion/
  observation/work/where·when) plus plan, work detail and actions — no
  fact lost versus 9.0, each stated once.
  - An idle managed row shows NO reply box in the list; expanding shows
  it. A permission ask or a dead turn (interrupted/failed) still shows
  its card in the list without any click.
  EXPECT: the popup reads as one calm system."

echo
echo "All eleven held → 5.0-β + 6.0 + 7.0 + 8.0 + 10.0 verified on this machine."
echo "Anything failed → copy the step number and what happened instead."
