# 2.0 计划 —— Respond / 回应

> **发布时拿到 2.0.0。** 这份计划曾两次改名（1.1 → 1.2 → 无号 plan-respond），
> 原因每次都一样：它阻塞于真机证据，而不阻塞的工作先发布了；「版本号发布时
> 才分配」的规矩正是它立下的，也在它身上兑现。地基随 1.0.1 落地，P0-0 证据的
> 主体于 2026-08-17 取得（见下），随后一版建成两端并发布。

## 这一版是 1.0 的后果，不是 1.0 的续集

1.0 之后 Pulse 能说出「devbox 上的 Claude 在等一个授权，已经等了 6 分钟」。然后你得
**ssh 过去**。

检测那一半做完之后，回应那一半的成本反而更刺眼：本机的等待切个窗口能答，远端的等待
要换一台机器。**1.0 让「看见」的边界消失了，「够得着」的边界就成了唯一的边界。**

所以这一版换的是**动词**：从「让你去看」到「让你回答」。

`EXPERIENCE.md` §1 的非目标写着「托盘内批准/拒绝 —— Pulse 让你去看，不替你做」。本版
**收窄**这条，不删除它：Pulse 仍然不替你判断，它只是把你的判断送达。判断权一寸都不转移
—— 见下方「明确不做」。

无 Apple Developer ID → 渠道仍是 `preview` / ad-hoc；**1.0 解绑的是版本号，不是签名承诺**。

---

## 通路已经通到正确的位置

`HooksInstaller` **已经**在 `PermissionRequest` 上注册了 Pulse：

```swift
ensureClaudeEvent(&hooks, event: "PermissionRequest",
                  command: hookCommand(agent: "claude", kind: "permission"), ...)
let hookBody = ["type": "command", "command": command, "timeout": 5]
```

也就是说 **Pulse 的代码此刻就在权限决定发生的那一瞬间被执行** —— 注意上面那个 `5`
是 Pulse 自己写进 settings 的超时，不是厂商的限制：厂商 hook 默认超时是 600 秒，
逐 hook 可配（见下方 P0-0 证据 Q4）。已装条目的 timeout 迁移是一项真实工作
（`ensureClaudeEvent` 见 marker 即跳过，现有安装不会自动提额）。
而 `PulseHookReceiver` 顶上写着：

> unknown kinds soft-fail (exit 0, no write) so vendor agents are never blocked

——它被**设计成永远沉默**。这不是要新建通路，是一条已经到位、但从不开口的通路。

加上 1.0 的收件箱：用户已有的同步工具本来就是双向的，`attention.d/` 进得来，决定就能
原路回去。**远端应答不需要新传输。**

---

## P0-0 · 阻塞项：真机验证厂商契约

**验证之前，一行「产生决定」的代码都不写。**

这不是谨慎，是 0.96.1–0.97.2 四连发的教训：没有真机证据就动解析等于抽奖。而这次抽错的
代价不是「主行显示错了」，是**批准了不该批准的东西**。

`scripts/qa_respond_contract.sh` 采集证据，它**只读、不批准任何东西、不碰全局设置**。
它要回答的问题：

| # | 问题 | 为什么它决定设计 |
| --- | --- | --- |
| Q1 | `PermissionRequest` 时 hook 的 stdin 到底收到什么？有没有**请求 id**、有没有**完整的工具入参**？ | 没有稳定 id 就无法把决定绑回具体请求；没有完整入参就**永远不能给「同意」按钮** |
| Q2 | hook 的 stdout 能否携带决定？schema 是什么？ | 决定这一版是「能回应」还是「只能拒绝并去看」 |
| Q3 | hook 超时（Pulse 当前装的是 5 s；厂商默认 600 s）之后发生什么：厂商自己弹提示，还是报错/中断？ | fail-open 是这套设计的底座；若超时不是干净回落，阻塞方案直接作废 |
| Q4 | `timeout` 可否调大？上限多少？调大后在场用户看到什么？ | 人需要的是几十秒，不是 4 秒 |
| Q5 | 入参是否被截断？大 diff / 长命令怎么表示？ | 直接决定「同意」按钮的出现条件 |

**Q2 若为否，本版的产品形态就变成「一键拒绝 + 去看看」**，而不是完整应答。那也是一个
诚实且有用的版本，但必须由证据来决定，不能由期望来决定。

### P0-0 · 证据·第一份（2026-08-17，容器取证）

> **来源与证据等级，先说清楚。** 取证环境是一个装有 Claude Code **2.1.233** 的 Linux
> 容器，不是用户的 macOS 真机。该环境下嵌套 Claude 走 SDK 权限回调
> （transcript 标注 `entrypoint: sdk-cli`），交互式权限对话路径无法端到端复现。
> 因此下面的答案分两个等级：**[binary]** = 从该版本正在发行的 CLI 二进制中提取的
> 实际代码路径（比文档强 —— 它就是会执行的东西；比真机观察弱一档）；
> **[live]** = 本容器实测。真机剩余步骤见后。

| # | 答案 | 证据 |
| --- | --- | --- |
| Q1 | **有稳定 id，有完整入参。** stdin JSON 携带 `tool_name`、完整 `tool_input`、`tool_use_id`、`permission_suggestions`，外加通用信封 `session_id` / `cwd` / `permission_mode` / `transcript_path` | [binary] hook 输入构造：`{..., hook_event_name:"PermissionRequest", tool_name, tool_input, permission_suggestions}`；事件表描述原文 "Input to command is JSON with tool_name, tool_input, and tool_use_id"。[live] 通用信封字段在同机 UserPromptSubmit 捕获中实测确认 |
| Q2 | **能。stdout 可携带判决，且用户自己的 deny/ask 规则覆盖 hook 的 allow。** 2.1.233 消费的形状是 `hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow"\|"deny", updatedInput?, updatedPermissions?, message?, interrupt? } }`；官方文档另载 `decision: "approve"\|"deny"` 字符串形。真机探测两种形状都试 | [binary] 消费代码：`case"PermissionRequest": if(hookSpecificOutput.decision){ permissionBehavior = decision.behavior==="allow" ? "allow" : "deny" … }`；allow 路径产出 `decisionReason:{type:"hook",hookName:"PermissionRequest"}`，deny 路径产出 "Permission denied by hook"；规则覆盖：`"PermissionRequest hook allowed … but deny/ask rule overrides"` —— **判断权不转移在厂商侧有第二道保险** |
| Q3 | **干净回落。** headless 路径整体 try/catch，hook 失败仅记日志、返回 null、走厂商自己的权限流程。fail-open 底座成立 | [binary] `catch(s){ log("PermissionRequest hook failed for headless agent: …") } return null`，随后落到 "Action requires interactive approval…" 的默认拒绝/正常提示 |
| Q4 | **可调，且「5 秒预算」是个误会。** 厂商 hook 默认超时是 **600 秒**（binary 常量 600000ms）；Pulse settings 里的 `timeout: 5` 是 `HooksInstaller` 自己写的。逐 hook `timeout` 字段被尊重。「让 Agent 等几十秒」没有厂商侧障碍。**hold 期间在场用户看到什么 UI，仍需真机**（见剩余步骤） | [binary] hook 执行默认 `timeoutMs = 600000`；per-hook timeout 来自 settings 条目 |
| Q5 | **无截断机制。** `tool_input` 作为完整 JSON 对象经 stdin 全量写入 hook；未发现任何按大小截断的代码路径。极端大 diff 的实测留给真机 | [binary] stdin 写入的是完整 hook input 对象的序列化 |

**结论：最悲观的分支（Q2=否 → 缩为「一键拒绝」）排除。可以按「完整应答」立项。**

**真机剩余步骤**（收窄后的 P0-0，约 30 分钟）：
1. 确认用户机器的 CLI 版本 ≥ 含 `PermissionRequest` 事件的版本（老版本装了 hook
   永不触发 —— 静默无害，但前提塌掉）；
2. 交互模式下实测 stdout 判决被采纳（两种形状各试一次：`decision.behavior` 对象形
   与 `decision: "approve"` 字符串形）；
3. hold 期间在场用户的 UI 观感（Q4 后半）；
4. 超大 `tool_input`（长 diff）实测（Q5 收尾）；
5. `Notification(permission_prompt)` 与 `PermissionRequest` 的触发顺序/重复关系。

---

## 三个真正的难点（都不是管线）

### 一、谁在等 —— 人还是 Agent

人看懂一个权限请求并决定，需要几十秒。厂商侧没有障碍 —— hook 默认超时 600 秒，
逐 hook 可配（P0-0 证据 Q4；此前这里写的「厂商 timeout 是 5 秒」是个误会，那是
Pulse 自己装的值）。所以「让 Agent 等你」技术上成立，剩下的是纯产品取舍：

让 Agent 等的代价是真的：**你就坐在那台机器前面时，Agent 会先冻住 N 秒再弹出它自己的
提示 —— 对在场用户是纯粹的倒退。**

默认取舍：**只有在你显然不在场时才让 Agent 等**（远端 raise，或本机输入空闲超过阈值）；
在场就立刻放行给厂商自己的提示。「Agent 最多等我多久」是用户设置，像停滞阈值一样，
不是我替他定的常数。

Pulse 目前没有输入空闲检测，这是新增的一小块能力（`CGEventSource` 的环境空闲时间，
不需要 TCC，不读按键内容）。

### 二、你会批准一件没读全的事

托盘上是一条 ≤200 字的消息。对着截断的工具调用点「同意」，正是 0.90–0.99 一直在杀的
那种「看起来验证过、其实没有」。

**Pulse 拿不到完整请求时，不给「同意」按钮** —— 只给「拒绝」和「去看看」。
拒绝永远是安全的，同意才是危险的那一半；两者不该享受同样的门槛。

### 三、信任面发生等级跃迁 ← 本版的设计中心

| | 能写入的人的最坏后果 |
| --- | --- |
| 1.0（已发布） | 让你的灯变红 —— 假警报，烦人 |
| Respond（本计划） | **代你批准一次工具调用** —— 在跑 Agent 的机器上执行任意动作，还是经由你自己的权限系统洗过的 |

**这不是同一类风险。** 因此：

- 决定只由 Pulse 应用进程产生，写在它自己的容器里、`0600`，**默认绝不落进同步目录**。
- **远端应答默认关闭**，逐 host 手动开启，且需要用户自备共享密钥做 HMAC。否则
  「同步目录」等于「任何有该目录写权限的人都能替你批准」。
- 决定**单次使用、短过期、同时绑定 request id 与请求内容摘要**。否则一份留在盘上的
  「允许」会去回答一个未来的、长得像的请求。

---

## 逐项清单

### P0 · 必须完成

| ID | 项 | 验收 | 状态（2026-08-17） |
| --- | --- | --- | --- |
| P0-0 | **真机契约证据** | `qa_respond_contract.sh` 在装了 Claude 的机器上跑完，Q1–Q5 有答案贴回本文件 | **主体已闭**（见上方证据节）；剩真机交互确认清单，其中第 2 条（stdout 判决形状被采纳）是发布前必须 |
| P0-1 | 可达性诚实 | `AgentID.respondReach`：`.hookSite`（Pulse 在决定点被执行）/ `.none`。**被执行 ≠ 能答复** —— 类型文档与门禁都必须这么说 | 已完成（1.0.1） |
| P0-2 | 决定模型 | 请求与判决的纯模型：绑定升级为**四重**（id + 内容摘要 + agent + host）、单次使用、过期；`canOfferAllow` 仅在完整请求可见时为真；拒绝无此限制 | 已完成（host/agent 绑定本版补齐） |
| P0-3 | 送达通路 | [`respond-protocol.md`](respond-protocol.md)：请求/判决 spool 文件、HMAC、`.used` 恰好一次、fail-open；远端 hold 端在 `pulse_hook.py`，由 `scripts/respond_hook_check.py`（CI 门禁，44 断言）实跑钉死 | **已建成** |
| P0-4 | 阻塞策略 | **本机永不 hold**（在场时厂商提示更好，缺席时无人可答）；远端 hold = 密钥文件存在即 opt-in，上限 `PULSE_RESPOND_MAX_HOLD_SECONDS`（默认 60s，钳 [5,300]） | **已定死并实现** |
| P0-5 | 远端应答 | 默认关闭；逐 host 密钥文件 opt-in；HMAC 常时比较；判决只落 Pulse 自己的 `respond.d`，同步方向由用户配置 | **已实现**（首个真实同步环路的实测仍在真机清单里） |
| P0-6 | 场景 + 测试 | EXPERIENCE **场景 AR**；`RespondFoundationTests` + `RespondSpoolTests` + `StatusStoreRespondTests` + `respond_hook_check.py` | 已完成 |
| P0-7 | 交付物 | plan；CHANGELOG；semver；门禁；草稿 PR；**等「发布」** | 本 PR |


### 明确不做

| 项 | 理由 |
| --- | --- |
| **规则引擎 / always-allow / 自动批准** | Pulse 一旦记住「这个项目里的 `rm` 一律放行」，它就从灯变成策略引擎，而一条错规则的伤害无上限。**用户一定会要这个功能 —— 不给。** |
| 替你判断 | 本版转移的是**送达**，不是判断。没有推荐、没有默认选项、没有「Pulse 认为可以」 |
| 扩到 32 个 Agent | 只有在决定点真的执行到 Pulse 的才有资格；其余诚实标「仅观测」 |
| 假 Waiting、cache→session、统计大盘、上传遥测、跳过 1.0 的渠道诚实 | 一律不变 |

---

## 1.0.1 落了什么（历史记录 —— 当时这份计划还叫 1.1）

**没有任何「能回应」的功能落地，这是有意的。** 落的是不依赖未验证契约的部分：

| 项 | 状态 |
| --- | --- |
| P0-0 证据采集脚本 | 已完成 —— 只读、不批准、不碰全局设置 |
| P0-1 `respondReach` + 门禁 | 已完成 |
| P0-2 决定模型与规则（纯函数 + 测试） | 已完成 |
| P0-4 的在场判定函数 | 已完成（策略本身仍待 P0-0） |
| P0-3 送达通路 | **空 —— 阻塞于 P0-0** |
| P0-5 远端应答 | **空 —— 阻塞于 P0-0** |

我的建议是**不发**：一个用户看不见任何新能力的版本，不该占一个版本号。

**这条建议被否决了，我按用户的决定发了 1.0.1。** 采用补丁号而不是 1.1，是为了让版本号
本身不撒谎：1.1 是「能回应」，而这一版不能。CHANGELOG 第一句就写明装上去看不到新东西。

P0-3（送达）与 P0-5（远端应答）仍然空着，仍然阻塞于 P0-0。

---

## 为什么是这个顺序

P0-0 排第一并阻塞两项，因为它决定的不是「怎么做」，是「做什么」——Q2 若为否，整版
从「应答」缩为「一键拒绝 + 去看看」。先建模型与可达性，是因为它们无论 Q2 答什么都成立，
而且模型里那三条规则（双绑定、单次、过期）是**唯一能让一份决定不被重放到另一个请求上**
的东西 —— 那是这一版风险等级跃迁之后的地基。
