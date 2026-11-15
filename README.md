# Swai (枢维智能 · 个人智能体)

> **面向 HarmonyOS NEXT 的下一代个人智能体助手与端侧自动化平台**  
> Next-Generation Personal AI Agent & Automation Platform for HarmonyOS NEXT

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-NEXT%205.0%2B-0A59F7?style=flat&logo=huawei)](https://developer.huawei.com)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Architecture](https://img.shields.io/badge/Architecture-In--Process%20DSH%20Harness-green.svg)](#-架构概览-architecture)

---

## 🌟 项目简介 (Overview)

**Swai**（取自 **S**hu**w**ei + **AI**，发音同 `/sweɪ/`）是由**枢维智能**团队自主研发、深度适配华为 **HarmonyOS NEXT** 的端侧个人专属智能体助手。

不同于普通的问答式聊天机器人，**Swai** 是一个具备**真实端侧执行能力**、**长上下文规划思维**与**跨应用自主协作**的生产力伴侣：
- 🤖 **内置 DeepSeek Harness (DSH) 原生引擎**：支持全流程思维链（Thinking Process）透传与自主工具编排。
- 🌐 **画中画悬浮小窗 (Floating Picture-in-Picture)**：随时伴随多任务并行，支持 1:1 边缘手势拖拽与微型胶囊贴边收起。
- 📱 **跨应用智能自动化**：自动化执行网页浏览、信息提取、微信公众号文章排版与草稿生成。
- 💻 **系统级安全执行底座**：提供原生安全沙箱与指令通道，赋能端侧高级控制。
- 🔒 **端侧隐私保护**：任务运行环境位于设备本地，敏感数据不离机。

---

## 📱 核心功能特性 (Key Features)

### 1. DSH 原生智能体运行时
- 端侧内置 Node.js + Python 双语言轻量沙箱环境。
- 原生 ToolBridge 工具桥接（支持系统调用、网络请求、文件读写、网页浏览与自动化操作）。
- 实时流式思考（Thinking Stream）与任务状态可视化。

### 2. 灵动画中画小窗 (Agent Pip)
- 参考原生交互设计，支持全屏展开、悬浮窗态、微型胶囊态自由切换。
- 智能磁吸贴边、自适应平滑吸附。
- 后台常驻状态微光环提示（运行中 / 等待中 / 错误警告）。

### 3. 系统级无感协同
- 侧边抽屉极简导航，随时在「**Swai 智能体**」、「**Shell 终端**」与「**独立浏览器**」之间无缝切换。
- 屏幕左侧微型拉手与边缘手势呼出，对主界面内容零遮挡。

---

## 🏗️ 架构概览 (Architecture)

```
┌─────────────────────────────────────────────────────────────┐
│                 Swai UI Layer (ArkUI / ETS)                 │
│  ┌───────────────────────┬───────────────────────────────┐  │
│  │   DSH Webview & Chat  │   Browser Floating Pip (画中画)│  │
│  └───────────────────────┴───────────────────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│                 Agent Core Runtime Engine                   │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ DeepSeek Harness (In-Process Runtime) + ToolRegistry  │  │
│  │ - Tools: Bash, Fetch, FileEditor, Chrome DevTools CDP │  │
│  └───────────────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│                 System & Execution Layer                    │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ HarmonyOS Native NDK (C++) + ShellBridge Service      │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 🚀 快速开始 (Getting Started)

### 环境依赖
- **DevEco Studio**: 5.0.0+ / HarmonyOS NEXT SDK (API 12+)
- **系统版本**: HarmonyOS NEXT 5.0+ (如 Mate 60 / Pura 70 系列或开发者真机)

### 编译与构建
1. 克隆本项目：
   ```bash
   git clone https://github.com/shuwei-ai/swai.git
   cd swai
   ```
2. 在 DevEco Studio 中打开项目，并在 `File -> Project Structure -> Signing Configs` 中勾选 `Automatically generate signature` 生成您的个人本地调试证书。
3. 执行编译打包：
   ```bash
   hvigorw assembleHap --mode module -p product=default -p module=entry@default
   ```

---

## 📄 开源许可证 (License)

本项目遵循 [Apache 2.0 License](LICENSE) 开源协议。
