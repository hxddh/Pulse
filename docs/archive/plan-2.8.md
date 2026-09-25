# 2.8 — Progress / 进展（从状态到进展）

## 为什么是这条轴

到 2.7 为止，行上的一切事实都在回答「它是什么状态」：灯色、CPU、会话记录增长速率、
token、错误计数、盘上 +142 −38。这些花了五个版本做到诚实，但全是**元数据**。
一个人打开弹窗真正想问的是：**它干到第几步了？顺利吗？要不要我管？** 目前只有
Waiting 回答了第三问，前两问一片空白。

更关键的发现：**最有价值的信号正在被当噪音扔掉。** 会话记录里躺着结构化的进展数据 ——
Claude Code 每次更新待办清单，整份清单（每项内容、状态、当前项）都写进会话记录；
Codex 的 `update_plan` 同理；agent 自己刚说的话在最后几行里；最近一次报错的原文
就在 `is_error` 的 tool_result 里。而 `NativeActivityHarvest` 现在**主动过滤**
这些结构（它们当年污染过主行标题，被整类踢出去，连同里面的进度一起 —— 见
`parseCodexFacts` 里 "Never promote tool-call argument titles into task" 那段）。

## P0 内容

### P0-A 计划/待办成为一等事实

- Claude 家族会话记录（`/.claude/`、`/.commandcode/` 等走 `usesTranscriptUserPrompt`
  的路径）：倒序扫窗口，找**最后一条** `TodoWrite` 的 `input.todos` —— 每项
  `{content, status, activeForm}`。
- Codex rollout：`response_item` / `function_call` / `name == "update_plan"`，
  `arguments`（JSON 字符串）里的 `plan: [{step, status}]`。循环本身是正序，
  后写覆盖先写 —— 天然「最新为准」。
- 产出四个事实：
  - `progressDone` / `progressTotal` —— 喂进**已存在**的进度事实（行上
    `3/7` 芯片、Details 的 Progress、activityChange 的 progress 档全部
    直接点亮，零新显示面）。
  - `planStep` —— 当前项文本（`activeForm` 优先，退回 in_progress 项的
    `content`；全部完成则为空 —— 没有「当前」就不发明一个）。
  - `planSteps` —— 整份清单（capped 8 项、每项 100 字符、逐项过 sanitizer），
    只进 Details。
- 哪家会话记录里没有这个结构，事实就如实缺席 —— 不猜（0 与空串，不是估算）。

### P0-B 它刚说的话 · 最近的错误

- `lastWord`：最新一条 assistant 消息的文本首行（Claude 家族倒序扫；Codex 的
  `event_msg.agent_message`）。消毒、截 160。
- `lastErrorText`：最近一条 `is_error: true` 的 tool_result 首行（Codex:
  `event_msg.error`）。有错误计数没有错误内容，等于告诉用户「出事了，猜去吧」。

### P0-C 展示与规矩

- 行叙事（story）第一位：`当前步骤：X` —— 位于故障/循环之后（isLooping 与
  waiting 的既有分支不动），排在 phase 之前。**新鲜门槛与 phase 相同**
  （lastActivitySeconds ≤ 30 分钟）：过期的步骤是陈旧冒充此刻。
- Details：Step 行、清单卡（✓ / ▸ / ·）、Last word 行、Last error 行。
- **这些全是自述**（agent 自己写的），与 task/tool/model 同一认识论层级，
  规矩也相同：过 sanitizer、过期即撤、**永远不从中推断 Waiting**。
- Fleet 快照搭车：`Row` 增加可选字段 `step` / `step_done` / `step_total`
  （Optional → `decodeIfPresent`，2.7 的旧文件照常解码；旧读者忽略未知键）。
  远端行 fresh 时得到当前步骤，lost contact 时随其他实质一起撤下 ——
  快照实质门控已有，步骤字段进同一个门。

## 明确不做

- 不解析测试输出/构建结果（内容重、厂商专属、易猜错）。
- 不把 lastWord 提升为行标题 —— 主行仍是用户的目标（AK 的规矩）。
- 不给 planSteps 上 Fleet（快照只运当前步骤一句话 + 计数；整份清单是内容，
  留在本机）。
- 不新增每拍读取量 —— 全部事实来自既有窗口文本的倒序重扫，扫描预算不变。

## 前置不变

- P0-0（用户跑 `scripts/qa_respond_evidence.sh`，约 10 分钟）仍然挂起，
  仍然卡着厂商侧 2.9+ 的判决通道工作。
- S1 声明式 adapter 契约继续 park；S2 余项见 plan-2.5.md。
