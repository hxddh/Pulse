# 2.4 计划 —— Answer Here / 就地回答

## 一件事：把 2.0 已经交付的动词变化，交到只有一台 Mac 的人手上

2.0 把「看见 → 走过去」换成了「看见 → 就地回答」。那是产品到目前为止**唯一一次
动词变化**，而它在单机上**完全无法触发**。

---

## 现状：三处独立地把本机排除在外

| 位置 | 现状 |
| --- | --- |
| `RespondSpool.readInboundRequests` | 只读 `respond.d/requests.d/<host>/`。本机 hook 写的是扁平的 `requests/`，**App 从不读它**（只有 `cleanupOutbound` 去删） |
| `RespondSpool.writeVerdict` | `guard !verdict.host.isEmpty` —— 「An empty host is a local decision; the spool exists for machines that are not this one.」 |
| `StatusStoreRespond.matchRespondInbound` | `guard row.observationSource == .remote` |

而且 `RespondHold.shouldHold` 把它写成了规则：

```swift
guard idleSeconds < awayAfterSeconds else { return false }  // 没人在，留着给谁看
return isRemote                                             // 本机：厂商提示已经在他面前了
```

hook 那侧（被 hold 的机器）用的是相反条件（`idleSeconds >= awayAfterSeconds` 才
hold）。两台机器上各自都对；**同一台机器上这两个条件互斥** —— 单机 Respond 不是没做，
是被构造成不可能。

## 要改的是那条规则的**理由**

原话：「The vendor's prompt is already in front of the user on this machine.
Pulse has nothing better to offer.」

**「有人在碰这台 Mac」不等于「那个提示在他眼前」。** `idleSeconds < 120` 只说明你在动
键鼠。而 EXPERIENCE §1 的头号场景就是「**开会 / 写文档时**不切终端也知道有人在等我」——
那个场景里你正在动键鼠（`isPresent` 为真），同时六个终端窗口在全屏 App 后面，厂商
提示恰恰**不在**你眼前。**这条规则在产品自己写下的头号场景里，判断是反的。**

Pulse 有比 HID idle 精确得多的信号可用：**最前台的 App 是不是这次请求的祖先进程**。
hook 是 agent 的子进程，agent 是终端 / IDE 的子进程；沿 ppid 链上溯，与
`NSWorkspace.frontmostApplication` 的 pid 比对即可。不需要新权限，不碰 TCC，不认
App 名单 —— Warp / iTerm / Terminal / VS Code / Cursor 一视同仁。

---

## 判断门（新）

```
hold 当且仅当：
    idleSeconds >= awayAfterSeconds              // 没人在（今天的规则，不变）
  或 前台 App 已知 且 不是本 hook 的祖先进程      // 人在，但看的是别处
不 hold：
    前台 App 是祖先（提示马上出现在他眼前）
    前台 App 未知 且 人在                        // 回落到今天的行为
```

**取值来源与失败方向**

| 输入 | 来源 | 拿不到时 |
| --- | --- | --- |
| `idleSeconds` | `UserPresence.idleSeconds`（`CGEventSource`，仅事件年龄，不含内容） | 0（视为在场） |
| 前台 App pid | `NSWorkspace.shared.frontmostApplication?.processIdentifier` | nil → 视为「未知」 |
| 祖先链 | `sysctl(KERN_PROC_PID)` 逐级取 `e_ppid`，上限 16 级 | 空链 → 视为「未知」 |

**失败一律倒向「不打扰」**：判断不出来就不 hold。在场时多冻 agent 一秒都是净损失，
这条不能靠自觉，要有测试钉死。

**刻意保守的一处**：前台是终端、但请求来自后台标签页时，仍然算「在你眼前」，不
hold。窗口 / 标签级的可见性要么要 Accessibility 权限，要么不可靠，两条都不走。

---

## 本机请求与本机判决怎么走

hook 侧一个字节都不改流向：照旧写 `respond.d/requests/<id>.json`、照旧等
`respond.d/verdicts/<id>.json`。变的是**谁来回答**。

| 步骤 | 做法 |
| --- | --- |
| Pulse 读本机请求 | 新增 `readLocalRequests(nowMs:)` 读扁平 `requests/`；同一套有界规则（≤32 文件、≤256KB/文件、超期跳过、digest 不符即 `truncated`） |
| 认领到行 | 本机请求只挂**本机行**（`observationSource != .remote`），按 agent + session 匹配；远端请求的规则一个字不动 |
| 写本机判决 | 写扁平 `verdicts/<id>.json`，0600，先写临时文件再原子 rename —— 与远端判决同一形状 |
| 签名 | 用**本机密钥** `respond-local.key`（Pulse 自动生成，32 随机字节，0600），不是逐 host 密钥 |
| hook 验证 | `claimVerdict` 依次用「逐 host 密钥」与「本机密钥」验，任一通过即接受 |

### 为什么本机判决也要签名

`verdicts/` 正是双机场景里**被同步进来**的那个目录。如果这里接受未签名的文件，一个被
攻破的同步共享就能注入一个未签名的 allow —— **那会削弱远端路径**。

本机密钥从不离开这台机器，所以同步共享里的文件永远签不出它；逐 host 密钥仍然是原来的
信任锚。两把钥匙都验，安全性质原封不动。而对一个已经能读到这把钥匙的攻击者来说，他
早就能以你的身份直接跑 agent 了 —— 这把钥匙没有新增任何东西可偷。

### 为什么是 opt-in

现有设计里 Respond 的开关就是「密钥文件在不在」。本机沿用同一形状：

- 偏好设置里一个开关，**默认关**。打开时生成 `respond-local.key`，关闭时删除它。
- hook 的规则不变：**没有钥匙，不 hold**。所以没打开的人，agent 行为一个字节都不变。
- 这也是唯一的 kill switch：判断门万一有 bug，关掉开关立刻回到今天。

---

## 逐项清单

### P0 · 判断门

| ID | 项 | 验收 |
| --- | --- | --- |
| A-1 | 祖先链 | 纯函数：给定 (自身 pid, 前台 pid, ppid 映射) 判定是否祖先；自环 / 环路 / 超 16 级一律判「未知」而不是死循环 |
| A-2 | `RespondHold` 换判断依据 | 「人在 + 前台是祖先」→ 不 hold；「人在 + 前台不是祖先」→ hold；「人不在」→ hold；「前台未知 + 人在」→ 不 hold。四种组合各一条测试 |
| A-3 | hook 接线 | `respondDecisionJSON` 用新门；`NSWorkspace` 取不到前台时不 hold；autoclosure 保证只有便宜的守卫都过了才去问系统 |
| A-4 | 远端不受影响 | 远端 Mac 上的 hook 行为与 2.3 逐字节一致（它的前台永远不是本 hook 的祖先，除非 agent 真在那台机器的前台跑） |

### P0 · 本机回答

| ID | 项 | 验收 |
| --- | --- | --- |
| B-1 | `readLocalRequests` | 扁平 `requests/`；有界；`isLocal` 标记；host 必须等于本机 host，否则跳过 |
| B-2 | 本机行认领 | 本机请求只挂本机行；远端请求仍只挂远端行；两者不互串 |
| B-3 | 本机判决写入 | 扁平 `verdicts/`，本机密钥签名，0600 + 原子 rename |
| B-4 | `claimVerdict` 双钥 | 逐 host 密钥或本机密钥任一验过即接受；两把都没有 → 拒绝；未签名 → 拒绝 |
| B-5 | opt-in 开关 | 偏好设置开关 ⇄ `respond-local.key` 的存在；关掉即刻停止 hold |
| B-6 | 通知上直接拒绝 | Waiting category 增一个「拒绝」action，仅在该行确有匹配请求时出现；「同意」**永不**上横幅 |

### 明确不做

| 项 | 理由 |
| --- | --- |
| 自动批准 / 规则引擎 / always-allow | 判断权一寸不转移，`AGENTS.md` 不变量 |
| 横幅上的「同意」 | 横幅装不下完整请求，`canOfferAllow` 的纪律就是「看不全不给同意」 |
| 默认开启本机 hold | 改变 agent 行为的东西必须是用户点开的 |
| 窗口 / 标签级可见性 | 要 Accessibility 权限或不可靠，两条都不走；宁可保守判「在你眼前」 |
| 把 hold 时长调长 | 60s 上限不动。人在但看别处的场景里，答不上来就该回落厂商提示 |
| 托盘之外的新表面 | 还是那一行 + 已有通知 category + Details 的完整请求区 |

---

## 先决门槛

1. **`plan-2.0` P0-0 剩余的真机确认**（约 30 分钟）。本机路径把 hold 从「双机用户的
   偶发路径」变成日常路径，地基必须验完 —— 这次躲不掉。
2. **S2（StatusStore 拆分）**：1.2 时 4548 行，2.2 时 4896，2.3 又动了 +215/−119。
   本机判决要再加「在场判断 + 本地判决写入 + 通知 action 回调」。本版至少把 Respond
   相关状态从 `StatusStore` 拆进 `StatusStoreRespond` 已有的边界里。
3. S1（声明式 adapter 契约）优先级仍低于 S2，继续挂着。
