# Pulse 深度 Review — 0.28.0

> 只读审查 · `main` @ `e6db661` · 版本 `0.28.0` · 未改动任何业务代码

---

## 结论

**`0.28.0` 方向对（面板缺「会动的事实」），文档与门禁也比 0.23 成熟；但旗舰 Agent 没接到新事实，且 handoff 文档仍停在 0.23。**

---

## 1. 现在在哪

| 阶段 | 主张 | 状态 |
|------|------|------|
| 0.23 | 核心可测（SnapshotBuilder / Settings） | 完成 |
| 0.24–0.26 | 辨识度、去重、信息效率 | 完成 |
| 0.27.x | Snooze、通知动作、折叠/键盘、深色模式翻车再修 | 完成 |
| **0.28** | harvest 产出会动的量；次行右端展示 | **刚合入** |

架构仍是：

```
Probe / Harvest / Attention
        → SnapshotBuilder（纯函数）
        → StatusStore（副作用）
        → Glance / Tray / Prefs
```

不变量（无假 Waiting、无配额 HUD、无托盘审批、逐 agent `guard`、无固定探测间隔）在代码与 `EXPERIENCE.md` 里仍一致。

本地可跑门禁：`version` / `matrix` / `coverage` / `appearance` / `harvest_stats` 全绿；`src/` 与 Resources 副本一致。本审查环境无 Swift 工具链，`swift test` 未跑；仓库自称 **215** 个测试。

---

## 2. 0.28 做对了什么

1. **问题诊断准**  
   面板不是排版差，是 26/32 harvester 几乎没有生命周期内会变的量；标题 + 路径是死的。

2. **诚实约束对齐产品**  
   `last_tool_name_strict` 拒猜 config / `"name"`；超预算不估 turns —— 与 Waiting 同构。

3. **线协议扩展干净**  
   尾部 `dict` 哨兵避免 tuple 长度歧义；旧 12 列仍可解析。

4. **第七道门禁真跑 Python**  
   合成文件 + 误报 blob + 反向断言（宽松版若不再乱猜则红）—— 近几版里第一次端到端可证的 harvest 改动。

5. **规格已回写**  
   `EXPERIENCE.md`：次行右端 ≤4 事实、工具名不猜、数量不估算、「无项目」不发表头、表头不 pin。

---

## 3. 严重：旗舰 Agent 没吃到 0.28

`session_stats` / `last_tool_name_strict` **没有接到最重要的几路**：

| 采集器 | `session_stats` | 工具提取 |
|--------|-----------------|----------|
| **claude** | 无；且 `claude_block` 直接 `emit()`，绕过 `emit_row` 的 extras | **宽松** `last_tool_name` |
| **codex** | 无 | **宽松** |
| **cursor** | 无（sqlite，无可计 turns 的文件） | 空 |
| grok / pi | 无 | 宽松 |
| gemini / opencode / cline / … | 多数无 | — |
| 长尾 extension / home_dir 等 | **有**（约 18 处） | **strict**（约 16 处） |

CHANGELOG 示例行是：

```
2h · 34 轮 · ↑12k ↓3k
```

但 **Claude JSONL 本可算 turns / started_ms，却没接**；Codex 同理。

门禁只断言：

- `session_stats(` ≥ 15
- `last_tool_name_strict(` ≥ 12

**不要求 claude / codex 在列** —— 所以 CI 绿，旗舰仍可能只有 tokens（Claude 本就有），**时长 / 轮数对主力用户仍是空的**。

这是「声称修好了面板没东西可显示」与「真正常开的 Agent」之间的落差，比文档漂移更要紧。

---

## 4. 文档漂移（接手风险）

| 文档 | 问题 |
|------|------|
| **`AGENTS.md`** | 仍写「0.22 已发布、0.23 进行中」；「下一步」指向 `plan-0.23.md`；release 示例仍是 `0.23.0` |
| **`docs/architecture.md`** | 门禁只列 3 个（现 7）；版本示例停在 0.22；SnapshotBuilder「34 个测试」已过时（现约 59） |
| **`docs/plan-0.23.md`** | 进度写「下一步 P1」，但正文 P1 已全 ✅；无 `plan-0.28`，0.28 只活在 CHANGELOG |
| **`EXPERIENCE.md`** | 抬头「0.22+」；内容已含 0.27–0.28，可用，但版本锚点偏旧 |
| **计划链** | 有 0.23 / 24 / 25 / 27，缺 0.26、0.28；README 已链到 0.24/25/27，AGENTS 未跟上 |

`CHANGELOG` + `EXPERIENCE` 质量高（用真机截图驱动决策）；**缺的是给下一个 agent 的「当前指针」**。

---

## 5. 代码结构与残余风险

### 仍健康

- Builder / Settings / ProbeStats / TrayFold / Snooze 边沿有测
- 深色模式：材质 + `appearance_check`（构造上防再冻外观）
- Snooze：压制打扰不藏行；到期先踢出 `knownWaitingKeys` 再重建 —— 测过

### 值得盯

1. **`rowMetrics` 用墙钟 `Date()`**，而 `sessionAgeSeconds` 设计为注入 `nowMs`；测试已踩过「固定扫描钟 vs 墙钟」—— 视图路径仍混用。
2. **`metaLine` 仍在**（a11y / BehaviourTests），主路径已是 `contextLine` + `rowMetrics` —— 两套叙事并行，易再偏。
3. **体积**：`StatusStore` ~1142 行 / `PulseApp` ~1525 行 / `activity_scan.py` ~2256 行 —— 0.23 抽了 builder，外壳与 harvest 又变厚。
4. **turns = JSONL 行数**：含系统 / 工具行，显示「34 轮」会偏乐观；产品已承认「合成文件 ≠ 真机形态」。
5. **未真机验证**（文档自陈）：键盘导航、`onKeyPress` 焦点、0.28 面板观感、真实 Agent 文件是否出量。
6. **0.23 P2 仍开**：Developer ID 公证；`PULSE_HARVEST_DEBUG`（32 处静默 `except` 仍在）。

---

## 6. 不变量与规格一致性

| 项 | 状态 |
|----|------|
| Waiting 只来自 hooks / pending | ✅ 与代码一致 |
| 非目标（配额 / 托盘审批） | ✅ |
| Focus 诚实分级 | ✅ |
| Glance 无常驻动画、芯片非常态 | ✅ |
| 折叠 ≥5 行、含 Waiting 项目不折 | ✅ 有实现与测 |
| `headerDetail` 恒「刚刚」 | ✅ 0.24 已换成 Agent 聚合 |
| 支持矩阵门禁 | ✅ 31 agent 与 `waitingSource` 一致 |

---

## 7. 总评

产品叙事连贯：

> 亮灯 → 可信 → 看得清 → 用得完 → 有东西可显示

0.28 的门禁思路是对的。

**当前最大缺口不是又一轮 UI，而是：**

1. **0.28 的事实管道绕开了 Claude / Codex / Cursor**
2. **`AGENTS.md` / `architecture.md` 仍指向 0.23**

### 建议的下一步（未实施）

1. 让旗舰 harvester（至少 Claude / Codex）真正发出 `turns` / `started_ms`
2. 收紧 `harvest_stats_check.py`，点名要求这些采集器接线
3. 更新 `AGENTS.md` 当前指针；视需要补 `plan-0.28` 或把「下一步」改到真实缺口

---

## 附录：审查范围

| 路径 | 用途 |
|------|------|
| `README.md` / `AGENTS.md` / `EXPERIENCE.md` / `CHANGELOG.md` | 产品与接手文档 |
| `docs/plan-0.23.md` … `plan-0.27.md` / `architecture.md` | 计划与架构 |
| `SnapshotBuilder.swift` / `StatusStore.swift` / `PulseApp.swift` / `Models.swift` | 核心 Swift |
| `src/activity_scan.py` / `scripts/harvest_stats_check.py` | 0.28 harvest |
| 七个 `scripts/*_check.py` | 门禁 |

审查方式：只读；未改业务逻辑。本文件仅作 review 输出，便于复制。
