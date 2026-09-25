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

## 12.2 已完成

- ε：会话形 runtime 协议（`startOrResume` / `send` / `resolveApproval` / `ManagedTurnEnd`），权限经
  runtime 送达；`AcceptanceRunner` + `EvidenceStanding`，过期判定移出视图（有界复测，未用 FSEvents）。

## 12.3 已完成（收齐）

原「留给 12.x」的四行全部在 12.3.0 一次完成：

| 阶段 | 完成内容 |
| --- | --- |
| γ Adapter 协议 | `TranscriptDialect` 协议 + 注册表；Codex / Pi / Claude / Gemini·Aider 各自成文件；跨扫描状态收进 `ScanMemory`，由 `Guarded` 一把锁持有（未改 actor，理由见 CHANGELOG） |
| δ Store 拆分 | `RowNarrator`（叙述离开 store，时钟注入）；`WaitingDelivery`（通知决定是值） |
| β 余下模块 | `PulseHarvest` / `PulseRespond` / `PulseManaged` 三个 target；`AgentCatalog`、`DebugLog` 进入 `PulseCore` |
| 严格并发 | 所有 App 侧 target 开启完整检查；警告数由 CI ratchet 只降不升 |

另：review-11.0 的 F-4（更新签名 / Team ID 校验）关闭；历史计划归档到 `docs/archive/`。

仍然不在 12.x 范围内的：Outcome（[`plan-outcome.md`](plan-outcome.md)），等真机 Codex 证据与
review-11.0 §4.3 的产品决定。

## 边界不动

AGENTS.md 的全部不变量；托盘与 Workbench 的用户可见行为；持久状态 schema。12.0 不改任何文案语义。
