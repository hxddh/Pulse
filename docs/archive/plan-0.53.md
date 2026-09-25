# 0.53 计划 —— Delivery Continuity / 交付连续信任

## 先说这份评估的局限

0.52.0 把「标签诚实」做完了：通道三态、intentional partial、通知 denied、
safe report、截图 CI、resource budget 均已进源码与 CHANGELOG。GitHub 上
`v0.52.0` 是 **Pre-release**，**Latest 仍停在 `v0.48.0`** —— 这是契约生效后的
预期副作用，不是发版失败。

再开一版「观测主题」收益变薄。下一刀切在 **可安装、可更新、可恢复的交付信任**：
把 0.52 写好的通道逻辑兑现成用户能双击打开的 stable，并收掉文档/安装/恢复毛刺。

**这一版的诚实前提：**

- 不扩 Agent 名单（冻结 31）。
- 不重做 Waiting 账本、质量信封、scoped App Data、发布通道机。
- **未公证绝不能标 stable / Latest** —— 0.52 核心契约，本版必须守住。
- 无 Apple Developer 凭据时，「首个 notarized stable」是外部 blocker；主题仍成立，
  但 P0 收窄为文档契约 + 安装/更新/恢复连续性，绝不塞假标签。

---

## 现状盘点（0.52.0）

| 主题 | 状态 | 0.53 动作 |
| --- | --- | --- |
| 通道三态 `preview` / `signed` / `stable` | 代码完成；runtime 仍 preview | 配齐 secrets → 首个 notarized stable（外部） |
| GitHub Latest | 停在 `v0.48.0`（非 prerelease） | stable 发布后 Latest 追上源码版本（外部） |
| README 发布说明 | **已对齐**（本版） | 与 `release.yml` 一致 |
| architecture / README 门禁 | **已对齐**（本版） | 三态 + 八门禁 |
| UpdateCheck | **就地安装仅 Gatekeeper-ready** | stable `/latest` 真机仍待公证工件 |
| InstallTruth | **LS + Desktop/Downloads；About「另有 N」** | 有 stable 后做事务替换 E2E |
| LaunchRecovery `forceQuit` | **SIGTERM 意图 + 分类修复** | 真 Force Quit (SIGKILL) 仍报 crash |
| 截图 QA | **轮询就绪 + appearance/language env** | 可选暗色/英文矩阵进 CI |
| none Agent / Attention 桥 | **托盘深链 + Support repair + 文档点名** | 不扩 hook 安装器 |
| bestEffortCache 缺口 | **隐私 → App Data；缓存 → wait-cache 文案** | — |
| 诊断包 | **factCoverage + failureTimeline** | — |

---

## P0 · 必须完成

### P0-1 首个 notarized stable（外部依赖）

- 仓库配置完整六项 Apple secrets（Developer ID p12 + 密码 + identity + notary key/id/issuer）。
- `package.sh` stapler 成功 → `DISTRIBUTION_CHANNEL=stable` + `PulseNotarized=true`。
- `release.yml` 产出 **非** prerelease；GitHub Latest 追上源码版本。
- 真机：双击打开无需右键放行；About 显示 stable；Gatekeeper 说明不再附带。

**无凭据时：** 本项保持「blocked / 凭据到位即发」，**不得**用假 Latest 填充。其余 P0/P1 照常推进。

### P0-2 发布文档契约对齐

- README：删除「不再允许 ad-hoc / 缺凭据拒绝发布」；改为与 workflow 一致——
  缺凭据 → ad-hoc + warning + **prerelease**；仅公证成功才非 prerelease / stable。
- `docs/architecture.md`：`PulseDistributionChannel` 写全 `preview` / `signed` / `stable`；
  门禁表纳入 `resource_budget_check.py`，改为八门禁。
- README 开发节「七个门禁」→ 八个，列出 resource budget。
- AGENTS 指针指向本计划。

### P0-3 UpdateCheck / About 在通道上的连续真相

- 仅 `isGatekeeperReady`（stable / 公证）才允许更激进的 in-place 安装叙事；
  ad-hoc / signed 保持用户主导、Gatekeeper 说明可达。
- stable 发布后验证：About 三态、`/latest` 路径、检查更新不跨通道误升。
- 「Latest 长期落后于 prerelease 链」时，检查更新 / 关于文案不暗示用户已过时到无药可救，
  也不把 prerelease 偷偷推给 stable 用户。

---

## P1 · 显著提升

### P1-1 InstallTruth 与安装面

- 孤儿副本发现面：不止 `/Applications` + `~/Applications` + rollback 的粗分类展示。
- About：duplicates 展示与回收 UX（不止前 3 条的静默截断，或明确「另有 N 个」）。
- 事务替换 / rollback 在 stable 通道上的端到端回归（有 stable 工件后）。

### P1-2 LaunchRecovery 分类诚实

- 补上 `forceQuit` 的 intended-exit 写入，结束 `LaunchRecovery` 里的「future hook」。
- 清理 recovery 文案死分支（`.clean` / `.updateReplace` 误落 crash 文案的粗糙路径）。

### P1-3 CI / QA 硬化

- `qa_observation_truth.sh`：减少固定 `sleep` 竞态；缺图失败已有，追求稳定绿。
- 可选：暗色 + 英文捕获，与 EXPERIENCE 验收矩阵对齐。
- 评估 `qa_mac_cursor_appdata_ab.sh` 是否进 CI（现偏手工 Darwin）。

---

## P2 · 辅线（不当整版标题）

- `waitingSource=.none` 六 Agent：Support / 托盘 nudge 更可行动；attention-bridge
  文档可达性 —— **不**扩 hook 安装器越过 Claude / Codex。
- `bestEffortCache` / App Data 受限 Agent 的缺口文案与深链再打磨。
- Support 诊断「失败时间线 / 字段覆盖率」（0.50 P2 遗留）。

---

## 验收

- 有凭据时：存在 notarized `stable` Release；非 prerelease；Latest == 源码版本；
  真机双击可开；About = stable。
- 无凭据时：仍为 prerelease / preview|signed；**绝无**假 Latest；文档不再谎称拒发 ad-hoc。
- README / architecture 与 `release.yml` + 八门禁一致。
- UpdateCheck 不跨通道误升；ad-hoc 安装叙事不假装 Gatekeeper-ready。
- InstallTruth / LaunchRecovery 的 P1 项有单测或可手工验收路径。
- swift test + 八门禁 + version_check 对 0.53.0（发版时）。

## 明确不做

额度 HUD、托盘 approve/deny、扩 Agent、扩 hook 安装器越过 Claude/Codex、
远程账号、装饰动画、Figma 前置、伪造 Waiting、未公证标 stable / Latest。

## 顺序

P0-2 文档契约（可立即）→ P0-1 Apple secrets / 首个 stable（外部）→
P0-3 UpdateCheck / About 真机 → P1 InstallTruth / LaunchRecovery →
P1-3 QA 硬化 → P2 辅线 → CHANGELOG `## 0.53.0` / 发版。

## 无凭据时的收窄版

若发版窗口内 Apple secrets 仍缺席：

1. 仍以本主题发 0.53（文档 + 安装/更新/恢复连续性）。
2. CHANGELOG 明确写出「stable 工件 blocked on notarization」。
3. GitHub 继续 prerelease；不把主题改成扩 Agent 或再一轮 Observation。
