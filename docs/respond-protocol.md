# Respond Protocol v1 — 判决怎么走到另一台机器

Attention Protocol 把「远端在等你」带到这台 Mac；本协议把**你的回答**送回去。
两者共用同一个前提：**Pulse 不联网、不带服务器** —— 传输是用户自己的同步工具
（rsync、syncthing、挂载卷），Pulse 只读写本地文件。

信任模型先说清楚：attention 的最坏情况是假警报（烦人）；**判决的最坏情况是让
一台机器上的 Agent 执行了不该执行的动作**。所以这条通路与 attention 不同级：
逐 host 手动 opt-in、共享密钥 HMAC、单次使用、短过期、双绑定 —— 缺一即拒收，
一切失败都回落到厂商自己的提示（fail-open 对 Agent，fail-closed 对判决）。

## 目录布局

**远端机器**（跑 Agent 的那台，装 `pulse_hook.py`，`<pulse_dir>` 即
`PULSE_HOME` 或 `~/Library/Application Support/Pulse`）：

```
<pulse_dir>/respond-secret.key          # 存在且非空 = 该机器的 Respond 已 opt-in
<pulse_dir>/respond.d/requests/         # hook 写：完整权限请求（出方向，同步到 Mac）
<pulse_dir>/respond.d/verdicts/         # 同步工具送回来的判决（入方向）
```

**回答端 Mac**（Pulse.app）：

```
…/Application Support/Pulse/respond.d/secrets/<host>.key   # 与远端同一密钥
…/Application Support/Pulse/respond.d/requests.d/<host>/   # 同步进来的请求
…/Application Support/Pulse/respond.d/verdicts.d/<host>/   # Pulse 写的判决（同步回去）
```

同步方向的配置是用户的事；hook 与 Pulse 都只碰本地文件。文件一律 `0600`，
目录读取有界（≤16 host、每 host ≤32 文件、每文件 ≤256KB）。

## 请求文件

`requests/<request_id>.json`（`request_id` 进文件名前 sanitize：仅
`[A-Za-z0-9._-]`，其余替换为 `_`，≤120 字符）：

```json
{"v":1,"request_id":"toolu_x","agent":"claude","host":"devbox","session":"s1",
 "cwd":"/w","tool_name":"Bash","raised_at_ms":1,"expires_at_ms":2,
 "payload_b64":"<verbatim hook stdin 字节的 base64>",
 "digest":"<同一批字节的 sha256 hex>","truncated":false}
```

`payload_b64` 是厂商交给 hook 的 stdin **逐字节原文**。digest 在两端都对这批
字节重算 —— 规范化序列化的问题不存在，因为没有重新序列化。解码后 digest
不符 → 该请求按 `truncated` 对待，**永不出现「同意」**（拒绝与去看看不受限）。

## 判决文件

`verdicts/<request_id>.json`，由 Mac 端 Pulse 写：

```json
{"v":1,"request_id":"…","digest":"…","agent":"claude","host":"devbox",
 "allow":true,"decided_at_ms":1,"expires_at_ms":2,"hmac":"<hex>"}
```

HMAC-SHA256，密钥 = 密钥文件原始字节（去尾部换行），消息为规范串：

```
"v1\n" + request_id + "\n" + digest + "\n" + agent + "\n" + host + "\n"
       + ("allow"|"deny") + "\n" + decided_at_ms + "\n" + expires_at_ms
```

## 消费规则（远端 hook 侧，全部必须成立）

1. HMAC 常时比较通过（`hmac.compare_digest`）；
2. `request_id` 与 `digest` 与请求逐字相等（双绑定 —— 任一单独可被重放）；
3. `agent` 与 `host` 相等（防跨主机收集）；
4. 未过期（对钟差宽容 ±5 分钟，写在实现注释里）；
5. `allow` 还要求请求 `truncated == false`；
6. **恰好一次**：先 `rename` 成 `.used` 成功才允许使用 —— 同步工具重复投递
   同一份判决文件时，第二次 rename 失败即视为无判决。

任何一条不成立 → 当作没有判决，继续等或超时回落。**hook 对 Agent 永远
exit 0、超时不打印任何东西** —— 厂商提示照常弹出，最坏情况回到 1.0 的世界：
你得走过去。

实现钉死的细则（两端一致，改一边必须改另一边）：

- **判决文件名同请求一样 sanitize**（同一规则、两端同用）；
- 钟差宽容是对称的：`now < expires + 5min` 且 `decided − 5min ≤ now` ——
  未来判决与过期判决一样被拒；
- 厂商事件**没有 `tool_use_id` 就不 hold**（无稳定 id 无法绑定判决）；
- requests 与 verdicts 两个目录都受 64 文件上限（超出删最旧）；
- stdout 判决形状单押 2.1.233 二进制取证到的
  `hookSpecificOutput.decision.behavior` 对象形 —— 若某版本 CLI 只认文档里的
  字符串形，判决被静默忽略（fail-open，无害但功能失效），这正是真机剩余
  步骤第 2 条要确认的事。

## 与 Attention 的关系

请求文件不取代 attention raise —— 灯照常亮（TSV 照写）。Respond 只是让
「亮了之后」多一个动作。`attention-protocol.md` 声明过「能写收件箱 = 能点灯」；
本协议的等价句是：**能写 verdicts 目录不等于能批准任何东西** —— 没有密钥
算不出 HMAC，改过的请求对不上 digest，昨天的判决过了期，别台机器的判决
绑错了 host。
