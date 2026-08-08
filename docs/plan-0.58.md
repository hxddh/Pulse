# 0.58 计划 —— Fleet Continuity / 舰队连续

## 先说这份评估的局限

0.55–0.57 完成了「回去 → 诚实落地 → 旗舰行有真事实」。0.57 的 Fact Continuity
主要硬化了 Claude / Codex / Cursor；**其余 Agent 仍可能薄 cache、假 session 证据、
子串假 Waiting、或 Waiting-none 不可达**。composer 深链仍见
[`docs/landing-hosts.md`](landing-hosts.md) Blocked。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。

**诚实前提：**

- 不扩 Agent；不扩 hook 安装器越过 Claude / Codex。
- 不伪造 Waiting；托盘无 approve/deny；无额度 HUD。
- 不承诺 composer/tab 深链；不把 Finder「打开目录」冒充 Focus。
- 扫描期不枚举全机 `runningApplications`、不隐式弹 TCC。
- Builder 保持纯。
- `bestEffortCache` **永不**升格为 session 证据。

---

## 逐项清单（验收时逐一比对）

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | 非旗舰 `structuredSession` 审计（Amp/Pi/Grok/Gemini/OpenCode/Goose/…） | merge / tool 后写 / 拒 chrome title；fixture 有 goal/cwd/tool |
| P0-2 | 高流量 cache 诚实 | `bestEffortCache` 行 evidence 恒为 `.cache`；薄 → Limited + Support depth「cache」；Windsurf/Cline fixture |
| P0-3 | 空壳禁令扩到舰队 | 无动态事实 → 无次行；无 Agent 名回退；EXPERIENCE 场景 O/Q |
| P0-4 | 文档指针对齐 0.58 | EXPERIENCE / architecture / AGENTS / README / plan |

### P1 · 显著提升

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | Waiting-none 六 Agent Attention 样本 | Settings 一键为 replit/devin/warpAgent/trae/antigravity/junie 写入/清除 |
| P1-2 | harvestPending 诚实 | token 级 pending；`depending` 等不得假 Waiting |
| P1-3 | 中档 goal/cwd/tool 回归单测 | Amp + cache thin→Limited |
| P1-4 | App Data 受限 nextStep | privacy_limited → `enable_app_data` 保持可点 |

### P2 · 收口

| ID | 项 | 验收 |
| --- | --- | --- |
| P2-1 | Stable Gate 插队说明 | CHANGELOG：无 Apple ID 不切 stable |
| P2-2 | Focus / Settings / 标题 / 0.57 回归 | 单测绿 |
| P2-3 | Support depth / 空壳 / subagent 回归保留 | 不回退 |

### 明确不做

额度 HUD、托盘 approve/deny、扩 Agent、扩 hooks、伪造 Waiting、假 stable、
composer 深链、SIGKILL helper、扫描期 Apple Events。

---

## 顺序

P0-2 evidence 门闩 → P1-2 pending 词表 → P0-1/P0-3  hardening → P1-1 Attention 六样本 →
测试与文档 → 0.58.0。
