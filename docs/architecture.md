# 架构

数据从「机器上有个进程」走到「菜单栏亮红灯」的完整路径。

```
  ┌─ ProcessProbe ──┐   ps -axo，进程 → AgentID，解析 TTY、Warp 与宿主 IDE 父进程
  │                 │
  ├─ ActivityHarvest┤   Swift 原生 bounded reader；可选 legacy activity_scan.py → named JSON schema 2
  │                 │
  └─ AttentionReader┘   读 attention.tsv（hooks 写的）
           │
           ▼
    SnapshotBuilder        纯函数：合并、去重、排序、编码状态、算边沿
           │
           ▼
      StatusStore          定时器、通知策略、设置、I/O
           │
           ▼
   MenuBarLabel / TrayPanel / SettingsView
```

## 三个来源

### ProcessProbe（便宜，常跑）

一次 `ps -axo pid=,ppid=,tty=,args=`，按规则表把命令行匹配到 `AgentID`。
每条规则有 basename、路径特征串和排除串——排除串是必需的，
`amp` 要躲开系统的 `AMPLibraryAgent`，`pi` 要躲开 `pip`。

顺着 ppid 链向上找，回答三件事：真实 TTY 是什么（进程自己常是 `??`），
是不是跑在 Warp 里，以及父进程是否是 Cursor / VS Code / Windsurf / Zed / Trae /
Antigravity。Focus 精度：Warp / 宿主仅 App、有绝对 cwd 时宿主工作区
（`open -a Host.app <cwd>`）、opt-in 后的终端标签。扫描期只用 `ps`，
不枚举 `NSRunningApplication`；activate / open 发生在用户点击之后。
详见 [`docs/landing-hosts.md`](landing-hosts.md)。

`signature()` 给出这一轮的进程指纹。指纹没变，说明会话数据大概率也没变，
昂贵的 harvest 就能跳过。

### ActivityHarvest（昂贵，按需）

`NativeActivityHarvest` 用 Foundation 读取各 Agent 自己的本地文件——Claude 的
`~/.claude/projects/*/*.jsonl`、Codex 的 rollout、Cursor 的 session/cache、OpenCode 的
JSON……每个 Agent 一个 bounded adapter，直接生成 Swift `Row` 和 `CollectorHealth`。
不稳定的 SQLite/私有 schema 只标为 cache，不猜成结构化会话。

旧版 `src/activity_scan.py` 仍随源码保留，只有设置
`PULSE_LEGACY_PYTHON_HARVEST=1` 时才作为显式兼容诊断路径；没有 Python 时 native harvest
仍完整运行，应用启动、自检和正常刷新都不依赖它。

两条硬约束，都是踩过坑之后加的：

- **逐 agent 隔离**。native reader 对每个 Agent 单独计时、限制深度/文件/行数；损坏文件只影响
  自身，其余 30 个用户可见 Agent 仍返回健康结果。
- **边跑边读**。native reader 不启动外部解释器；显式 legacy 模式仍由 Swift 独立线程排空
  stdout/stderr，并对每个 collector 设置 1.2–2.0 秒硬上限。超时保留已完成的 JSON 行，
  未到达的 adapter 继续沿用上一份有效事实，并在健康度窗口标为扫描未完成。

  Native row 不经过外部 wire；字段在 `ActivityHarvest.Row` 内按类型校验和敏感信息清洗。
  显式 legacy 模式才启用 schema 2 JSON，未知 schema 直接进入 failed health，不会把错位字段
  渲染成有效内容。读取受保护的 App Support/App Group 需要按 Agent 明确授权；native reader
  在访问前做 lexical TCC gate，ProcessProbe 的 lsof 也只接收已授权 Agent 的 PID。

legacy 超时不再丢弃已有结果：完整的行留下、被截断的最后一行丢掉；native adapter
按自己的时间预算直接返回已解析事实。

#### Harvest merge（事实连续）

一个会话文件常被拆成多条 Fact（用户 prompt、多次 `tool_use`、cwd 碎片）。
Adapter 在补齐路径派生的 `sessionID` / Claude encoded cwd / subagent 计数之后，
会对同一文件的碎片 **再跑一次 merge**，否则盖章同一 session id 会把身份压扁，
最早的碎片会永远抢走最新动作。

合并规则（`NativeActivityHarvest.merge`）：

- **identity**：同一 `(session / path)` 收成一行
- **task / cwd / project / model…**：先写优先（空才填）
- **tool：后写非空覆盖** —— Claude 的 `tool_use` 出现在用户 prompt 之后；
  prefer-first 会让行永远停在空动作
- **tokens / progress / subRunning / subTotal**：取 max
- Codex 无类型的 head/compat 行：保留 cwd/tool/tokens，**不把裸 `title`
  升成 task**（那是 plan/registry 标签，不是用户目标）
- **`bestEffortCache` 永不输出 `.session` 证据** —— 即使路径针或 SQLite 行
  看起来像 structured；薄索引保持 Limited + Support depth「cache / index」
- **pending 词表按整词/短语匹配** —— `depending` 不得因包含 `pending` 子串
  而假抬 Waiting（Goose 历史坑）

`HarvestSupervisor` 在 `StatusStore` 外围为每个 Agent 保存独立的失败次数、下次重试、熔断截止和最后错误；
一次 partial scan 只更新已到达的 adapter，下一次只探测已到期的 Agent，全部退避时做一个半开探测。

### AttentionReader（事件驱动）

`~/Library/Application Support/Pulse/attention.tsv`，由 `pulse_hook.py` 写入
（Claude Code 的 hooks、Codex 的 `notify`）。格式见
[`attention-bridge.md`](attention-bridge.md)。

规则：同一 `(agent, session)` 后写的覆盖先写的；`done` 清除；`stop` 也清除，
但 20 秒宽限内不清掉刚发生的 Permission/Input——Claude 常常先发 idle_prompt 再发 Stop。
超过 30 分钟的条目直接过期。

`AttentionWatcher` 用 `DispatchSource` 盯着这个文件，写入即触发刷新，
所以红灯不用等下一个探测周期。

## SnapshotBuilder（纯函数）

合并核心。0.23 之前它埋在 `StatusStore.applyScan` 里，382 行，零测试覆盖。

它做的事：

1. 进程按 agent 收敛，`cursor_agent` 并进 `cursor`
2. harvest 行建会话行；key 冲突时唯一化；每 Agent 的 500 条采集输入保留 500 条，
   超出部分精确计入未显示数量；面板 glance 默认全局前 12 行
3. 陈旧 harvest 丢弃；同 Agent 没有任何新鲜记录且进程仍在时，只允许一个未完成记录
   按工作区匹配 / 最近活动降级为上下文；subagent 仍在运行的记录不视为陈旧
4. `skill=pending` → Waiting，除非用户软忽略过
5. live 进程**只挂到一行**，不在同 agent 的兄弟会话间涂抹
6. attention 三级匹配：session id → cwd → 该 agent 最合适的行；都不中就新建一行
7. 解析 focus 分级；进程探测补充可验证的工作目录（每轮一次，不在视图里）
8. 排序：Waiting → 有会话标题 → live → recent → agent 优先级
9. 编码 glance 状态、标题、tooltip、header
10. 算边沿：哪些是**新**的 Waiting、哪些等待结束了、灯是否刚变灰

**它不做任何有副作用的事。** 时钟、终端环境、路径存在性判断都从 `Context` 注入；
想让外界做的事——发通知、写日志、清除某个 key——全部作为数据返回。
这就是为什么它能被专门的纯逻辑回归测试覆盖，并可在完整 XCTest 环境中独立验证。

## Attention ledger 与 StatusStore（外壳）

AttentionReader 仍读取 agent-owned 的 attention.tsv，但 Waiting 边沿、通知时间、稍后截止
时间、排队、确认、稳定事件 ID 和已解决历史由 Pulse-owned 的 attention-ledger.json 原子写入
Library/Application Support/Pulse。账本只保留 row key、Agent、会话短标识、项目尾部和
时间戳，不保存提示内容或 tool 参数；首次可信扫描播种 baseline，崩溃/重启不会重复通知，
清空历史只删除已解决事件。

拥有 builder 刻意不碰的东西：

- **定时器与节奏**。`ProbeSchedule` 给出间隔，`PowerMonitor` 提供息屏 / 锁屏 /
  低电量状态。息屏即停表——attention 文件变化仍会唤醒。
- **通知策略**。builder 报告边沿，store 决定要不要发：安静时段、按 agent 静音、
  开关、首扫只播种不通知（否则启动时会为所有已有的等待刷屏）。
- **设置**。`PulseSettings` 负责解析和序列化，store 只做桥接和落盘。
- **权限边界**。0.48 的 `appDataPolicyVersion` 不继承旧版全局授权；旧文件先回到关闭，用户在逐 Agent 选择后才重新启用，避免升级后的 ad-hoc 身份触发后台 TCC 弹窗。
- **动作**。可靠 Focus、安装 / 移除 hooks、复制诊断信息、打开 Agent 详情审视器。

## 视图

`StatusPanelController` 拥有原生状态项和单表面 `NSPanel`；其中承载
`TrayPanel`（连续会话列表 + Header 动作），`SettingsView` 管偏好。SwiftUI 视图都标了
`@MainActor`——SwiftUI 只有 `body` 隐式主 actor 隔离，
辅助计算属性不是，调 store 的 `@MainActor` 方法会编译失败。

视图里不做 I/O。focus 分级和目录存在性在扫描时算好存进 `AgentRow`，
此前它们在 `estimateHeight` 里，意味着每行每次重绘都遍历一遍运行中的应用并 stat 磁盘。

## 版本身份

`PulseVersion.semver` 是唯一真源。`package.sh` 把 git short sha 与构建日期写进
`Info.plist`，运行时读回，于是有三档：

| channel | 判据 | 显示 |
| --- | --- | --- |
| `release` | bundle 版本 == 编译版本 | `Pulse 0.61.0` |
| `dev` | 无 bundle 版本（`swift run`） | `Pulse 0.61.0-dev` |
| `mismatch` | 两者不一致 | `0.61.0≠0.60.0` + 橙色警告 |

`PulseDistributionChannel` 另标记分发通道：`preview`（ad-hoc）、`signed`（Developer ID
未公证）、`stable`（公证成功，`PulseNotarized=true`）。无 Apple Developer ID 时 GitHub
仍可将当前 semver 标为 **Latest**，但 Info.plist **不得**写 `stable`，About 保持
preview/signed；只有 notarized 才能自称 Gatekeeper-ready。
`InstallTruth` 发现用户安装副本的边界：Launch Services 已注册路径 + `/Applications`、
`~/Applications`、Desktop、Downloads **一层** `*.app`，以及 Application Support 下的
rollback；不递归扫嵌套目录。未注册且不在上述根的孤儿可能漏检。
更新器在下载校验后先挂载预检，再由同一可执行文件的 helper 等待父进程退出，事务式移动旧 App 到
`~/Library/Application Support/Pulse/rollback`；`current.json` 让下一次启动可以恢复未完成替换。

`mismatch` 针对的是菜单栏应用的高频陷阱：装了新版，旧的还在跑。

## Native 是运行时真源

`NativeActivityHarvest.swift` 是正常运行时的采集真源，所有 31 个用户可见 Agent 都有
Swift descriptor、权限边界、bounded file walk 和健康结果。`src/activity_scan.py` 只保留为
可选 legacy adapter / fixture source；它不会在默认启动或刷新路径被 fork，也不能使自检失败。

hooks 仍可按用户选择安装。它们使用 `RuntimeResolver` 查找可选 Python，而不是假定某个
系统路径；缺少 Python 只会让 hook 操作返回可行动的失败，不影响 native harvest。

## 门禁

| 脚本 | 守什么 |
| --- | --- |
| `version_check.py` | 版本只有一个真源，CHANGELOG 与 README 徽标跟随 |
| `coverage_check.py` | 每个 `AgentID` 都有 harvest 接线；新增 id 未登记即失败 |
| `matrix_check.py` | README 支持矩阵 == `AgentID.harvestSource` + `waitingSource` |
| `make_agent_icons.py --check` | 每个 `AgentID` 都有图标，且与生成器逐字节一致 |
| `appearance_check.py` | 没有把随外观变化的值冻进常量（0.27.1 因此丢了深色模式） |
| `harvest_stats_check.py` | 把真实会话文件摆到真实位置，跑真实 collector，验完整 TSV |
| `resource_budget_check.py` | native fixture 墙钟 + RSS 上限（env 可调） |
| `package_check.py` | 打出来的 `.app` 能找到自己的资源 |

八个都在 `package.sh` 和 CI 里。加上 `swift test` 与 `--selftest`，这是全部自动防线。

**门禁只能守它真正执行的东西。** `harvest_stats_check.py` 的 0.28.0 版本
自称「跑真实 harvester」，实际只调 helper 再数源码字符串——而字符串计数
分不出「接线」和「接了但下游被砍掉」，于是 Cascade 与 Amp 两条数据丢失
全程绿灯出厂。凡是加门禁，先把它要防的那个 bug 放回去，确认它会红。
