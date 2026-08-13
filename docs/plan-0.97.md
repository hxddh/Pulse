# 0.97 计划 —— Hero Honesty / 主行诚实

## 先说这份评估的局限

0.96.1 修好了 Pi 的会话标题。同构的撒谎还在旗舰路径上：**Claude / Command Code
把 `tool_result` 当用户目标；长笔录只看最后 256 行；Codex 不读 `event_msg` 用户
正文、不剥 Desktop 信封、`continue` 覆盖真目标。** 托盘表头按 12 行窗口计数；
Details 无 phase 时发明「等待权限」。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。
Composer 深链仍 Blocked —— 本版不挖。

**诚实前提：**

- 不伪造 Waiting；不扩 hooks；不升格 cache→session。
- 主行只陈述真实用户目标，不把工具回包 / 文件路径 / 传输信封当 hero。
- builder 保持纯；无额度 HUD；托盘无 approve/deny。

---

## 现状盘点（0.96.1）

| 主题 | 缺陷 | 0.97 动作 |
| --- | --- | --- |
| Claude / Command Code | `role=user` 的 tool_result 变标题；suffix(256) 丢开场目标 | 跳过工具信封；全文抽最新有意义用户提示 |
| Codex | `event_msg`/`user_message` 不进 task；Desktop 信封；continue 覆盖 | 抽正文、剥信封、meaningful 覆盖 |
| cwd | 通用 `path` 把 tool 文件当成工作区 | tool 形记录不用 `path` 当 cwd |
| Goose / Kimi | 忽略 `name` / `lastPrompt` / `workDir` | 补键（非 tool 记录） |
| 表头计数 | `headerStates` 数窗口行，不是舰队 | 用 `sectionTotals` |
| Details Phase | 空 phase + Waiting → 发明「等待权限」 | 用 waitKind；无证据不升格 Permission |
| harvest waitKind | 一律 `Input` | 审批类 tool/phase → `Permission` |

---

## 逐项清单

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | Claude 用户提示 | tool_result 不当标题；300 条工具尾仍保留开场目标 |
| P0-2 | Codex 用户提示 | `event_msg` user_message 进 task；剥 `## My request for Codex` / `<image>`；`continue` 不覆盖 |
| P0-3 | tool path ≠ cwd | Claude/通用 tool_use `path` 不是工作区 |
| P0-4 | Goose / Kimi 键 | `name` / `lastPrompt` 进标题；`workDir` 进 cwd |
| P0-5 | 表头计数 | 非搜索时 header 用 `sectionTotals`（15 running 不显示成 9） |
| P0-6 | Details 不发明权限 | 空 phase 的 Input 等待 ≠「等待权限」 |
| P0-7 | waitKind | `request_approval` / permission phase → Permission，其余 Input |
| P0-8 | 场景 AK + 测试 | EXPERIENCE **AK**；HeroHonesty 回归 |
| P0-9 | 交付物 | plan；CHANGELOG；semver；AGENTS/README；门禁；草稿 PR；**等「发布」** |

### P1

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | preferTask | 超长 tool dump 不得压过短真目标 |
| P1-2 | readablePhase | 非 Waiting 时 `permission` 子串不说「等待权限」 |

### 明确不做

假 Waiting、扩 hooks、composer 深链、cache→session、假 1.0、额度 HUD、托盘
approve/deny、Aider 根目录扩扫、Copilot yaml、Gemini `projects.json`、Look
coalesce、Windsurf 产品身份合并。
