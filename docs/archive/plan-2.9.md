# 2.9 — Quality / 质量（秒级 · 自证 · 平权）

## 为什么是这条轴

2.8 之后行上已经有「干到第几步、顺利吗」，但观测**质量**有四个真实短板
（按伤害排）：

1. **时效是分钟级的，而 Pulse 本可以站在秒级的位置上。** 自己的 hook 已经在
   Claude 的事件流里（Stop / Notification / PermissionRequest），却对活动事件
   视而不见 —— 所有「正在干什么」都靠轮询磁盘：扫描节拍 + 省电退避 + mtime 门 +
   读窗口。等待是推送的，干活是轮询的。
2. **质量不自证。** 深度只有两档声明（structured / bestEffortCache），声明不等于
   产出。厂商改格式，解析静默退化成「标题 + 路径」，没有信号说「是观测坏了」。
3. **深度不平权。** 2.8 的计划/刚说的话/错误原文只扫 Claude 家族 + Codex 的
   路径 —— 其实是倒序扫描器被路径白名单拦住了，别家的会话记录里若有同形结构
   也读不到。
4. **读窗口截断**：头尾窗口之外要等 digest 追平（本版不动，记录在案）。

## P0 内容

### P0-事件：活动事件（时效分钟 → 秒）

- 安装器给 Claude 增加 `PreToolUse`（kind `activity`）与 `UserPromptSubmit`
  （kind `prompt`）两个 hook 注册，超时同现有 5s。**Codex 本版不参与**：
  它的 notify 机制只在回合边界与审批时刻发事件，没有逐工具事件可订 ——
  Codex 的「正在干什么」继续走轮询，如实分级，不硬造。
- receiver（原生 + python 对照物同步实现）对这两个 kind **不写 attention** ——
  它们不是等待；写 `activity.d/<agent>-<session>.json`（每会话一个状态文件，
  每事件覆写；0600；tool/target 走既有 toolDescriptor + 消毒 + 截断；目录
  机会式清理：>64 个删最旧，>24h 删除）。
- `PrivateFile` 的原子写（临时文件 + rename）天然触发目录 DispatchSource ——
  `AttentionWatcher` 加第三个 source 盯 `activity.d`，与现有节流合并；唤醒走
  **轻量刷新**：只读 spool、只更新匹配行的 live 字段，不做全量 harvest（能耗
  是硬约束）。
- 行获得 `liveTool` / `liveTarget` / `liveAtMs` / `livePhase`（tool|prompt）；
  叙事在事件新鲜（≤120s）时说**现在时**：「正在 Edit · main.swift」，过期即
  回落到既有轮询叙事 —— 现在时只许对秒级证据说。
- 规矩：事件仍是自述；轮询仍是兜底；**永不由活动事件推断 Waiting**；文件名
  决定身份，正文不符拒收（respond spool 老规矩）；未知 agent 跳过。

### P0-自证：产出率（测量测量自己）

- 每 agent 每拍聚合「事实类产出」：task / tool / tokens / progress / plan /
  word / error 各类是否在本拍任何行上出现，连同 filesRead / rowCount 进
  `CollectorHealth`。
- Support Health 显示**声明 vs 实测**：声明 structured 而本拍有行却核心三类
  （task/tool/tokens）全空 → 点名「结构化适配器零产出 —— 厂商格式可能已漂移」。
  厚薄从此有解释：「agent 没干活」和「Pulse 没看清」不再穿同一件衣服。
- 全部本机计算，不出机器。

### P0-平权：自述扫描器摘掉路径白名单

- 2.8 的倒序自述扫描（todos / lastWord / lastErrorText）从
  `usesTranscriptUserPrompt` 白名单放开到**所有 structured JSONL 会话记录**：
  谁的记录里有同形结构（`"todos"` 数组、assistant 文本块、`is_error` 结果）
  就读出来，没有就如实缺席 —— 引擎共享、形状严格匹配、不猜。
- 支持矩阵的意义由 P0-自证升级：从「声明一致」到「声明 = 实测」。

## 决定：S1 仍然 park，而且现在能说清为什么

评估时想把 S1（声明式适配契约）作为平权的载体。实现前的诚实结论：把
Claude/Codex 这两份最久经沙场的解析器改写成声明式，是全仓回归风险最高的一步，
且契约「符合与否」在产出率可测**之前**根本无法验收。所以本版先交付可测
（P0-自证）与可达（P0-平权的引擎共享），S1 等产出率跑过真机之后再付 ——
届时它是在还一笔能验收的债，而不是一次盲改写。

## 明确不做

- 不做离机遥测（产出率本机算、本机看）。
- 不碰屏幕 / AXAPI，不 hook 厂商二进制 —— 只用文档化的 hook / notify 机制。
- 不从活动事件发明 Waiting；不把事件当判决通道。
- `PostToolUse` 不注册 —— 每次工具调用两次进程唤起换一个 outcome 字段，
  能耗账不划算；错误原文继续走会话记录扫描。
- 读窗口/digest 追平机制本版不动。

## 前置不变

- P0-0（用户跑 `scripts/qa_respond_evidence.sh`，约 10 分钟）仍挂起，
  仍卡着厂商侧判决通道（verdict fate ③、富判决）的一切工作。
