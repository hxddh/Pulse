# 0.61 计划 —— Hook Autonomy / 原生等待通路

## 先说这份评估的局限

0.55–0.60 闭环了观测 Continuity。本版换轴：**Claude/Codex 金标准 Waiting
不再依赖 optional Python** —— install / self-test / 写入与 native harvest 同级。
不扩 hook 安装器越过 Claude/Codex；不碰 Stable Gate / composer 深链 / 1.0。

无 Apple Developer ID → Stable Gate 仍外部 blocked。

**诚实前提：**

- 不扩 Agent；不扩 hooks 越过 Claude / Codex。
- 不伪造 Waiting；托盘无 approve/deny；无额度 HUD。
- 已装 `pulse_hook.py` 的用户不打断；可迁移到原生 `pulse-hook`。
- Builder 保持纯；Attention 0.60 身份门闩保留。

---

## 逐项清单（验收时逐一比对）

### P0 · 必须完成

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | 原生 hook 写入器 | `PulseBar --hook` + Application Support `pulse-hook` launcher；flock/TSV = AttentionIO |
| P0-2 | install 不依赖 Python | Swift 改 Claude settings / Codex config；无 Python 成功 |
| P0-3 | self-test 不依赖 Python | 进程内 / launcher 自检；无 Python 绿 |
| P0-4 | 兼容旧 Python hook | probe 认 `pulse-hook` 与 `pulse_hook.py`；uninstall 清两者；seed 仍带 py |
| P0-5 | EXPERIENCE 场景 T + 文档 | 无 Python 的 Mac，Claude 仍能红灯 |

### P1 · 显著提升

| ID | 项 | 验收 |
| --- | --- | --- |
| P1-1 | First-run 文案 | hooksHint / Support：安装无需 Python |
| P1-2 | Bridge 原生 raise | samples 优先调 `pulse-hook`；Attention 样本路径保留 |
| P1-3 | Live stall 线索 | 停滞行次要文案点出「无活动」时长，不发明 Waiting |
| P1-4 | 回归 | Attention 身份、pending、Waiting-none、Focus |

### P2 · 收口

| ID | 项 | 验收 |
| --- | --- | --- |
| P2-1 | Stable Gate 插队 | CHANGELOG：无 Apple ID 不切 stable |
| P2-2 | 能量预算 | hook 路径不加深 harvest walk |

### 明确不做

额度 HUD、托盘 approve/deny、扩 Agent、扩 hooks、伪造 Waiting、假 stable、
composer 深链、SIGKILL helper、扫描期 Apple Events。

---

## 顺序

P0-1 AttentionIO/PULSE_HOME + PulseHookReceiver → P0-2/3 native install/self-test →
P0-4 compat → P1 → 场景 T → 0.61.0。
