# 0.95 计划 —— Extinguish Honesty / 熄灭诚实

## 先说这份评估的局限

0.94 证明「真 ask 能亮」。现场与代码审计仍缺一环：**假 Waiting 会亮、清/软消后会复燃、
一权限涂红全家**。本版换章：熄灭诚实 —— 无证据不亮，有清除就灭，再亮必须是新证据。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。
Composer 深链仍 Blocked —— 本版不挖。

**诚实前提：**

- 不伪造 Waiting；不扩 hooks 安装器；不升格 cache→session。
- 不靠 transcript 自由文本猜 Waiting（删 Pi/Grok 子串推断）。
- builder 保持纯；无额度 HUD；托盘无 approve/deny。

---

## 现状盘点（0.94.0）

| 主题 | 缺陷 | 0.95 动作 |
| --- | --- | --- |
| OpenCode permission | 全局一旗涂红所有 session | 去掉全局 smear；只认 session tool pending |
| Cascade/Windsurf | 共享根双抬两行红 | 对齐 legacy：有 Cascade 则不发 Windsurf 壳 |
| Pi/Grok | 自由文本 permission/approval → pending | 删除文本推断 |
| 已答 ask | askResponse 不否决 ask-tool | 已答 / 终态否决 |
| merge pending | OR/prefer-nonempty 单调 | 按 activityMs last-wins |
| soft-dismiss | 重启丢失 tombstone | 持久化 dismissed-pending |
| dismissWaiting | 无 session 的 harvest dismiss → agent-wide done | 纯 harvest 不写 Attention done |
| 消失的行 | 缺席不清 tombstone | 可靠 scan 下缺席即 clear |
| harvest failed | 剥 pending → 假熄再亮 | 失败保留 last-good（含 pending） |
| Go-Look | 扩窗后立刻清 pending → 滚不到 | 两阶段：可见后再清 |
| Attention 前缀 | 短 session  smears | 唯一可解析才匹配 |
| stop grace | 漏 `Waiting` 种类 | 与 Permission/Input 同宽 |
| Clear waiting | 通知队列竞态 | 同步清空队列 + acknowledge |
| Waiting-none Reach | 常驻展开动作条 | 恢复 hover；次菜单保留 Reach |
| bool 旗 | firstValue 非决定性 | 全键 OR |

---

## 逐项清单

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | OpenCode 去 smear | 两 session / 一 permission 表更新 → 不全家红；tool pending 仍可 session 点亮 |
| P0-2 | Cascade/Windsurf 仲裁 | 全扫共享根只抬 Cascade；仅 Windsurf filter 仍可见 |
| P0-3 | 禁文本推断 | Pi/Grok 「permission」正文不抬 pending |
| P0-4 | 已答 / 终态否决 | askResponse / completed 压过 ask-tool |
| P0-5 | merge last-wins | 新非 pending 片段熄灭旧 pending |
| P0-6 | dismiss / clear 生命周期 | 持久 tombstone；缺席可再亮；纯 harvest 不 agent-wide done；clear 无迟到通知 |
| P0-7 | Go-Look / Attention 匹配 / stop grace | 可见后 reveal；唯一 session；Waiting+Stop 有 grace |
| P0-8 | 场景 AH + 测试 | EXPERIENCE **AH**；ExtinguishHonesty 回归 |
| P0-9 | 交付物 | plan；CHANGELOG；semver；AGENTS/README；门禁；草稿 PR；**等「发布」** |

### P1

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | EXPERIENCE 版本戳 | 对齐 0.95.0 |
| P1-2 | Codex Support | hooks 未装时仍认 harvest-pending 就绪 |
| P1-3 | L10n | Look Closure EN「moved」→「changed」 |
| P1-4 | AttentionWatcher | 监视 `AttentionIO.path` |

### P2

假 stable 插队；八门禁对 0.95.0。

### 明确不做

假 Waiting、扩 hooks、composer 深链、cache→session、假 1.0、额度 HUD、托盘 approve/deny、
Glance 标题宽度大章、Look Continuity 指纹世代大改（记入后续）。
