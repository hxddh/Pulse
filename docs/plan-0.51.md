# 0.51 计划 —— Observation Truth / 诚实表面

## 先说这份评估的局限

0.50.0 交付了质量信封、500 会话索引、恢复分类与权限定向重扫。本机 Cursor
App Data A/B 证明：**托盘在 scoped 授权下正确**，但 Support 横幅、
`--harvest-test`、托盘指标去重仍会撒谎或重复。0.50 P1（灯可解释、Settings
深链、能力卡片补齐）未收完。

**这一版的诚实前提：**

- 不扩 Agent 名单（冻结 31）。
- 不重做 Waiting 账本、事务更新、InstallTruth。
- 主题是让已有能力在真机上说对、显示对、诊断也对。

读代码能发现「没接线」；截图才能发现「看起来不对」。P1 视觉项仍以真机截图
为最终验收。

---

## 现状盘点（0.50.0 + 本机 A/B）

| 主题 | 状态 | 0.51 动作 |
| --- | --- | --- |
| ObservationQuality 信封 | 已交付 | 补 timeout / nextStep 映射 |
| 托盘 scoped App Data | 真机正确 | 保持 |
| Support「deep scan is off」横幅 | 撒谎（scoped 仍全关文案） | 三分 all / scoped / none |
| `--harvest-test` | 不读 settings | 加载同一 settings.txt |
| Context 行重复 | 真机见过 | compactSignalEvidence |
| Claude native_timeout | 整盘 incomplete 笼统 | 分文案 + 行级原因 |
| 灯 tooltip | 运营摘要 | waiting/stalled/error 可解释 |
| Settings 深链 | 只 openSettings() | focusAppDataFor agent |
| Support 能力 pill | 仅 observed | privacy/limited 也显示缺口 |
| 检查器质量卡 | 有摘要 | confidence / facts / 深链 |
| status-* fixture | QA 分支已修 | 保留 |
| 扫描耗时门禁 | 无 | HARVEST_MAX_SECONDS |

真正撑起 0.51.0 的事：

1. Support / harvest CLI / 托盘与真实 `appData*` 授权对齐
2. 指标去重与超时诚实文案
3. 灯可解释、Settings 深链、能力卡片与检查器补齐
4. QA 脚本与 harvest 墙钟门禁

---

## P0 · 必须完成

### P0-1 Support 隐私横幅对齐 scoped 授权

**缺口**：任一 `privacyLimited` 就显示「deep app-data scan is off」；只开
Cursor 时 Available 已是 1，横幅仍像全关。

**做法**：`appDataGrantMode` = all / scoped(n) / none；横幅三分文案；Settings
按钮深链到第一个受限 Agent。

**验收**：Cursor-only ON 时横幅为 scoped 文案，非全关。

### P0-2 `--harvest-test` / `--harvest-dump` 读同一 settings

**缺口**：`ActivityHarvest.scan()` 默认关 App Data，A/B harvest 文本无差异。

**做法**：`PulseSettings.loadFromDisk()`；dump 打印 `appData` / agents；
QA 脚本断言 B≠A。

**验收**：scoped ON 时 dump 反映授权；cursor health 可区分。

### P0-3 托盘指标去重

**缺口**：无 `activityChange` 时 `rowSignalMetric` 与 `rowStableFacts` 双写
Context。

**做法**：无变化分支走 `compactSignalEvidence`。

**验收**：单测无重复 Context 串。

### P0-4 扫描不完整与超时诚实

**缺口**：Claude `native_timeout`（已有 rows）仍只显示笼统 incomplete。

**做法**：timeout_with_rows vs 失败 vs 故意延后；质量缺口
`scan_timeout` / `retry_scan`；托盘短提示；不 blank scan。

**验收**：超时 Agent limited + 原因；其它 Agent 仍可见。

---

## P1 · 显著提升产品力

- 灯 tooltip：waiting/stalled/error 含谁、为何、多久
- `openSettings(focusAppDataFor:)` + Support / 质量下一步深链
- Support 对 privacy/limited/unscanned 显示能力缺口 pill
- 检查器：人类化 confidence、facts、collector 读时间 / errorKind、深链
- `observationGapNextStep` 显式映射各 nextStep 码

---

## P2 · 门禁与回归

- `scripts/qa_observation_truth.sh`：status-* fixture 截图
- `harvest_stats_check.py`：墙钟 ≤8s（`HARVEST_MAX_SECONDS`）
- 保持 preview / ad-hoc

---

## 验收标准

- Cursor-only ON：Support 横幅为 scoped；Available ≥1
- harvest-dump 反映 `appDataAgents`；A/B 可区分
- 无重复 Context 指标
- Claude timeout 不拖空白整盘
- waiting 灯 tooltip 含 agent + 原因
- Support/质量下一步可落到对应 App Data 开关
- swift test + 七门禁 + version_check 对 0.51.0

---

## 明确不做

- 额度 / 费用 / reset HUD
- 托盘内批准 / 拒绝
- 后台远程账号体系
- 桌面宠物和纯装饰动画
- 继续扩 Agent 名单
- 在 feature 分支打 `[release]`（合入 main 后再发）

---

## 顺序

P0-2（harvest CLI）先解堵 QA → P0-1 横幅 → P0-3 去重 → P0-4 超时。
P1 深链与 nextStep 可并行；灯 / 卡片 / 检查器随后。
P2 与 CHANGELOG 在 P0 可验收后推进。

版本号与 CHANGELOG `## 0.51.0` 在功能可验收时再写；发布门禁拒绝无该段的发布。
