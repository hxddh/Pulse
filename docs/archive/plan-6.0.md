# 6.0 — Complete / 完成度（不开新轴，把 runtime 轴做完）

## 模式诊断（为什么连续四版都是半成品）

3.0 开窗口轴、4.0 开全文+送达轴、5.0 开 runtime 轴 —— 每版开新轴，每轴停在
v1 深度。顶尖产品不是比 Pulse 多几条轴，而是把「拥有会话」一条轴做到完成。
「不要走偏」= 6.0 不开新轴：全部工作落在 5.0 已建成的边界内
（SessionSource / worktree 命名空间 / Respond 纪律）。

5.0 受管会话对照顶尖产品的完成度缺口，按致命度排序：

1. **权限**：headless 静默拒掉未白名单工具 → 真任务跑不动。致命洞。
2. **持久化**：退 Pulse 即失忆，对话与会话全丢。
3. **并行编排**：一次派一个，无队列、无同题对比。
4. **worktree 里跑检查**：合并前无法验证。
5. **渲染深度**：工具调用/结果不配对，无每回合落盘快照。

## 三段走

### 6.0-α 舰队引擎（彻底重构本体：受管会话从 ad hoc 到受监督的持久实体）

- `ManagedFleet` 监督器：拥有全部 runner；**并发上限 + 队列**（默认同时 3，
  超出进 `queued` 状态成行排队，槽位空出自动开跑）。
- **持久化**：每会话一个状态文件（`Application Support/Pulse/managed/<id>.json`，
  0600 经 PrivateFile；含标题/根/claudeSessionID/完整对话/成本/token/状态）。
  写盘时机有界：回合起、回合终、取消、失败 —— 不逐流事件写。
- **重启重挂**：启动即读回全部会话；上次退出时正在跑的回合如实标
  `interrupted`（「回合被中断」，不冒充失败也不冒充完成）；`claudeSessionID`
  在，回复即 `--resume` 继续。
- 移除动词：已结束会话可移除（删状态文件；worktree 留给用户，路径明示 ——
  6.0 不代删 worktree）。
- 状态机新增 `queued` / `interrupted`，全部 switch 由编译器驱动更新。

### 6.0-β 权限通道（补致命洞）

- 每个受管回合注入 `--mcp-config <生成的配置> --permission-prompt-tool
  mcp__pulse__approve`：配置指向 **Pulse 自己的二进制** 以
  `--permission-server` 子命令跑一个最小 MCP stdio 服务（newline-delimited
  JSON-RPC：initialize / tools/list / tools/call）。
- tools/call(approve) → 写请求文件进权限 spool（0600；tool 名 + 完整 input
  JSON + 会话身份），**阻塞等待判决文件**；应用侧 DispatchSource 盯 spool，
  审批卡实时出现在该会话的检视器顶部。
- 审批卡走 Respond 的全部既有纪律：**完整请求原文**旁才有「同意」、拒绝永远
  可用、input 超界截断则 canOfferAllow=false、判决单次使用。
- 超时（120s）与任何失败 → **deny**（headless 没有厂商提示可回落，这里的
  fail-open 就是 fail-closed —— 放行才是不安全的那个方向）。
- 协议形状 fixture 钉死 + 未识别方法计数；官方文档薄弱是已知状况，qa 脚本
  加权限一步真机验证。

### 6.0-γ 完成度收口

- **同题 N 路**：派活面板并行尝试数（1–4），每路自己的 worktree/分支；
  同组会话在检视器互列（状态 + 落盘计数），一键切换对比 diff，选优后照旧
  提交/推送。
- **运行检查**：验收卡新增检查命令（每会话记忆、持久化），在 worktree 里跑
  （超时有界、退出码如实、输出尾部展示）—— 合并前先验证。
- **渲染深度**：tool_use 与 tool_result 配对缩进；每回合终了测一次 worktree
  落盘（`measure`，读-only），状态卡显示「本回合 +x −y」。
- 观察侧一个字节不动。

## 边界与脊柱

Waiting 唯一来源仍是 attention 协议（受管权限请求在指挥台呈现，v1 不点托盘
红灯 —— 与受管等待同一规矩，下版评估升格）；0600；能耗（spool 监听为
DispatchSource，轮询只在有未决请求的 200ms 窗口内）；命名空间门不变；
判断权一寸不转移。

## 交付与发布

用户已预授权：完成即直接发布 6.0.0（本版不再等「发布」口令）。真机验证脚本
扩到权限与队列两步；用户真机反馈优先于计划内一切工作。
