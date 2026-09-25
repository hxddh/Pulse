# 5.0 — Runtime / 双引擎（市场定义的质变）

## 诊断（4.0 为什么仍是半成品）

对照 2026 年的顶尖同类（Conductor / Nimbalyst / Vibe Kanban / Claude Squad /
Sculptor / Omnara）：**每一家都拥有它展示的会话** —— 由它启动 agent 进程、独占
结构化输出流，所以完整对话、直接回复、隔离并行、验收合并是架构的自然结果。
Pulse 是全市场唯一的纯旁观者：观察靠磁盘考古（尾窗 / mtime / 形状解析），动作
靠 AppleScript 敲键盘 —— 4.0 送达的精确门只对 Terminal/iTerm tty 行成立，IDE
内嵌会话（现实中的大多数）落回剪贴板。**天花板是架构性的，加卡片碰不到。**

保留的地基（竞品全都没有）：对 32 家厂商既有会话的零配置旁观、菜单栏扫视、
诚实纪律、本地 only、能耗纪律。

## 质变的定义

**Pulse 必须拥有它派出的会话，同时保留对一切既有会话的旁观。** 双引擎：
Observed（今天的一切）+ Managed（新 runtime）。

## 三段走

### 5.0-α 引擎边界（彻底重构的本体）

- `SessionSource` 协议：会话生产者的统一契约。`ObservedSessionSource` 收编
  现有 harvest/builder/applyScan 管线为第一个 conformer；
  `SessionSourceCoordinator` 归 StatusStore 持有，合并各源产出。
- 合并契约（测试钉死）：各源内部顺序保留；源按注册序优先；rowKey 冲突先注册
  者胜；轻路径补丁经协调器同时落到源与合并缓存，不允许两份真相。
- 单源时逐字节透传 —— 行为冻结，全量测试是契约。这就是 3.0 起「接缝跟着用法
  走」欠着的那条真接缝：第二个生产者的出现使它不再可推迟。

### 5.0-β 受管会话（质变本体）

- 派活重生：Pulse 以 `claude -p --output-format stream-json`（续回合
  `--resume <sid>`）**纯管道**驱动子进程 —— 无 PTY、无 AppleScript、无 TCC。
  跑在 Pulse 建的 git worktree（`git worktree add`，Pulse 自己的命名空间）或
  用户明选的目录。
- `ManagedSessionSource`：stream 事件（init / assistant / tool_use /
  tool_result / result）→ 第一手 Session 事实（task/tool/tokens/cost/
  transcript 全量、无「没测到」折扣）；行进指挥台与托盘（section 规矩沿用）。
- 指挥台对话面板：完整会话流原生渲染（复用 TranscriptReader 的条目形状），
  回复框 = 下一回合（`-p --resume`），取消 = 终止子进程（SIGTERM→SIGKILL，
  既有纪律），成本与 token 逐回合累计。
- 权限语义（唯一需要专门定的设计点，保守起步）：v1 继承用户项目自身的
  settings/allowedTools，headless 拒绝的工具调用如实显示为「被权限挡下」，
  由用户在对话面板补一句授权语义的回合或转终端接管；不建 Pulse 自己的
  permission-prompt 通道（那是 5.1 复用 Respond 的事）。
- 生命周期：退出杀全部子进程（终止标记先例）；崩溃后孤儿以 PID 文件收养或
  提示；能耗 = 事件驱动读管道，无轮询。

### 5.0-γ 验收闭环

- 受管 worktree 上的动词：diff（已有只读纪律）、提交、开分支、开 PR ——
  全部用户点击触发。
- 原则重划（照 3.0-β 改「只有计数」的先例写进 EXPERIENCE）：**「永不代动
  仓库」是对旁观会话的规矩**；Pulse 自建的 worktree 里，用户点击就是行动者。
- 观察行保留 4.0 全部路径不动。队列/多任务看板排 5.1。

## 不变的脊柱

旁观会话的一切诚实规矩不动；跨机器仍只运计数与短名；Waiting 唯一来源不变
（受管会话的「等回复」是第一手事实，不经 attention 协议，也**不点亮托盘红灯**
—— v1 受管等待只在指挥台呈现，避免两套 Waiting 语义混血）；能耗硬约束；0600。

## 风险与对策

- 盲写子进程管理：回合制管道正好落在 ProcessIO 纪律内；stream-json 全部用
  fixture 测试；真机脚本 `qa_managed_session.sh` 验一条完整回合链。
- stream-json 格式漂移：版本探测 + 未识别事件如实计数（TranscriptReader 同款）。
- worktree 卫生：Pulse 只删自己建的（命名空间前缀），孤儿 worktree 列出让
  用户处置。
