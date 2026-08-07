# 0.56 计划 —— Landing Precision / 精确落地

## 先说这份评估的局限

0.55 把「点一下能回去」做成了诚实分级（Warp / 宿主 / opt-in TTY / 托盘）。
剩余最大落差是：**多数路径只激活 App，却仍像「跳到那个会话」**。
本版把落地精度说清楚，并在可验证时把宿主落到工作区文件夹。

无 Apple Developer ID → Stable Gate 仍外部 blocked，本版不切 `stable`。

**诚实前提：**

- 不扩 Agent；不扩 hook 安装器越过 Claude / Codex。
- 不伪造 Waiting；托盘无 approve/deny；无额度 HUD。
- 不把 Finder「打开目录」冒充 Focus；宿主内打开工作区文件夹 ≠ Finder。
- 扫描期不枚举全机 `runningApplications`、不隐式弹 TCC。
- Builder 保持纯：路径存在性若影响广告，须可测的纯判定或 Context 注入。

---

## 逐项清单（验收时逐一比对）

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | 落地精度诚实：会话/工作区 vs 仅 App vs TTY 标签 vs 仅观测 | L10n + Support + 行动作；绝不把仅激活 App 写成「跳到该会话」 |
| P0-2 | 可验证时宿主工作区落地：`open -a Host.app <cwd>` | `FocusTier.hostWorkspace`；无绝对 cwd 则 `.hostApp`；点击失败回退 activate |
| P0-3 | Warp 诚实为 App 级 | 文案 / Support 标明 Warp (app)；不暗示标签精度 |
| P0-4 | EXPERIENCE / README / architecture / matrix / AGENTS 对齐 0.56 | 文档与代码一致；README 不再写「直接跳到那个终端页」而不分级 |

### P1 · 显著提升

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | Cursor / VS Code / Zed 深链 spike 结论入库 | `docs/landing-hosts.md`：工作区 `open -a` 可用；composer 级无稳定无 TCC 深链则标明 blocked |
| P1-2 | bestEffortCache 核心事实 / Limited 说明 | matrix 与 ObservationQuality 叙事一致；不假装会话级 |
| P1-3 | ingest LIMIT 与 retain 500 对齐 | `NativeActivityHarvest` SQL `LIMIT 500`（或与 retain 同常量） |
| P1-4 | Attention 可达：Settings 一键写样本 Waiting | 不扩安装器；复用 bridge 语义；可清除 |

### P2 · 收口

| ID | 项 | 验收 |
| --- | --- | --- |
| P2-1 | Stable Gate 插队说明 | CHANGELOG：无 Apple ID 不切 stable |
| P2-2 | 落地分级单测 | hostWorkspace / hostApp / Warp app-only / 文案 |
| P2-3 | 标题回归保留 | 0.54.2 / 0.55 标题单测仍绿 |

### 明确不做

额度 HUD、托盘 approve/deny、扩 Agent、扩 hooks、伪造 Waiting、假 stable、
SIGKILL helper、扫描期 Apple Events、Finder 打开目录冒充 Focus。

---

## 顺序

P0-2 `hostWorkspace` → P0-1/P0-3 文案 → P1-3 LIMIT → P1-4 Settings 样本 →
P1-1/P1-2 文档 → P0-4 全文档 → P2 → 0.56.0。
