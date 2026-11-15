/*
 * DeepSeek Harness (DSH) Single Unified Agent Session for HarmonyOS.
 *
 * Exclusively driven by DeepSeek Harness in-process engine:
 * - Direct streaming reasoning (Thinking) and assistant tokens via WebSocket ($events).
 * - Real-time Tool Bridge interception for native Swai tools.
 * - Single-engine mode without legacy fallback or dual-engine switching.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import hilog from '@ohos.hilog';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { AgentModelConfig, ImageAttachment, Message, SessionEvent, ToolResult } from './types';
import { ContextTracker, ContextUsageSummary } from './ContextTracker';
import { GoalManager } from './goal/GoalManager';
import { DshAgentManager } from './dsh/DshAgentManager';
import { DshClient, DshStreamEvent } from './dsh/DshClient';

const DOMAIN: number = 0x0001;
const TAG: string = 'AgentSession';

export type SessionEventListener = (event: SessionEvent) => void;

export class AgentSession {
  private config: AgentModelConfig;
  private messages: Message[] = [];
  private listeners: SessionEventListener[] = [];
  private isRunning: boolean = false;
  private currentThinking: string = '';
  private currentReply: string = '';
  private boundStreamListener: ((event: DshStreamEvent) => void) | null = null;

  constructor(config: AgentModelConfig) {
    this.config = config;
    this.messages = [];
    this.initDshBridge();
  }

  private initDshBridge(): void {
    this.boundStreamListener = (event: DshStreamEvent) => {
      this.handleStreamEvent(event);
    };
    DshClient.getInstance().addListener(this.boundStreamListener);
  }

  private handleStreamEvent(event: DshStreamEvent): void {
    switch (event.kind) {
      case 'thinking':
        this.currentThinking += event.content || '';
        this.emit({
          type: 'thinking_delta',
          text: event.content || ''
        });
        break;

      case 'token':
        this.currentReply += event.content || '';
        this.emit({
          type: 'text_delta',
          text: event.content || ''
        });
        break;

      case 'tool_call':
        this.emit({
          type: 'tool_call_start',
          toolCall: {
            id: `call_${Date.now()}`,
            type: 'function',
            function: {
              name: event.toolName || 'tool',
              arguments: event.toolArgs || '{}'
            }
          }
        });
        break;

      case 'tool_result':
        this.emit({
          type: 'tool_call_result',
          toolResult: {
            toolCallId: `call_${Date.now()}`,
            toolName: event.toolName || 'tool',
            output: event.toolOutput || '',
            images: event.images,
            isError: false
          }
        });
        break;

      case 'done':
        if (this.currentReply.length > 0 || this.currentThinking.length > 0) {
          const assistantMsg: Message = {
            role: 'assistant',
            content: this.currentReply
          };
          if (this.currentThinking.length > 0) {
            assistantMsg.reasoning_content = this.currentThinking;
          }
          this.messages.push(assistantMsg);
        }
        this.isRunning = false;
        this.currentThinking = '';
        this.currentReply = '';
        this.emit({ type: 'turn_complete' });
        break;

      case 'error':
        this.isRunning = false;
        this.currentThinking = '';
        this.currentReply = '';
        this.emit({
          type: 'error',
          error: event.error || 'DSH engine error'
        });
        break;
    }
  }

  addEventListener(listener: SessionEventListener): void {
    this.listeners.push(listener);
  }

  removeEventListener(listener: SessionEventListener): void {
    this.listeners = this.listeners.filter(l => l !== listener);
  }

  private emit(event: SessionEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(event);
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'Listener invocation error: %{public}s', `${err}`);
      }
    }
  }

  getMessages(): Message[] {
    return this.messages;
  }

  setMessages(messages: Message[]): void {
    this.messages = messages;
  }

  clearHistory(): void {
    this.messages = [];
  }

  getIsRunning(): boolean {
    return this.isRunning;
  }

  getContextUsage(): ContextUsageSummary {
    return ContextTracker.getInstance().computeUsage(this.messages);
  }

  updateConfig(config: AgentModelConfig): void {
    this.config = config;
  }

  refreshSystemPrompt(): void {
    // DSH engine manages system prompt dynamically
  }

  manualCompact(): void {
    // DSH engine manages context windows dynamically
  }

  abort(): void {
    this.isRunning = false;
    this.currentThinking = '';
    this.currentReply = '';
    DshAgentManager.getInstance().interrupt();
    this.emit({ type: 'stopped' });
  }

  async runPrompt(userPrompt: string, images?: ImageAttachment[]): Promise<void> {
    const trimmedPrompt = userPrompt ? userPrompt.trim() : '';
    if (trimmedPrompt.length === 0 && (!images || images.length === 0)) {
      return;
    }

    const effectivePrompt = trimmedPrompt.length > 0 ? userPrompt : '请查看我发送的图片。';

    this.isRunning = true;
    this.currentThinking = '';
    this.currentReply = '';

    // If user prompt starts with /goal, initialize autonomous goal
    if (trimmedPrompt.startsWith('/goal')) {
      const goalObjective = trimmedPrompt.substring(5).trim() || 'Autonomous System Task';
      GoalManager.getInstance().startGoal(goalObjective);
      this.emit({
        type: 'goal_updated',
        goal: GoalManager.getInstance().getActiveGoal() as Object
      });
    }

    // Append user message
    this.messages.push({
      role: 'user',
      content: effectivePrompt,
      images: images && images.length > 0 ? images : undefined
    });

    this.emit({
      type: 'user_message_appended',
      text: effectivePrompt,
      images: images
    });

    // Request transient background execution delay so OS does not freeze process
    let suspendDelayId = -1;
    try {
      const delayInfo = backgroundTaskManager.requestSuspendDelay('PiDshTask', () => {
        hilog.warn(DOMAIN, TAG, 'Background suspend delay expired by system');
      });
      suspendDelayId = delayInfo.requestId;
    } catch (_) {}

    try {
      const ok = await DshAgentManager.getInstance().sendPrompt(
        effectivePrompt,
        images && images.length > 0 ? images : undefined
      );
      if (!ok) {
        this.isRunning = false;
        this.emit({
          type: 'error',
          error: 'Failed to send prompt to DeepSeek Harness engine'
        });
      }
    } catch (err) {
      this.isRunning = false;
      this.emit({
        type: 'error',
        error: `${err}`
      });
    } finally {
      if (suspendDelayId !== -1) {
        try {
          backgroundTaskManager.cancelSuspendDelay(suspendDelayId);
        } catch (_) {}
      }
    }
  }

  destroy(): void {
    if (this.boundStreamListener) {
      DshClient.getInstance().removeListener(this.boundStreamListener);
      this.boundStreamListener = null;
    }
  }
}
