# 0.54 计划 —— Channel Continuity / 通道与契约连续

## 先说这份评估的局限

0.53.0 把安装 / 更新 / 恢复的代码契约做完了，但 **notarized stable 仍缺席**：
`v0.53.0` = Pre-release，GitHub Latest = `v0.48.0`。再开观测主题收益薄；
下一刀切在 **用户触达的链接、数字、更新句与通道事实一致**。

**这一版的诚实前提：**

- 不扩 Agent 名单（冻结 31）；不扩 hook 安装器越过 Claude / Codex。
- **未公证绝不能标 stable / Latest**。
- 无 Apple secrets 时主题仍成立：修契约与叙事，不塞假标签。
- 不为 SIGKILL 上常驻 helper。

---

## 现状盘点（0.53.0）

| 主题 | 状态 | 0.54 动作 |
| --- | --- | --- |
| README 下载链 | 仍指 `v0.49.1`；安装节写 `/latest`→0.48 | 跟当前 semver tag；Latest 叙事诚实 |
| EXPERIENCE 会话预算 | 仍写 256/128 | 对齐代码 500/500/glance 12 |
| Update「已是最新」 | 不解释通道 | preview vs stable 分文案 |
| version_check | 不管下载 URL | 拒绝远旧 tag |
| CI 截图 | 仅 zh/light | 再跑 en/dark |
| ProbeSchedule empty harvest | 每 tick | 空闲降频 |
| crash 文案 | 不提 SIGKILL 上限 | 谦虚说明 |
| InstallTruth | 浅扫未写清 | 文档边界 |
| App Data A/B | 手工 Darwin | **明确不进 CI**（需真机 Cursor） |
| notarized stable | 外部 blocked | 插队槽，不假 Latest |

---

## P0 · 必须完成

### P0-1 触达契约

- README 下载链 → `v{semver}` 当前 tag；安装节不把 `/releases/latest` 写成「当前源码」
- EXPERIENCE：500 读 / 500 保留 / glance 12；图标 32；场景 C/E 与禁常驻动画一致
- AGENTS / architecture 跟 0.54；plan-0.53 → historical；贡献节八门禁

### P0-2 更新通道叙事

- `updateCurrent` 分 preview/signed vs stable：说明相对哪条 feed、「不含 prerelease / 等公证」
- About 保持三态；不跨通道误升

### P0-3 版本门禁扩面

- `version_check.py`：README「下载 DMG」URL 必须含 `v{semver}`

---

## P1 · 显著提升

- CI：`qa_observation_truth` 再跑一组 `en` + `dark`（独立产物目录）
- `ProbeSchedule.harvestEveryNTicks(.empty)` 降频（守 Waiting 2s、无固定短全局 interval）
- 单测覆盖 empty harvest 倍数

---

## P2 · 收口

- LaunchRecovery crash 文案：注明无法区分强制退出（SIGKILL）
- InstallTruth / architecture：写清浅扫边界（Applications / Desktop / Downloads 一层 + LS）
- App Data A/B：书面决定保持手工 Darwin，不进 CI

---

## 验收

- README 下载链 == 当前 semver；安装叙事不把 Latest 当最新源码
- EXPERIENCE 预算与代码一致；version_check 对下载 URL 红/绿正确
- Update「已是最新」分通道可读
- CI 上传 zh/light + en/dark 截图
- empty 空闲 harvest 倍数 > 1；Waiting 仍每 tick
- swift test + 八门禁 + version_check → 0.54.0
- CHANGELOG 写明 stable 仍 blocked on notarization

## 明确不做

额度 HUD、托盘 approve/deny、扩 Agent、扩 hooks、伪造 Waiting、假 Latest、
SIGKILL helper、再开 Observation 大主题。

## 顺序

P0 契约 → P0 更新文案 → P0 version_check → P1 ProbeSchedule / CI → P2 文案与文档 → CHANGELOG / 发版。
