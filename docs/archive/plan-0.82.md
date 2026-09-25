# 0.82 计划 —— Tray Fleet Substance / 舰队托盘实质

## 先说这份评估的局限

0.80 画出观测行，0.81 打通 Claude / Codex / Cursor。本版同章补丁：**非旗舰
session + bestEffortCache + quiet live phase**，让默认行在真实有字段时不空。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。

**诚实前提：**

- 不伪造 Waiting；不用 last tool 冒充 Now。
- 不升格 cache→session；不扩 hooks；不碰 composer 深链。

---

## 逐项清单

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | 共享 `fact(from:)` | `modelName` / `modelDetails`；`candidatesTokenCount`；`usageMetadata` / `response.usage`；`functionCall.name`；`hasDisplaySignal` 含 model |
| P0-2 | Phase 诚实 | `in_progress` / `depending` / `active` / `thinking` / `busy` → working；可读 Now |
| P0-3 | Cursor / Pi | Cursor `modelDetails.modelName`；Pi usage 尽量带 model |
| P0-4 | Cache 观测 | 有 model/tokens/files/context 的 Limited 行观测非空；证据仍 `.cache` |
| P0-5 | 场景 AB + 测试 | EXPERIENCE；Native + ResourceLookup |

### P1

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | Quiet live | 无 phase 时 Now 仍空；观测仍可有 model/tokens |
| P1-2 | EXPERIENCE 版本戳 | 对齐当前实现 |

### P2

假 stable 插队说明；八门禁对 0.82.0。

### 明确不做

假 Waiting、tool→Now、cache→session、扩 hooks、composer 深链、假 1.0。
