# Swai (Shuwei HShell) Agent 架构迁移至 DeepSeek Harness (DSH) 方案设计

## 1. 架构愿景与背景
当前 Swai 项目拥有业界独创的 **HarmonyOS NEXT 本地 `hdcd` 回环特权通道（uid=2000 shell）**，并在此基础上构建了全套完整的真·UI 自动化工具（`UiTool`）、本地离线计算沙箱（`RunCodeTool` - CPython 3.13 / V8 JSVM）以及远程桌面级卸载工具（`RemoteBashTool` - 原生 SSH-2.0）。

然而，当前应用层 Agent 逻辑完全由 ArkTS 手工维护（`AgentLoop.ets`, `SystemPromptAssembler.ets`, `ContextCompactor.ets`, `TicketEngine.ets`），存在以下维护与演进痛点：
1. **模型能力与上下文治理脱节**：官方 DeepSeek Harness (DSH) 拥有专门针对 DeepSeek 模型的长上下文压缩、思维链（Thinking）流式解析、渐进式 Prompt 组装与容错重试机制；
2. **多智能体演进孤岛**：Swai 自研的 TicketEngine 与开源主流 Multi-Agent / Swarm 协议脱节；
3. **扩展生态闭塞**：无法直接复用 DSH 官方以及开源社区沉淀的丰富 MCP 工具和标准 Skills。

本方案旨在**将 Swai 当前的 Agent 核心引擎全面切换到 DeepSeek Harness (DSH)**，同时**100% 完整保留并发挥 Swai 现存的所有核心特权工具**。

---

## 2. 核心架构决策矩阵（基于 /grill-me 访谈结论）

| 决策维度 | 确定的选型方案 | 核心理由与技术依据 |
| :--- | :--- | :--- |
| **运行时拓扑** | **进程内嵌 Node.js (`libnode.so`, `--jitless`) + DSH 引擎** | 参考 dsh-Go 实践，保证 Agent 拥有 DSH 原生思考与调度能力，避免自研 ArkTS 复刻版的功能滞后 |
| **工具桥接通道** | **“Cordis 插件 + C ABI (dlopen) + N-API 状态机”** | 进程内零网络损耗，严格绕过鸿蒙禁止 `fork/exec` 限制，支持原子取消、前后台生命周期锁 |
| **工具职责划分** | **分层融合** | 标准文件操作（`read/write/edit`）使用 DSH 内部高效 Node fs；特权工具（`ui`, `bash`, `run_code`, `remote_bash`）由 Swai 接管，DSH 的 `bash` 直接路由给 Swai 的 HDC uid 2000 |
| **多智能体架构** | **彻底替换为 DSH 原生 Subagent / Swarm** | 废弃 Swai 冗余的 `superagent/` 和 `TicketEngine`，全面拥抱 DSH 原生子智能体与会话路由 |
| **前后端通讯** | **本地 Loopback HTTP REST + WebSocket (`$events`)** | 与 DSH 官方协议完全一致，ArkTS 前端作为标准客户端接入，打字机流式渲染与状态展示稳定解耦 |
| **技能与记忆** | **全面遵循 DSH SKILL.md 与 Memory 规范** | 废弃 ArkTS 冗余的 Skill/Memory 解析器，将现有技能目录统一为 DSH 标准 `SKILL.md` 规范 |

---

## 3. 总体系统架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          HarmonyOS NEXT 进程空间 (Swai)                     │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                    ArkTS 前端界面 (Index.ets / FloatPanel.ets)        │  │
│  │    (聊天界面、悬浮窗控制面板、打字机流式输出、Thinking 思维链折叠渲染)       │  │
│  └───────────────────▲───────────────────────────────────▲───────────────┘  │
│                      │                                   │                  │
│     1. 本地回环连接 (HTTP / WebSocket)          3. N-API 状态机驱动 (特权工具)│
│                      ▼                                   ▼                  │
│  ┌───────────────────────────────────────┐  ┌────────────────────────────┐  │
│  │       libnode.so 独立线程             │  │   libswshell.so 原生宿主   │  │
│  │                                       │  │   (CMake + C++17)          │  │
│  │  ┌─────────────────────────────────┐  │  ├────────────────────────────┤  │
│  │  │ DeepSeek Harness 官方引擎        │  │  │ DshHostState 状态机        │  │
│  │  │ (@deepseek-ai/dsh)              │  │  │ 维护 engineId / 租约 / 队列│  │
│  │  │  - Agent Loop / Context Compactor│  │  ├────────────────────────────┤  │
│  │  │  - Subagents / Swarm            │  │  │ C ABI: dsh_host_swai_v1    │  │
│  │  │  - Standard Filesystem Tools    │  │  │ (dlopen 直连供 Node 插件)  │  │
│  │  └─────────────────▲───────────────┘  │  └────────────▲───────────────┘  │
│  │                    │                  │               │                  │
│  │  ┌─────────────────┴───────────────┐  │               │                  │
│  │  │ Cordis 插件: swai-bridge-plugin │──┼───────────────┘                  │
│  │  │ 将 DSH bash / ui / run_code 映射│  │                                  │
│  │  │ 到 C ABI 状态机                 │  │                                  │
│  │  └─────────────────────────────────┘  │                                  │
│  └───────────────────────────────────────┘                                  │
│                                                          │                  │
│                                            4. 调用真实特权工具              │
│                                                          ▼                  │
│                                  ┌───────────────────────────────────────┐  │
│                                  │    Swai 核心特权能力执行中心          │  │
│                                  │ - UiTool: uitest 布局解析 + uinput点击│  │
│                                  │ - BashTool: 本机 hdcd (uid=2000 shell)│  │
│                                  │ - RunCodeTool: 本地 CPython 3.13 静态库│  │
│                                  │ - RemoteBashTool: 原生 SSH-2.0 远程执行│  │
│                                  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 详细模块设计与改造方案

### 模块一：Native 宿主管理与 Node 嵌入（C++ / N-API）
1. **编译集成 `libnode.so`**：
   - 引入针对 `aarch64-linux-ohos` 构建的 `libnode.so`；
   - 在 C++ 宿主层（`napi_init.cpp`）提供 `dshNodeStart(options)` 与 `dshNodeStop()` 导出给 ArkTS；
   - 内部创建独立 `std::thread`，以 `--jitless` 启动 Node 实例。
2. **标准输出管道捕获（Stdout Redirection）**：
   - 使用 `pipe` + `dup2` 截获 Node 的标准输出；
   - 捕获 `dsh web: http://127.0.0.1:<port>/?token=<token>`，解析随机动态端口与握手 Token；
   - 将 `ready` 事件通过 N-API 回调给 ArkTS 前端。
3. **C ABI 状态机（`swai_state.h`）**：
   - 导出 `dsh_host_swai_v1` C ABI 符号；
   - 维护线程安全的调用队列，提供 `Claim`（认领）、`Consume`（消费）、`Finish`（完成）操作，支持 30 秒默认超时与前后台门禁。

### 模块二：DSH 动态补丁与 Cordis 插件（Node.js 端）
1. **DSH 启动补丁配置 (`swai-host.patch.json`)**：
   - 禁用默认的桌面端 `subprocess` 和 `sandbox`；
   - 注入定制插件：
     - `swai-subprocess`: 拦截所有 Shell 命令，经由 C ABI 转发至 Swai 的 `hdcd` 通道；
     - `swai-ui`: 注册 `ui` MCP 工具，透传至 Swai `UiTool`；
     - `swai-runcode`: 注册 `run_code` MCP 工具，透传至 Swai 本地 CPython 3.13 引擎；
     - `swai-remotebash`: 注册 `remote_bash` MCP 工具，透传至 Swai 的原生 SSH 客户端。

### 模块三：工具层适配与桥接映射（ArkTS 端）
保留并重构当前 `entry/src/main/ets/agent/tools/`：
* **`UiTool.ets`**：保持其完整的布局抓取（`dumpLayout`）、视觉语义计算（`VisualAffordanceEngine`）、端侧 OCR 兜底（`PhoneOcr`）以及 `uitest/uinput` 自动化点击与中文输入能力不变。
* **`BashTool.ets`**：保持与本机 `hdcd` 的回环通信（`BridgeController.getInstance().exec`），以 `uid 2000` 执行宿主命令。
* **`RunCodeTool.ets`**：保持纯原生 CPython 3.13 静态库执行通道。
* **`RemoteBashTool.ets`**：保持原生 SSH-2.0 执行通道。
* **桥接调度器（`SwaiToolBridge.ets`）**：
  - 监听 C++ 状态机的任务事件；
  - 根据工具名称（`ui` / `bash` / `run_code` / `remote_bash`）路由至对应执行器；
  - 执行完毕后将 JSON 结果写回状态机。

### 模块四：代码清理与降冗（Retire & Clean）
切换到 DSH 原生架构后，清理 ArkTS 侧自研的冗余逻辑：
* **移除** `entry/src/main/ets/agent/harness/`（`AgentLoop.ets`, `SystemPromptAssembler.ets`, `ContextCompactor.ets`, `OutputTruncator.ets`）；
* **移除** `entry/src/main/ets/agent/LlmClient.ets`（由 DSH 核心通信层全权负责）；
* **移除** `entry/src/main/ets/agent/superagent/`（废弃自研 `TicketEngine`、`WorkerSession`，改为 DSH 原生 Subagent / Swarm）；
* **迁移** `entry/src/main/ets/agent/skills/`（现有 Prompt Skills 直接重构为符合 DSH 标准的 `SKILL.md` 文件放在工作区）。

### 模块五：ArkTS 前端连接与界面重构
* 在 `Index.ets` 和 `FloatPanel.ets` 中引入轻量级 WebSocket 客户端（可基于鸿蒙 `@ohos.net.webSocket`）：
  - 连接 `ws://127.0.0.1:<port>/$events?token=<token>`；
  - 实时接收 `thinking` 事件渲染折叠思维链；
  - 实时接收 `token` 流驱动打字机效果；
  - 监听 `tool_call` 事件更新悬浮窗当前动作状态（如“正在读屏”、“正在输入中文”）。

---

## 5. 实施路线图（Milestones）

| 阶段 | 核心任务 | 验收标准 |
| :--- | :--- | :--- |
| **M1: 引擎启动与双向握手** | 引入 `libnode.so`，编写 C++ `HostCore` 启动管理，实现 stdout 端口/Token 捕获与 ArkTS WebSocket 连接 | ArkTS 前端成功通过 WebSocket 连上内嵌 DSH，完成第一句 Hello World 对话 |
| **M2: C ABI 与特权工具桥接** | 编写 `swai_state.h` 状态机，开发 Node Cordis 插件，打通 `BashTool` (HDC) 与 `UiTool` | DSH 能成功调用 `ui` 工具抓取屏幕布局并完成一次自动化点击 |
| **M3: 全套工具接入与代码降冗** | 接入 `RunCodeTool` (CPython) 与 `RemoteBashTool`；移除旧版 `AgentLoop`、`superagent/`、`LlmClient` | 全部 4 大特权工具在 DSH 调度下稳定运行，工程无孤立遗留代码 |
| **M4: 前端交互与悬浮窗深度集成** | 悬浮窗 `FloatPanel.ets` 适配 DSH 事件流，支持 Thinking 折叠、一键中断/停止会话、实时进度更新 | 悬浮窗面板能流畅展示 DSH 推理过程并在 UI 自动化期间自动避让 |
| **M5: 真机综合验收与鲁棒性加固** | 真机压测、前后台切换生命周期防悬挂、网络断线重连测试 | 在 HarmonyOS NEXT 真机上平稳执行长链条复杂任务 |
