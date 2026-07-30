# 架构

数据从「机器上有个进程」走到「菜单栏亮红灯」的完整路径。

```
  ┌─ ProcessProbe ──┐   ps -axo，进程 → AgentID，解析 TTY 与 Warp 父进程
  │                 │
  ├─ ActivityHarvest┤   fork activity_scan.py，读各 Agent 的会话文件 → TSV
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

顺着 ppid 链向上找，回答两件事：真实 TTY 是什么（进程自己常是 `??`），
以及是不是跑在 Warp 里（决定 Focus 该怎么做）。

`signature()` 给出这一轮的进程指纹。指纹没变，说明会话数据大概率也没变，
昂贵的 harvest 就能跳过。

### ActivityHarvest（昂贵，按需）

fork `src/activity_scan.py`，它读各 Agent 自己的私有文件——
Claude 的 `~/.claude/projects/*/*.jsonl`、Codex 的 rollout、Cursor 的
`state.vscdb`、OpenCode 的 sqlite……每个 agent 一个采集器，输出一行 TSV。

两条硬约束，都是踩过坑之后加的：

- **逐 agent 隔离**（`guard()`）。任一采集器抛异常只影响它自己，写 stderr，
  其余照常输出。此前一个坏采集器会让脚本非零退出，Pulse 丢掉全部 32 个 agent 的结果。
- **边跑边读**。Swift 侧用独立线程排空 stdout/stderr。此前是等子进程退出后才读，
  输出一超过 64KB 管道缓冲就死锁到超时——越忙越没数据。

超时不再丢弃已有结果：完整的行留下，被截断的最后一行丢掉。

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
2. harvest 行建会话行；key 冲突时唯一化；每 Agent 的 64 条采集输入保留 32 条，
   第 33–64 条精确计入未显示数量
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
这就是为什么它能被 34 个测试覆盖。

## StatusStore（外壳）

拥有 builder 刻意不碰的东西：

- **定时器与节奏**。`ProbeSchedule` 给出间隔，`PowerMonitor` 提供息屏 / 锁屏 /
  低电量状态。息屏即停表——attention 文件变化仍会唤醒。
- **通知策略**。builder 报告边沿，store 决定要不要发：安静时段、按 agent 静音、
  开关、首扫只播种不通知（否则启动时会为所有已有的等待刷屏）。
- **设置**。`PulseSettings` 负责解析和序列化，store 只做桥接和落盘。
- **动作**。可靠 Focus、安装 / 移除 hooks、复制诊断信息。

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
| `release` | bundle 版本 == 编译版本 | `Pulse 0.28.1` |
| `dev` | 无 bundle 版本（`swift run`） | `Pulse 0.28.1-dev` |
| `mismatch` | 两者不一致 | `0.28.1≠0.28.0` + 橙色警告 |

`mismatch` 针对的是菜单栏应用的高频陷阱：装了新版，旧的还在跑。

## Python 是真源

`src/*.py` 是唯一真源，`PulseBar/Sources/PulseBar/Resources/` 里的是
`package.sh` 同步出的副本。两份都在版本控制里，CI 比对，不一致就红。

改采集逻辑改 `src/`，然后跑一次 `package.sh`。

## 门禁

| 脚本 | 守什么 |
| --- | --- |
| `version_check.py` | 版本只有一个真源，CHANGELOG 与 README 徽标跟随 |
| `coverage_check.py` | 每个 `AgentID` 都有 harvest 接线；新增 id 未登记即失败 |
| `matrix_check.py` | README 支持矩阵 == `AgentID.harvestSource` + `waitingSource` |
| `make_agent_icons.py --check` | 每个 `AgentID` 都有图标，且与生成器逐字节一致 |
| `appearance_check.py` | 没有把随外观变化的值冻进常量（0.27.1 因此丢了深色模式） |
| `harvest_stats_check.py` | 把真实会话文件摆到真实位置，跑真实 collector，验完整 TSV |
| `package_check.py` | 打出来的 `.app` 能找到自己的资源 |

七个都在 `package.sh` 和 CI 里。加上 `swift test` 与 `--selftest`，这是全部自动防线。

**门禁只能守它真正执行的东西。** `harvest_stats_check.py` 的 0.28.0 版本
自称「跑真实 harvester」，实际只调 helper 再数源码字符串——而字符串计数
分不出「接线」和「接了但下游被砍掉」，于是 Cascade 与 Amp 两条数据丢失
全程绿灯出厂。凡是加门禁，先把它要防的那个 bug 放回去，确认它会红。
