/**
 * Swai (Shuwei AI) <-> DeepSeek Harness (DSH) Unified Agent Manager
 *
 * Implements native In-Process DeepSeek Harness execution engine on HarmonyOS NEXT:
 * - Coordinates Native C ABI (dsh_host_swai_v1) & DshToolBridge
 * - Dispatches autonomous Harness turns with LLM stream (reasoning & content)
 * - Executes native tools directly via ToolRegistry (ui, bash, run_code, remote_bash)
 * - Broadcasts streaming events to DshClient and AppStorage for UI & Float Window
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import {
  dshHostStartNative,
  dshHostStopNative,
  dshHostGetSnapshotNative,
  DshHostSnapshot
} from '../../common/NativeBridge';
import { DshToolBridge } from './DshToolBridge';
import { DshClient, DshStreamEvent } from './DshClient';
import { AgentConfigStore } from '../AgentConfigStore';
import { LlmClient } from '../LlmClient';
import { ToolRegistry } from '../tools/ToolRegistry';
import { ImageAttachment, Message, ToolCall } from '../types';
import hilog from '@ohos.hilog';
import fs from '@ohos.file.fs';

const DOMAIN = 0x3F00;
const TAG = 'DshAgentManager';

export interface DshUiState {
  phase: string;
  isConnected: boolean;
  port: number;
  baseUrl: string;
  authToken?: string;
  activeTool?: string;
  activeAction?: string;
  currentThinking: string;
  currentReply: string;
  lastError?: string;
}

export type DshUiStateListener = (state: DshUiState) => void;

export class DshAgentManager {
  private static instance: DshAgentManager | null = null;
  private stateListeners: DshUiStateListener[] = [];
  private activeLlmClient: LlmClient | null = null;
  private conversationHistory: Message[] = [];
  private workspaceRoot: string = '';
  private startEnginePromise: Promise<boolean> | null = null;
  private engineStartEpochMs: number = 0;
  private currentState: DshUiState = {
    phase: 'idle',
    isConnected: false,
    port: 0,
    baseUrl: '',
    currentThinking: '',
    currentReply: ''
  };

  static getInstance(): DshAgentManager {
    if (!DshAgentManager.instance) {
      DshAgentManager.instance = new DshAgentManager();
    }
    return DshAgentManager.instance;
  }

  getState(): DshUiState {
    if (!this.currentState.authToken || this.currentState.port === 0 || this.currentState.port === 2026) {
      try {
        const snap = dshHostGetSnapshotNative();
        if (snap && snap.phase === 'running' && snap.port > 0) {
          this.currentState.phase = 'running';
          this.currentState.isConnected = true;
          this.currentState.port = snap.port;
          this.currentState.baseUrl = snap.baseUrl;
          this.currentState.authToken = snap.token;
        }
      } catch (e) {
        // ignore
      }
    }
    return this.currentState;
  }

  getAuthenticatedUrl(workspaceRoot?: string): string {
    const state = this.getState();
    if (state.baseUrl && state.port > 0) {
      return `${state.baseUrl}/`;
    }
    // Fallback: Check ready.json on disk directly
    try {
      const candidates: string[] = [];
      const ws = workspaceRoot || this.workspaceRoot;
      if (ws && ws.length > 0) {
        candidates.push(`${ws}/ready.json`);
      }
      candidates.push('/data/storage/el2/base/haps/entry/files/workspace/ready.json');
      for (let i = 0; i < candidates.length; i++) {
        const p = candidates[i];
        if (fs.accessSync(p)) {
          const content = fs.readTextSync(p);
          const obj = JSON.parse(content) as Record<string, Object>;
          if (obj) {
            if (typeof obj.baseUrl === 'string' && (obj.baseUrl as string).length > 0) {
              return `${obj.baseUrl as string}/`;
            }
            if (typeof obj.url === 'string' && (obj.url as string).length > 0) {
              return obj.url as string;
            }
          }
        }
      }
    } catch (e) {
      // ignore
    }
    return state.baseUrl || '';
  }

  constructor() {
    // Listen to tool bridge events
    DshToolBridge.getInstance().addListener((tool, action, status) => {
      if (status === 'started') {
        this.updateState({ activeTool: tool, activeAction: action });
      } else {
        this.updateState({ activeTool: undefined, activeAction: undefined });
      }
    });

    // Listen to client streaming events
    DshClient.getInstance().addListener((event: DshStreamEvent) => {
      switch (event.kind) {
        case 'thinking':
          this.updateState({
            currentThinking: this.currentState.currentThinking + (event.content || '')
          });
          break;
        case 'token':
          this.updateState({
            currentReply: this.currentState.currentReply + (event.content || '')
          });
          break;
        case 'tool_call':
          this.updateState({
            activeTool: event.toolName,
            activeAction: event.toolArgs
          });
          break;
        case 'tool_result':
          this.updateState({
            activeTool: undefined,
            activeAction: undefined
          });
          break;
        case 'done':
          this.updateState({
            activeTool: undefined,
            activeAction: undefined
          });
          break;
        case 'error':
          this.updateState({
            lastError: event.error
          });
          break;
      }
    });
  }

  addUiStateListener(listener: DshUiStateListener): void {
    this.stateListeners.push(listener);
    listener(this.currentState);
  }

  removeUiStateListener(listener: DshUiStateListener): void {
    this.stateListeners = this.stateListeners.filter(l => l !== listener);
  }

  getCurrentState(): DshUiState {
    return this.currentState;
  }

  getSnapshot(): DshHostSnapshot {
    return dshHostGetSnapshotNative();
  }

  isEngineRunning(): boolean {
    return this.currentState.phase === 'running' && this.currentState.isConnected;
  }

  private updateState(partial: Partial<DshUiState>): void {
    if (partial.phase !== undefined) {
      this.currentState.phase = partial.phase;
    }
    if (partial.isConnected !== undefined) {
      this.currentState.isConnected = partial.isConnected;
    }
    if (partial.port !== undefined) {
      this.currentState.port = partial.port;
    }
    if (partial.baseUrl !== undefined) {
      this.currentState.baseUrl = partial.baseUrl;
    }
    if (partial.activeTool !== undefined) {
      this.currentState.activeTool = partial.activeTool;
    }
    if (partial.activeAction !== undefined) {
      this.currentState.activeAction = partial.activeAction;
    }
    if (partial.currentThinking !== undefined) {
      this.currentState.currentThinking = partial.currentThinking;
    }
    if (partial.currentReply !== undefined) {
      this.currentState.currentReply = partial.currentReply;
    }
    if (partial.lastError !== undefined) {
      this.currentState.lastError = partial.lastError;
    }

    // Synchronize to AppStorage for Float Window and System UI
    const isRunning = this.currentState.phase === 'running' ||
      this.currentState.phase === 'starting' ||
      !!this.currentState.activeTool ||
      this.currentState.currentThinking.length > 0 ||
      this.currentState.currentReply.length > 0;

    AppStorage.setOrCreate('agentIsRunning', isRunning);
    AppStorage.setOrCreate('agentThinkingText', this.currentState.currentThinking);

    let statusText = '待命';
    if (this.currentState.activeTool) {
      statusText = `执行工具: ${this.currentState.activeTool}`;
      AppStorage.setOrCreate('agentCurrentTool', `${this.currentState.activeTool}: ${this.currentState.activeAction || ''}`);
    } else if (this.currentState.phase === 'starting') {
      statusText = 'DSH 引擎启动中...';
      AppStorage.setOrCreate('agentCurrentTool', '');
    } else if (this.currentState.phase === 'running') {
      statusText = this.currentState.currentReply ? '正在生成回复...' : 'DSH 引擎就绪';
      AppStorage.setOrCreate('agentCurrentTool', '');
    } else if (this.currentState.phase === 'error') {
      statusText = `错误: ${this.currentState.lastError || ''}`;
      AppStorage.setOrCreate('agentCurrentTool', '');
    } else {
      AppStorage.setOrCreate('agentCurrentTool', '');
    }
    AppStorage.setOrCreate('agentStatusText', statusText);

    for (const listener of this.stateListeners) {
      try {
        listener(this.currentState);
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'Listener error: %{public}s', `${err}`);
      }
    }
  }

  async startEngine(runtimeRoot: string, workspaceRoot: string): Promise<boolean> {
    if (this.isEngineRunning()) {
      return true;
    }
    if (this.startEnginePromise) {
      return this.startEnginePromise;
    }
    this.startEnginePromise = this.startEngineInner(runtimeRoot, workspaceRoot);
    try {
      return await this.startEnginePromise;
    } finally {
      if (!this.isEngineRunning()) {
        this.startEnginePromise = null;
      }
    }
  }

  private async startEngineInner(runtimeRoot: string, workspaceRoot: string): Promise<boolean> {
    this.workspaceRoot = workspaceRoot;
    this.engineStartEpochMs = Date.now();
    this.updateState({
      phase: 'starting',
      isConnected: false,
      port: 0,
      baseUrl: '',
      authToken: undefined,
      lastError: undefined
    });

    try {
      dshHostStartNative({
        runtimeRoot: runtimeRoot,
        workspaceRoot: workspaceRoot
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'dshHostStartNative error: %{public}s', `${e}`);
    }

    // Start background Tool Bridge
    DshToolBridge.getInstance().start();

    // Poll until running or timeout (60s for first-launch compile cache generation)
    const startTime = this.engineStartEpochMs;
    let isRunning = false;
    let finalUrl = '';
    let finalPort = 0;
    let finalToken = '';
    let lastErrorMsg = '';

    while (Date.now() - startTime < 60000) {
      const snap = dshHostGetSnapshotNative();
      if (snap.phase === 'running' && snap.port > 0) {
        isRunning = true;
        finalPort = snap.port;
        finalUrl = snap.baseUrl;
        finalToken = snap.token;
        break;
      }
      if (snap.phase === 'error' || snap.phase === 'exited') {
        const errParts = [snap.errorCode, snap.errorMessage].filter((s) => s && s.trim().length > 0);
        lastErrorMsg = errParts.length > 0 ? errParts.join(': ') : `DSH 进程异常退出 (${snap.phase})`;
        hilog.error(DOMAIN, TAG, 'DSH engine failed to start: %{public}s', lastErrorMsg);
        break;
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 50));
    }

    if (isRunning) {
      const elapsedMs = Date.now() - this.engineStartEpochMs;
      this.updateState({
        phase: 'running',
        isConnected: true,
        port: finalPort,
        baseUrl: finalUrl,
        authToken: finalToken
      });
      hilog.info(DOMAIN, TAG, 'In-process DeepSeek Harness engine ready in %{public}d ms on %{public}s', elapsedMs, finalUrl);
      return true;
    } else {
      const errDetail = lastErrorMsg.length > 0 ? lastErrorMsg : 'DSH engine start timed out (60s)';
      this.updateState({
        phase: 'error',
        isConnected: false,
        port: 0,
        baseUrl: '',
        lastError: errDetail
      });
      hilog.error(DOMAIN, TAG, 'Engine start failed: %{public}s', errDetail);
      return false;
    }
  }

  stopEngine(): void {
    this.startEnginePromise = null;
    if (this.activeLlmClient) {
      this.activeLlmClient.abort();
      this.activeLlmClient = null;
    }
    DshToolBridge.getInstance().stop();
    dshHostStopNative();
    this.updateState({
      phase: 'idle',
      isConnected: false,
      port: 0,
      baseUrl: '',
      activeTool: undefined,
      activeAction: undefined,
      currentThinking: '',
      currentReply: ''
    });
  }

  /**
   * Check if the given baseUrl points to a local relay or a known free model gateway
   * that does not require an API key (dsh-our-free-model compatible endpoints).
   */
  private static isKeylessEndpoint(baseUrl: string): boolean {
    const lower = (baseUrl || '').toLowerCase();
    return lower.includes('127.0.0.1')
      || lower.includes('localhost')
      || lower.includes('opencode.ai')
      || lower.includes('kilo-ai.com');
  }

  async sendPrompt(prompt: string, images?: ImageAttachment[]): Promise<boolean> {
    const config = AgentConfigStore.getInstance().getConfig();
    if (!DshAgentManager.isKeylessEndpoint(config.baseUrl)
      && (!config.apiKey || config.apiKey.trim().length === 0)) {
      const err = '请先点击右上角「模型设置」配置 API Key，或选择「🆓 免费模型」预设';
      DshClient.getInstance().emit({ kind: 'error', error: err });
      return false;
    }

    AppStorage.setOrCreate('agentLatestPrompt', prompt);
    this.updateState({
      currentThinking: '',
      currentReply: '',
      lastError: undefined
    });

    // Build system prompt if conversation history is empty
    if (this.conversationHistory.length === 0) {
      const systemPrompt = `You are Swai, an expert AI personal assistant and coding automation agent running natively on HarmonyOS NEXT (Swai - 枢维智能 · 个人智能体).
You are powered by DeepSeek Harness (DSH). You have direct native access to device shell commands (uid=2000), UI automation (ui), file operations (read, write, edit), Python/JS execution (run_code, run_js), remote SSH execution (remote_bash), and screen inspection (inspect_image).

Always be concise, precise, and proactive. When asked to perform system actions, check status, or explore, call the appropriate tools.
When asked to check, view, inspect, or see the current device screen (e.g. 截图看下, 查看屏幕), call the inspect_image tool with source="screen". When images are attached by the user or tools, carefully inspect and describe the visual content.`;
      this.conversationHistory.push({
        role: 'system',
        content: systemPrompt
      });
    }

    const userMsg: Message = {
      role: 'user',
      content: prompt
    };
    if (images && images.length > 0) {
      userMsg.images = images;
    }
    this.conversationHistory.push(userMsg);

    this.activeLlmClient = new LlmClient();
    const maxTurns = 15;
    let turn = 0;

    try {
      while (turn < maxTurns) {
        turn++;
        const sanitizedHistory = LlmClient.sanitizeMessages(this.conversationHistory);

        const result = await this.activeLlmClient.streamChat(
          config,
          sanitizedHistory,
          ToolRegistry.getDefinitions(),
          {
            onThinkingDelta: (delta: string) => {
              DshClient.getInstance().emit({ kind: 'thinking', content: delta });
            },
            onContentDelta: (delta: string) => {
              DshClient.getInstance().emit({ kind: 'token', content: delta });
            }
          }
        );

        if (result.tool_calls && result.tool_calls.length > 0) {
          // Append assistant message with tool calls
          this.conversationHistory.push({
            role: 'assistant',
            content: result.content,
            reasoning_content: result.reasoning_content,
            tool_calls: result.tool_calls
          });

          // Execute each tool call sequentially
          for (const tc of result.tool_calls) {
            DshClient.getInstance().emit({
              kind: 'tool_call',
              toolName: tc.function.name,
              toolArgs: tc.function.arguments
            });

            const toolRes = await ToolRegistry.execute(tc);

            DshClient.getInstance().emit({
              kind: 'tool_result',
              toolName: tc.function.name,
              toolOutput: toolRes.output || toolRes.error || '',
              images: toolRes.images
            });

            const toolMsg: Message = {
              role: 'tool',
              tool_call_id: tc.id,
              name: tc.function.name,
              content: toolRes.output || toolRes.error || ''
            };
            if (toolRes.images && toolRes.images.length > 0) {
              toolMsg.images = toolRes.images;
            }
            this.conversationHistory.push(toolMsg);
          }

          // Continue loop for model to evaluate tool results
          continue;
        }

        // Final assistant turn completed without new tool calls
        this.conversationHistory.push({
          role: 'assistant',
          content: result.content,
          reasoning_content: result.reasoning_content
        });
        break;
      }

      DshClient.getInstance().emit({ kind: 'done' });
      return true;
    } catch (err) {
      const errMsg = (err instanceof Error) ? err.message : `${err}`;
      hilog.error(DOMAIN, TAG, 'Autonomous Harness turn error: %{public}s', errMsg);
      DshClient.getInstance().emit({ kind: 'error', error: errMsg });
      return false;
    } finally {
      this.activeLlmClient = null;
    }
  }

  async interrupt(): Promise<boolean> {
    if (this.activeLlmClient) {
      this.activeLlmClient.abort();
      this.activeLlmClient = null;
    }
    this.updateState({
      activeTool: undefined,
      activeAction: undefined
    });
    DshClient.getInstance().emit({ kind: 'done' });
    return true;
  }
}
