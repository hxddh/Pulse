# 0.62 计划 —— Attention Autonomy / 开放 Attention 协议

## 先说这份评估的局限

0.61 让 Claude/Codex Waiting 脱离 Python。本版换轴：把同一原生 `pulse-hook`
升成 **对外契约** —— Waiting-none 与名单外工具可按协议亮红灯，**不扩**
Claude/Codex hook 安装器。不碰 Stable Gate / composer 深链 / 1.0。

无 Apple Developer ID → Stable Gate 仍外部 blocked。

**诚实前提：**

- 不扩 Agent；不扩 hooks 越过 Claude / Codex。
- 不伪造 Waiting；托盘无 approve/deny；无额度 HUD。
- Waiting-none **永不**从 harvest 抬 pending；Attention 0.60 身份门闩保留。
- 未知 kind **拒绝写入**（soft-fail exit 0，不挡 agent）。

---

## 逐项清单（验收时逐一比对）

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | 协议冻结 | `AttentionProtocol` v1：header、六列、kind 白名单、session 身份文档 |
| P0-2 | 可交付 raise 包 | `raise.sh` + PROTOCOL；samples 冒烟优先 `pulse-hook` |
| P0-3 | 产品可发现 | Waiting-none nudge / Support / L10n 指向协议 raise |
| P0-4 | 硬门闩 | 未知 kind 不写；`.none` 不抬 harvest pending；不 smear 兄弟 |
| P0-5 | EXPERIENCE U + 文档 | 外接 raise → 红灯；architecture 去「hooks 靠 Python」 |

### P1 · 显著提升

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | Zero-deps 叙事 | seed/文档与「不需要 Python」一致 |
| P1-2 | Live stall 回归 | 停滞仍标无活动时长 |
| P1-3 | 0.60/0.61 回归 | Attention 身份、native install/self-test |

### P2 · 收口

| ID | 项 | 验收 |
| --- | --- | --- |
| P2-1 | Stable Gate 插队 | CHANGELOG：无 Apple ID 不切 stable |
| P2-2 | 能量预算 | 不加深 harvest walk |

### 明确不做

额度 HUD、托盘 approve/deny、扩 Agent、扩 hooks、伪造 Waiting、假 stable、
composer 深链、SIGKILL helper、扫描期 Apple Events。

---

## 顺序

P0-1 AttentionProtocol → P0-4 写入门闩 → P0-2 raise 包 → P0-3 文案 →
场景 U → 0.62.0。
