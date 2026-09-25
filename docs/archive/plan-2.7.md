# 2.7 计划 —— Fleet / 舰队

## 版式沿用 2.2：先还账，再加新轴

### P0 · 实证 —— 2.6 的「已知限制」自己关掉

2.6 的发布说明写「git 的实际行为只有真机能证」。**CI 的 macOS runner 就是一台真机。**
`RealGitTests` 在 runner 上建真仓库、跑真 git、对账计数 —— 与
`testTheRealParentLookupAgreesWithTheKernel` 用同一个模式。

**它第一跑就抓住了一个已发布的真缺陷（G-5）**：porcelain 的 `git diff` 在 stat 缓存
失配时改写 index，且 `--no-optional-locks` 与 `GIT_OPTIONAL_LOCKS=0` **都拦不住**
（optional-locks 机制盖住 `status` 的隐式刷新、盖不住 `diff` 的；先前一轮容器测量
以为环境变量有效，是测量顺序造成的假象 —— 第一次 diff 写回后 stat 已一致，之后
自然「不再写」）。也就是说 2.6.0 的每一次测量都在真实改写 index 并短暂持有
`index.lock`。修法：行数改用 **plumbing 的 `diff-index --shortstat HEAD`** —— 它从不
刷新、对 stat 脏条目做内容核对、输出同一种 shortstat，解析器一字不改；三个变体各用
全新仓库隔离验证（真实改动 / stat 脏但内容相同 / 删除文件全部正确）。index 逐字节
不动由 RealGitTests 对真仓库断言（SHA-256 前后一致）—— fixture 永远看不见这类缺陷，
这正是实证轴存在的理由。

### P0 · 审计 —— 2.6 新面挖出四条

| ID | 项 | 修法 |
| --- | --- | --- |
| G-1 | **「在动，盘上没落地」对边干边提交的 agent 是诬告** —— 提交后工作树干净，那是「全落地了」，不是「没落地」 | 每次测量顺带 `rev-parse HEAD`（已在允许动词集合内，不碰 index）；两拍 HEAD 不同 → 记住「最近有提交」10 分钟；窗口内不再说那句话 |
| G-2 | `rootByDirectory` 无界增长 —— 见过的每个工作目录记一辈子 | 上限 256，超了只保留本拍还在关心的目录 |
| G-3 | 目录解析无每拍上限 —— 一拍冒出 N 个新会话就 fork N 次 rev-parse | 与测量共用 `maxRootsPerTick`，其余排到后续拍 |
| G-4 | 长时间 park 后第一拍把几小时前的计数当「此刻」端出来 | 存量测量超过 120 秒即按未知供给（陈旧不冒充此刻，2.4 的规矩） |

### P0 · Fleet —— 舰队不再只有门铃

1.0 之后远端 agent 只在**门铃响的时候**存在：行由 attention raise 构造，`done` 即清。
「devbox 上三个 agent 还在跑」和「devbox 关机了」在 Pulse 里一模一样 —— 而场景就叫
Remote Fleet。

同一形状的第三个目录：本机 Pulse 周期写 `fleet.d/<host>.json`，用户自己的同步工具
搬运，对端读其余 host 的文件。没有网络、没有服务器、没有守护进程。

**硬规则**：

1. **远端事实全部是过去时。** 快照年龄随行走：新鲜（<10 分钟）才引用实质；过期进
   失联（行留着、实质不引用）；一小时后整行消失。年龄以**本机磁盘的 mtime** 计
   （AttentionIO 的 receivedAtMs 同理），发送方时钟超前 5 分钟即 clockSuspect。
2. **Waiting 永不来自快照。** attention 协议是 Waiting 的唯一来源；同一 host+agent+
   session 的 raise 与快照落在**同一个 rowKey** 上 —— 等待来自 raise，实质来自快照。
   两把 key 会让「running」行和它自己的「waiting」行并排站着。
3. **计数与短名。** 标题 ≤160 过 `ContentSanitizer`；project 只取叶子名，**永不带
   路径**（连到达的路径都先削成叶子）；不带分支、不带 diff 正文、不带 argv。
4. **广播默认关**（内容离开本机是用户的选择，每次都是）；**读取常开**（被动、本地、
   有界，目录不存在就是空）。关掉广播时删除本机文件 —— 死快照不许继续搭着同步工具
   看起来权威。
5. **远端行永不**报进程、没有 Focus、`workspaceRoot` 恒空（构造上进不了碰撞计数）。
6. **本机快照只含本机行。** 转播 devbox 的行会在两台机器互同步的那一刻让每个 agent
   翻倍。
7. 有界：≤16 host、每份 ≤16 行、≤256KB/文件；文件名决定 host，正文不符即拒收
   （respond spool 的同一条规矩）；未知 agent 跳过、不猜。

### 明确不做

| 项 | 理由 |
| --- | --- |
| 舰队仪表盘 / 分组看板 | 统计大盘是非目标；还是同一个托盘、同一套行、同一个排序 |
| 快照签名 | 快照是观测不是判决，最坏后果=一行假信息（无动作可执行）；判决路径的 HMAC 纪律原封不动 |
| 远端 Focus / 远端碰撞 | 都是对另一台机器磁盘的主张 |
| 实时推送 | 同步工具的节奏就是节奏；30 秒写一次已远超「扫一眼」的需要 |

### 先决门槛照旧

P0-0 那十分钟真机取证（`qa_respond_evidence.sh`）仍等用户；S1 挂着；S2 剩余按
`plan-2.5.md` 的评估不做。
