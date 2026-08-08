# 0.59 计划 —— Cache Continuity / 缓存连续

## 先说这份评估的局限

0.58 Fleet Continuity 止住了「假 session」：`bestEffortCache` 恒输出 `.cache`。
本版缺口是 **Limited 诚实但仍常空** —— 高流量 cache 里已有 goal/cwd/tool/mtime
却未抽出，或 Support 把富索引与薄索引说成同一种「Limited」。

composer 深链仍见 [`docs/landing-hosts.md`](landing-hosts.md) Blocked。
无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。

**诚实前提：**

- 不扩 Agent；不扩 hook 安装器越过 Claude / Codex。
- 不伪造 Waiting；托盘无 approve/deny；无额度 HUD。
- `bestEffortCache` **永不**升格为 `.session` 证据。
- 只抽取字段里已有的事实，不发明 goal。
- 扫描期不枚举全机 `runningApplications`、不隐式弹 TCC。
- Builder 保持纯。

---

## 逐项清单（验收时逐一比对）

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | 高流量 cache 抽真实字段 | cwd 认 `workspace`/`path`；JSON `updatedAt`→activityMs；chrome title 不压用户 prompt；扩展 Cline/Roo/Cascade/Warp/Zed/Amazon Q 根 |
| P0-2 | 富 Limited vs 薄索引 | Windsurf/Cline/Roo fixture：富 → medium + Support「cache facts」；薄 → low +「thin cache」；证据仍 `.cache` |
| P0-3 | 证据门闩 + Waiting-none | `bestEffortCache` 永不 `.session`；`waitingSource.none` 不从 harvest 抬 `skill=pending`（Warp） |
| P0-4 | 文档 / 场景 R | attention-bridge 六样本；AGENTS→0.59；EXPERIENCE 场景 R |

### P1 · 显著提升

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | ObservationQuality / Support 三分 | 薄 / privacy / 富-cache-Limited 可区分 |
| P1-2 | pending 词表回归 | `depending` 仍否；`awaiting_user` / ask tokens 仍是 |
| P1-3 | 中档 session 抽检 | Pi 或 Goose fixture goal/cwd |
| P1-4 | Attention 文档 + Support 深链 | bridge 文案对齐；repair 仍指向 Attention |

### P2 · 收口

| ID | 项 | 验收 |
| --- | --- | --- |
| P2-1 | Stable Gate 插队 | CHANGELOG：无 Apple ID 不切 stable |
| P2-2 | Focus / Settings / 0.58 回归 | 单测绿 |
| P2-3 | 能量预算 | 不加深无界 walk；根扩展仍 bounded |

### 明确不做

额度 HUD、托盘 approve/deny、扩 Agent、扩 hooks、伪造 Waiting、假 stable、
composer 深链、SIGKILL helper、扫描期 Apple Events、把 Limited 文案写成 session。

---

## 顺序

P0-1 抽取键 / 根 / merge → P0-3 Waiting-none pending 门闩 → P0-2 Support 富/薄 →
测试 → 文档 → 0.59.0。
