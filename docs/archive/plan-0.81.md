# 0.81 计划 —— Tray Substance / 托盘实质

## 先说这份评估的局限

0.80 让观测行**画出来了**，但用户仍反馈「缺少有效信息」。根因下沉到
**harvest→行**：旗舰会话常无 model/tokens；次行在 tool-hero + 分组去路径时被压空；
`usefulAction` 白名单丢掉真实工具名。

无 Apple Developer ID → Stable Gate 仍外部 blocked；**不跳 1.0**。

**诚实前提：** 不伪造 Waiting / 进度占位；只展示真实 harvest 字段。

---

## 根因（相对 0.80）

| 问题 | 后果 |
| --- | --- |
| Claude `message.model` / `usage` 未稳进 Fact | 观测行空或仅 events |
| Codex 只读 `total_token_usage` | 有 `last_token_usage` 时 tokens=0 |
| Cursor `unifiedMode` 未读 + 默认 `local` | mode 被 readableMode 剥光 |
| tool-hero + `omitPath` | 次行只剩「最近活动」 |
| `usefulAction` 白名单 | LS/Task/Agent 等不上次行 |

---

## P0

| ID | 项 | 验收 |
| --- | --- | --- |
| P0-1 | Claude model+usage | fixture 含 message.model/usage → 行有 model+tokens |
| P0-2 | Codex last_token_usage | 优先 last，回退 total |
| P0-3 | Cursor unifiedMode | 读 unifiedMode/composerMode；不默认 local |
| P0-4 | 次行不塌 | omitPath 或 tool-hero 时仍保留路径或最近动作之一 |
| P0-5 | usefulAction | 凡人话标签非空即有用 |
| P0-6 | 场景 AA + 测试 | EXPERIENCE；Native + ResourceLookup |

### 明确不做

假 Waiting、stat strip、升格 cache→session、扩 hooks、假 1.0。
