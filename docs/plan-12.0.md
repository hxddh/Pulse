# 12.0 — Kernel / 内核

> 评估与动机见 [`review-11.0.md`](review-11.0.md) §4.2。本文件记录 12.0 实际交付了什么、用什么证明，
> 以及哪些阶段留给 12.x。原 plan-12.0（Outcome）已改名为 [`plan-outcome.md`](plan-outcome.md)，不编号。

## 唯一一件事

把 Pulse 从一个 33.8k 行、单 target、靠约定维持边界的 App，变成**一个有类型边界的内核 + 两个表面**。
用户可见的质变不是一张新卡，而是三句由测试或编译器证明的话。

## 发布定义（三句话）

| 句子 | 实现 | 证明 |
| --- | --- | --- |
| **加一个 agent 只动一个 Swift 文件** | `AgentCatalog.swift`：`AgentID` + 每个 agent 一条 `AgentSpec`（显示名、单字母标记、Waiting / 采集等级、App 数据授权、transcript 策略、Respond 可达性、别名、进程规则、采集根目录与命令）。ProcessProbe、NativeActivityHarvest、ActivityHarvest、AgentIcon、Respond 只读它 | `AgentCatalogTests`；`scripts/agent_catalog_check.py`（别处的 `case` 行一次最多点名 6 个 agent、一个文件最多 8 个，否则 CI 失败）；coverage / matrix / icons 三个 gate 从目录推导名单，不再手抄 |
| **一次扫描不重绘设置** | `StoreObservation`：设置窗口不直接观察 `StatusStore`；扫描落地期间（`isApplyingScan`）的变更最多每 30 秒转发一次 | `StoreObservationTests`：5 次扫描转发 0 次，改一个设置转发 1 次 |
| **看到的请求就是签名的请求** | `respondAllow(_:shown:)` 的 `shown` 不可省；与当前挂在行上的请求 id + digest 不一致即拒绝（11.0.4 H-1，12.0 保留为类型上的必填参数） | `StatusStoreRespondTests` 五条 |

## 结构

- **`PulseCore` 库 target**：`AcceptanceEvidence`、`PrivateFile` / `SafeRead`、`ProcessIO`、
  `ContentSanitizer`、`TranscriptReader`、`SessionDigest`、`AttentionProtocol`、`ProbeSchedule`、
  `ProbeStats`。只 import Foundation（+ CryptoKit / CoreGraphics），开启严格并发检查。App 经
  `PulseCoreExports.swift` 的 `@_exported import` 使用它；依赖方向由编译器保证。
- **Builder 纯度**：`SnapshotBuilder` 不再经 `AgentRow.lastActivitySeconds` 读墙钟，改用
  `lastActivitySeconds(at: context.nowMs)`。
- **一份 gate 清单**：`scripts/gates.sh`，CI、release.yml、`release.sh`、`package.sh` 共用。
- **CI**：同一分支 push + PR 只保留最新一次（`concurrency`），缓存 `.build`。

## 12.1 已完成

- γ 的数据部分：`HarvestWalk` 把 SQLite 读取器、transcript 选择、读窗口、时限等按 agent 的走法
  搬进目录；`NativeActivityHarvest` 按职责拆成四个文件。
- 严格并发：`PulseCore` 零警告并开启 warnings-as-errors。
- review-1.2 F-2：远端时钟按文件校正。
- ε 的一部分：检查可取消、退出时收割。

## 留给 12.x（按 review §4.2 的阶段）

| 阶段 | 未做部分 | 前提 |
| --- | --- | --- |
| γ Adapter 协议 | 厂商解析（Codex / Pi / Cursor…）各自成文件并以协议分派；扫描引擎改 actor | fixture 墙逐家对比 hero 值 |
| δ Store 拆分 | 除设置外的 `WaitingDelivery` / `RowPresenter`；Narration 离开 store | 性能墙扩展到托盘与 Workbench |
| β 余下模块 | `PulseHarvest` / `PulseRespond` / `PulseManaged` target | γ、δ 先完成 |
| ε Managed 地基 | 会话形 runtime 协议、独立 AcceptanceRunner、过期判定移出视图（FSEvents） | Outcome 开工之前 |
| 严格并发 | 推广到 App target | 先拆出更多 target |

## 边界不动

AGENTS.md 的全部不变量；托盘与 Workbench 的用户可见行为；持久状态 schema。12.0 不改任何文案语义。
