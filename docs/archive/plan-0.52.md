# 0.52 计划 —— Release Trust / 可交付信任

## 先说这份评估的局限

0.50 / 0.51 把观测做深、把文案做诚实。本机已装 0.51.0。再开一版「观测主题」
收益变薄；下一刀切在 **发布可信度、扫描成本、通知真相、真机回归、诊断包**。

**这一版的诚实前提：**

- 不扩 Agent 名单（冻结 31）。
- 不重做 Waiting 账本、质量信封、scoped App Data。
- 现状仍是 preview / ad-hoc / 未公证 —— 标签与 Gatekeeper 事实必须一致。

---

## 现状盘点（0.51.0）

| 主题 | 状态 | 0.52 动作 |
| --- | --- | --- |
| GitHub prerelease ↔ ad-hoc | 已对齐 | 签名但未公证不得标 stable |
| Info.plist `PulseDistributionChannel` | 只看签名身份 | 公证成功才 `stable` |
| UpdateCheck `/releases/latest` | preview 看不到下个 preview | preview 读 releases 列表 |
| `collectorScanIncomplete` | 故意延后也亮灯 | intentional partial 不亮 |
| Claude `native_timeout` | 整盘 incomplete | 分文案 + 不掩盖健康 Agent |
| 通知 denied | 有横幅 | safe report + Settings 常驻提示 |
| 截图 QA 脚本 | Darwin 手工 | CI 产物上传 |
| safe report | 缺通知/权限/超时 | 补齐脱敏字段 |
| 托盘「最近变化」 | 折进 signalLine | a11y 统一到 signalLine |
| 资源门禁 | 仅墙钟 8s | native fixture RSS/墙钟 |

---

## P0 · 必须完成

### P0-1 发布标签与公证真相

- `package.sh`：`DISTRIBUTION_CHANNEL` = preview（ad-hoc）/ signed（有签名无公证）/ stable（公证成功）
- Info.plist 写入 `PulseDistributionChannel` + `PulseNotarized`
- `release.yml`：ad-hoc **或** 无 notary → GitHub prerelease
- About：三态文案；Gatekeeper 首次打开说明仅未公证时写入
- `UpdateCheck`：preview 通道读 releases（含 prerelease），不跨通道误升

### P0-2 扫描能量与 incomplete 隔离

- intentional supervisor partial → **不**设 `collectorScanIncomplete`
- incomplete 文案区分：timeout-with-rows / 失败 / （不再把故意延后当 incomplete）
- 托盘 incomplete 短提示与 Support 同源；不 blank 其它 Agent

### P0-3 通知权限真相

- denied：托盘/Waiting 维护条 + Settings 常驻「去系统设置」；不循环索取
- safe report 写入 `notifications:` 授权与 pending 计数

---

## P1 · 显著提升

- CI macOS job：跑 `qa_observation_truth.sh`（或 packaged binary 等价 capture），上传 PNG 产物；缺文件失败
- `safeSupportReport`：appDataGrant、probeCadence、per-agent errorKind/duration、supervisor deferred
- a11y：以 `rowSignalLine` 为动态摘要主源，去掉重复 activityChange+metrics
- EXPERIENCE / AGENTS 指针

---

## P2 · 门禁

- `scripts/resource_budget_check.py`：`--native-fixture-test` 墙钟 + RSS 上限（env 可调）
- `harvest_stats_check` / package / CI 接入；AGENTS 八门禁
- 加深 timeout / partial 相关 Swift 测试

---

## 验收

- 未公证包绝不能标 stable / 非 prerelease
- supervisor 故意延后不出现 incomplete 横幅
- timeout-with-rows 有专属文案；其它 Agent 仍可见
- 通知 denied 时 Settings 与 safe report 诚实
- CI 上传 observation-truth PNG；缺图失败
- resource budget gate 绿
- swift test + 门禁 + version_check 对 0.52.0

## 明确不做

额度 HUD、托盘 approve/deny、扩 Agent、远程账号、装饰动画、Figma 前置。

## 顺序

P0-1 发布标签 → P0-2 incomplete → P0-3 通知 → P1 诊断/截图/a11y → P2 资源门禁 → CHANGELOG / 发版。
