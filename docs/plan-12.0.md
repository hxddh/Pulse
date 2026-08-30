# 12.0 — Outcome / 结果契约（从管理会话到交付可验证候选）

## 判词：11.0 的天花板不在界面

11.0 已把「拥有会话」这条轴做到完整：Pulse 能在隔离 worktree 中派活，监督持久
会话与队列，处理权限，同题并行，展示完整对话与 diff，并在用户点击后运行检查、提交、
推送和打开 PR。7.0–11.0 又把这些能力带回托盘并收成一套视觉与信息系统。

但用户仍在做最后一段人工编排：把同一个目标复制成几场会话，逐场打开，记住各自跑过
什么检查，再凭印象比较。原因不是少一张卡，而是当前数据模型只拥有
**session + prompt**：

- 同题尝试是同一个 Claude runtime 的 N 份会话，不是不同 runtime 的候选；
- 检查命令会持久化，退出码与输出只活在当前 SwiftUI view state；
- 检查没有绑定执行时的代码身份，代码再变后旧绿灯无法判定是否仍有效；
- `claudeSessionID`、argv、stream decoder 与 permission 参数都长在通用 session / runner
  里，而 Codex 的公开嵌入边界是长寿双向 App Server；第二个 runtime 会逼出复制粘贴或
  大量条件分支；
- 比较面只列状态与 `+x −y`，没有同一把验收尺下的证据。

继续加采集字段、卡片或更快刷新，只会把会话控制台做得更好，不会改变用户与产品的关系。

## 唯一一件事

**用户声明结果与怎样算完成；Pulse 在隔离环境中组织候选、执行同一份用户定义的验收，
并把可比较的证据交还给用户选择。**

产品动词由「派出并管理会话」变成「交付可验证候选」。这不是自动判断：检查通过是
可观测事实，哪个候选最好仍是用户判断。

## 结果契约

### Mission（用户要的结果）

一项 Mission 是持久实体，不是 dispatch sheet 的临时输入：

- `id`、标题、完整目标；
- 仓库根与创建时间；
- 用户写下的约束（可空，不由 Pulse 发明）；
- 有序的验收检查（可空；空就是「未定义机械验收」，绝不降格成已验证）；
- 由它产生的 Candidate ids；
- 生命周期：`draft / running / ready / archived`。`ready` 只表示候选都不再运行，
  **不表示任务正确或完成**。

目标、约束与检查在第一位 Candidate 开始后冻结为该轮的 contract revision。用户修改时
产生新 revision；旧 Candidate 保留自己的 revision，不把新尺子倒套到旧结果上。

### Candidate（一次隔离实现）

Candidate 取代今天只有 `attemptGroup` 的隐式分组：

- `missionID` + contract revision；
- `runtimeID` + runtime 自己的不透明 continuation identity；
- 独立 worktree / branch；
- 会话状态、完整 transcript、第一手结果与未知事件计数；
- diff / worktree effect；
- 一组持久 `AcceptanceEvidence`；
- 用户明确选择与否。未选择不是落败，Pulse 不排名。

### AcceptanceEvidence（代码在某一刻通过了什么）

每次检查记录：

- 原始命令、开始与结束时间；
- exit code、timeout、bounded stdout/stderr；
- 执行目录；
- 执行前代码指纹；
- `passed / failed / timedOut / couldNotRun`。

代码指纹取该 worktree 的 `HEAD`、staged/unstaged diff，以及非 ignored untracked 文件的
路径与内容做流式摘要；检查后再次测量。任何内容无法读取或超出明确预算时，指纹就是
unknown，不能显示通过。前后不同则本次证据标 `invalidatedDuringRun`。之后 Candidate 的
代码指纹再变化，已有证据显示**已过期**，不静默保留绿色。

只有 exit code 0 且未 timeout、未在运行中变化、当前指纹仍匹配时，才可说「通过」。
Pulse 只说每条检查的事实，不合成质量分，不把「全部检查通过」写成「实现正确」。

## 12.0-α · Runtime 接缝（先保行为，再开第二实现）

α 的第一轮公开协议取证见 [`evidence-12.0-codex.md`](evidence-12.0-codex.md)：Codex
`exec --json` 有结构化输出与 resume，但没有可供父进程回答的审批协议；满足 Pulse 安全
纪律的边界是 App Server stable v2 over stdio。真机 fixture 门仍未完成。

这个证据也否定了只抽 `executable + argv + consume(line)`：Claude 是每回合一个 child，
Codex 是 Candidate 期间一个长寿双向 child。共同边界必须是 runtime session 的用户语义，
每家独占进程拓扑与 wire 形状：

```swift
protocol ManagedRuntime {
    var id: ManagedRuntimeID { get }
    func executable() -> URL?
    func makeSession(context: ManagedRuntimeContext) -> ManagedRuntimeSession
}

protocol ManagedRuntimeSession {
    func startOrResume(continuation: String?) async throws
    func send(prompt: String) async throws
    func cancel() async
    func resolveApproval(id: String, decision: ManagedApprovalDecision) async
    func shutdown() async
}
```

名字可在实现时按 Swift 边界调整，但职责不能漂：

- executable discovery 与版本能力；
- child/App Server 生命周期、argv 与 prompt/resume 传递；
- continuation identity 的校验与提取；
- stream event → 通用 transcript / usage / result；
- 双向 permission request / verdict adapter；
- 厂商错误与 unknown event 计数。

`ManagedSessionRunner` 只管通用 turn 状态与主线程交付；具体进程、pipe/RPC 与取消方式归
runtime session。`ManagedFleet` 继续只管队列、跨 runtime 合计并发与持久化；worktree 和
用户点击触发的 landing 不属于 runtime。

边界确定后先抽出 `ClaudeManagedRuntime`，旧 fixture 与行为逐项透传，再接第二 runtime。
此阶段不增加其他产品能力，禁止一边重构一边改状态语义。状态文件升级为有 schema
version 的 DTO：

- 老 `claudeSessionID` 迁成 `runtimeID=claude` + opaque continuation；
- 文件名 / body id 一致门、0600 和有界写盘不变；
- 读不懂的新 schema 拒绝加载并留下诊断，不猜；
- 迁移测试使用真实旧版 fixture，钉住 transcript、状态、队列与 resume identity 不丢。

### 第二 runtime 的 P0 证据门

Codex 的公开协议能力已经成立，但当前 Linux orb 没有 Codex binary，仍不能把文档当执行
证据。写 product adapter 前必须在真实 macOS + 当期正式 CLI 上保存脱敏 fixture，证明：

1. 有稳定、可有界解析的结构化输出；
2. 能取得并安全续接会话身份，或明确声明不支持续回合；
3. cancel / clean exit / failure 可以区分；
4. App Server command request 有完整 command/cwd；file request 能与先到的完整 diff item
   可靠关联；network request 有自己的完整目标形状；
5. 实际改文件、工具失败、最终回答与 token（若厂商提供）的形状均有样本；
6. CLI 不存在或版本不兼容时能诚实拒绝，而不是退成半受管会话。

Codex v1 只用 stable v2 stdio，`experimentalApi=false`；不接 WebSocket、MCP elicitation、
dynamic tools、account 或配置写 API。只回单次 accept/decline/cancel，永不回
`acceptForSession` 或 policy amendment。某项没有证据就标 unsupported；若完整请求不可得，
该请求没有 Allow。不能为了凑「双 runtime」放宽安全或诚实规则。

## 12.0-β · Mission 与持久验收（质变本体）

- Dispatch 从「task + attempts」升级为 Mission composer：目标、约束、检查、runtime /
  candidate 选择。默认仍应轻：只有目标是必填；高级字段渐进披露。
- `ManagedFleet` 监督 Candidate，Mission 只聚合归属与 contract；不另建一套进程系统。
- 当前 inspector 的 run-check 搬到独立 acceptance runner；运行、超时、输出 bounding 不再
  属于 SwiftUI，view 只渲染持久状态。
- 检查按 Mission 中的用户顺序执行；默认串行，首个失败后**仍继续**，这样比较面得到同一
  把尺子的完整事实。用户可取消尚未开始的检查。
- Agent 无权修改 Mission contract。它可以建议检查，但建议只是 transcript 文本，除非用户
  明确编辑 Mission 并产生新 revision，否则不进入验收。
- 重启时正在运行的检查回到 `interrupted` / `couldNotRun`，绝不根据残留输出补判成功；
  用户可重新运行。
- 旧 11.x 同一 `attemptGroup` 的 sessions 迁入同一个 legacy Mission；standalone session
  各自成为单 Candidate Mission。旧 `runCommand` 可迁为一条尚未运行的检查，
  **不能制造 Evidence**。

## 12.0-γ · Evidence Compare（把判断所需事实放在一起）

Mission 详情以候选为列、事实为行，默认只展示会改变选择的内容：

1. runtime / 模型与会话状态；
2. 每条验收的通过、失败、过期、未运行；
3. diff 文件数与 `+x −y`；
4. 最终回答、失败与 unknown events；
5. 进入完整 diff / transcript 的动作。

禁止总分、星级、自动推荐色和「最佳」徽章。可以排序的只有用户明选顺序、创建顺序与
机械状态（仍在跑 / 已停止），不能按 Pulse 发明的质量函数排序。

选择 Candidate 是显式用户动作。选择只改变 UI 归属，不写 git；commit、push、打开 PR
继续各自需要用户点击。12.0 不做 merge。

托盘不变成 Mission 看板：Glance 仍回答「要不要抬头」，Tray 仍以 Waiting 优先。Mission
进度与比较属于 Workbench；托盘最多把受管行归到 Mission 名下，不增加历史统计或常驻 HUD。

## 判断边界（发布阻断项）

以下任一出现都算方向失败，即使功能可用：

- Pulse 宣称、暗示或视觉推荐某 Candidate「最好」；
- 自动选择、自动 commit、自动 push、自动开 PR 或自动 merge；
- 检查通过后自动批准权限或触发新的高风险动作；
- Agent 能静默修改自己的验收标准；
- 未运行、过期、运行中代码变化或无法读取的检查显示成通过；
- 用模型互评替代用户定义检查；
- 对不完整 permission request 提供 Allow；
- 为多 runtime 复制 Fleet、worktree、acceptance 或 persistence 管线；
- 把 Mission 变成统计大盘、token/cost 排行或历史绩效系统。

机械重试不在 12.0：即使检查失败，也由用户决定回复 Candidate、重新运行检查或放弃。
先把证据闭环做可信，再评估下一版是否需要用户明确配置的重试策略。

## 证明墙

### 纯测试

- Runtime contract：Claude 旧 fixture 逐事件等价；第二 runtime 每种已承诺事件有 fixture；
  unknown event 不吞、不崩。
- Migration：11.x state → legacy Mission/Candidate；重复迁移幂等；坏 id/schema 拒绝。
- Mission revision：执行后修改 contract 生成新 revision，旧证据不串线。
- Evidence state table：exit / timeout / spawn failure / interrupted / during-run mutation / stale
  全组合。
- Isolation：一个 runtime decoder、进程或检查失败不影响其他 Candidate。
- Queue：并发上限仍对所有 runtime 合计生效，不是每家各三个。
- Security：0600、命名空间门、完整请求旁才有 Allow、输出与 transcript bounding。
- UI：无检查不显示已验证；过期不是通过；没有推荐 / 排名；完整 diff 才能进入 landing。

### 真机 P0

发布前在真实 macOS 完成并留脱敏证据：

1. Claude 与第二 runtime 对同一 Mission 各建一个独立 worktree；
2. 两者都完成真实文件修改、一次工具失败与最终回答；
3. 同一组至少两条检查在两边运行，制造一边通过、一边失败；
4. 检查后再改文件，旧通过立即变过期；
5. 退出 Pulse / 重开，Mission、Candidate、证据与过期状态不丢；
6. 两边各走一次权限 Allow、Deny、timeout（只对具备完整请求能力者要求 Allow）；
7. 用户选择其一，显式 commit、push、打开 compare/PR；另一边零 git 写动作；
8. CLI 缺失与版本不兼容路径各验证一次，失败可见且不阻塞另一 runtime。

第二 runtime 未过 P0 就不发布 12.0；不能用两个 Claude 尝试冒充跨 runtime 结果契约。

## 明确不做

| 项 | 理由 |
| --- | --- |
| 只加 runtime 下拉框 | 兼容性增量，不是结果闭环 |
| 自动选优 / LLM judge | 判断权转移，且不可证 |
| 自动修到测试通过 | 把机械事实升级成自主策略；12.0 先交付可信证据 |
| 自动 merge | 不是结果契约成立的必要条件，风险远大于价值 |
| 云端队列 / 账号 / 同步 | 破坏 local-only 边界，引入另一整套信任产品 |
| Kanban / 趋势 / 绩效统计 | Workbench 不是管理大盘，EXPERIENCE 明确禁止 |
| 扩张 hook installer | 仍只限 Claude / Codex，其他 Waiting 走 Attention bridge |
| 顺带重写 observed adapters | 观察引擎不是这条轴；只动 runtime 与 Mission 必需接缝 |

## 发布定义

12.0 只有在以下一句话能被真实机器逐字证明时才成立：

> 给 Pulse 一个结果和验收方式，它让不同编码 Agent 在隔离环境中产出候选，并把
> 同一把尺下的可验证差异交给你决定。

少第二 runtime，是 11.x 的持久验收增强；少持久 Evidence，是 provider picker；自动替用户
选，是越界。三者任一发生都不应取 12.0 这个版本号。
