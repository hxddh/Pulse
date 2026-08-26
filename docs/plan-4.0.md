# 4.0 — Operator / 操作台（把 3.0 欠下的三笔债一次还清）

## 诊断（3.0 为什么是半成品）

用户的判词成立，逐条认领：

1. **没有质变**：指挥台每张卡的事实（等待/计划/原话/token/diff 计数）全是托盘
   与 Details 已有的，只是换了更大的容器。真正新增的信息只有 diff 正文一项。
   「看清楚一个会话」交付的仍是十来个抽取字段，不是会话本身。
2. **没有重构**：α 是文件搬运。StatusStore 仍是 4200 行神对象，AgentRow 仍是
   ~70 个平铺字段，Session 实体不存在。「接缝跟着用法走」被推迟成了没发生。
3. **能力平庸**：权限类 Respond 卡是 2.4 的旧物换窗重放；提问类「回答」实为
   剪贴板助手（用户自己粘贴自己回车）；复盘是卡片重排序；派活整个推给 3.1。
   「判断权不转移」被过度应用 —— 它禁止的是盲目代答，从不禁止「用户写好回复、
   点发送，Pulse 负责送达」：用户敲下的回复本身就是判断。盲写 Swift 没有真机，
   于是处处选了最不会出错、也最没用的实现。

## 三段走（每段一个 PR，全量测试冻结契约）

### 4.0-α 全文（看见会话本身）

- 管线：`NativeActivityHarvest.Fact.sourcePath` 已存在但止步于 Native 内部。
  接出来：`ActivityHarvest.Row.transcriptPath` → `AgentRow.transcriptPath`。
  只在 `structured` 且文件形如 JSONL 时携带；**永不进 fleet 快照、永不上托盘、
  永不进 debug.log 之外的任何出机通道** —— 这是指挥台专用的本地读取句柄。
- `TranscriptReader`：按需读取（点击才加载，能耗硬约束），尾窗有界
  （默认尾部 512KB / ≤300 条），撕裂首行跳过（2.1 AP 的同一课）；**按形状
  解析不按厂商名**（2.9 平权）：Claude 家族 `message.content[]` 块、Codex
  `event_msg` 信封、通用 role/content 形状；逐条过 `ContentSanitizer`、
  逐条截断；解析不出的行如实计数为「未识别」，不猜。
- 展示：检视器新增「会话全文」卡 —— 角色徽标（用户/agent/工具），工具行带
  名称与结果状态，错误结果标橙；截断时明说「只读了尾部 N KB」；不支持的
  来源（cache、SQLite、远端行）不装按钮。运行中与复盘两种序都有它。
- 原则边界（写进 EXPERIENCE）：全文是**指挥台的**能力 —— 本地、只读、
  点击才加载、逐处消毒、一个字节不出机器。托盘与跨机器通道的规矩一字不动。

### 4.0-β 真动词（送达，不是复制）

- **回答 = 送达**：读全文 → 写回复 → 点「发送」。Pulse 沿既有 TTY 定位纪律
  找到那个终端标签页，经 Automation（System Events keystroke）把回复敲进
  会话并回车。判断权的每一寸都在用户手里 —— 文本是用户写的，发送是用户点的，
  Pulse 只出手指活。Opt-in（沿用/并列既有 Automation 开关），未开启时回退
  3.0 的剪贴板路径（降级为回退，不再是本体）。每个出口可见：送达成功 /
  找不到标签页 / 未授权，都在卡上说。
- **派活 = 启动**：选仓库根（来自已观测的 workspaceRoots）、写任务句，
  Pulse 在正确目录起新会话（Terminal `do script`：`cd <root> && claude '任务'`）。
  同一个 Automation opt-in，同一套 fail-visible。
- 真机验证：`scripts/qa_workbench_actuation.sh` —— 用户十分钟脚本，逐步
  验证聚焦/敲入/派活三条路径。**这是全案唯一必须真机确认的部分**；合并不等
  验证，发布前如实标注验证状态。

### 4.0-γ 重构兑现（不再是「以后」）

- `Session` 成为一等值类型：AgentRow 的平铺字段按事实簇重组
  （identity / liveness / selfReport / effect / remote），编译器驱动迁移，
  行为零变化，全量测试冻结。
- StatusStore 沿指挥台的真实读取面拆引擎边界：采集调度 / 状态 / 服务。
- 验收线写死：`StatusStore.swift` < 1500 行；拆出的每个文件单一职责。

## 不变的脊柱

没测到的不许说；Waiting 唯一来源是 attention 协议；fail-open；0600；跨机器
只运计数与短名；判断权一寸不转移（送达 ≠ 代答）；能耗是硬约束；陈旧不冒充
此刻；文件名决定身份。

## 风险与对策

- keystroke 语义未经真机验证 → opt-in + fail-visible + qa 脚本 + 发布说明
  如实标注；剪贴板路径永远在场作回退。
- 全文展示的泄露面 → transcriptPath 永不出机器；渲染逐条消毒；远端行无按钮。
- γ 的盲改风险 → 值类型重组让编译器当验证器；每段小 PR 快 CI。
