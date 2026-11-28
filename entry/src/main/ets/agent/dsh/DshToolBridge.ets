/*
 * Swai (Shuwei HShell) <-> DeepSeek Harness (DSH) Tool Bridge Dispatcher
 *
 * Polls claimed tool requests from Native C ABI state machine,
 * executes them via ToolRegistry (UiTool, BashTool, RunCodeTool, RemoteBashTool),
 * and feeds results back to DSH.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import { dshHostClaimNative, dshHostFinishNative, DshToolClaimResult, DshToolFinishInput } from '../../common/NativeBridge';
import { ToolRegistry } from '../tools/ToolRegistry';
import { DshImageProcessor } from './DshImageProcessor';
import { ThinkingCapsuleManager } from '../../window/ThinkingCapsuleManager';
import { ToolCall, ToolResult } from '../types';
import hilog from '@ohos.hilog';

export type ToolBridgeListener = (tool: string, action: string, status: 'started' | 'completed' | 'failed') => void;

export class DshToolBridge {
  private static instance: DshToolBridge | null = null;
  private running: boolean = false;
  private listeners: ToolBridgeListener[] = [];

  static getInstance(): DshToolBridge {
    if (!DshToolBridge.instance) {
      DshToolBridge.instance = new DshToolBridge();
    }
    return DshToolBridge.instance;
  }

  addListener(listener: ToolBridgeListener): void {
    this.listeners.push(listener);
  }

  removeListener(listener: ToolBridgeListener): void {
    this.listeners = this.listeners.filter(l => l !== listener);
  }

  private notify(tool: string, action: string, status: 'started' | 'completed' | 'failed'): void {
    for (const listener of this.listeners) {
      try {
        listener(tool, action, status);
      } catch (_) {}
    }
  }

  start(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.pollLoop();
  }

  stop(): void {
    this.running = false;
  }

  private async pollLoop(): Promise<void> {
    while (this.running) {
      try {
        const claim = await dshHostClaimNative(300);
        if (claim) {
          await this.handleClaim(claim);
        }
      } catch (err) {
        hilog.error(0x3F00, 'DshToolBridge', 'Error in tool claim loop: %{public}s', String(err));
        await new Promise<void>((resolve: () => void) => {
          setTimeout(resolve, 500);
        });
      }
    }
  }

  private async handleClaim(claim: DshToolClaimResult): Promise<void> {
    const toolName = claim.tool;
    const reqId = claim.requestId;

    // Internal silent bridge for DSH attachment image verification & normalization
    if (toolName === 'dsh_image_op') {
      const imgRes = await DshImageProcessor.execute(claim.argsJson || '{}');
      dshHostFinishNative({
        requestId: reqId,
        success: imgRes.ok,
        output: imgRes.output,
        error: imgRes.error,
        exitCode: imgRes.ok ? 0 : 1
      });
      return;
    }

    // Internal silent lifecycle telemetry from DSH agent loop -> ThinkingCapsuleManager
    if (toolName === 'swai_capsule_event') {
      ThinkingCapsuleManager.getInstance().onCapsuleEvent(claim.argsJson || '{}');
      dshHostFinishNative({
        requestId: reqId,
        success: true,
        output: 'ok',
        error: '',
        exitCode: 0
      });
      return;
    }

    let actionDesc = '';

    try {
      const parsedArgs = JSON.parse(claim.argsJson || '{}') as Record<string, Object>;
      actionDesc = (parsedArgs['action'] as string) || (parsedArgs['command'] as string) || '';
    } catch (_) {}

    this.notify(toolName, actionDesc, 'started');
    ThinkingCapsuleManager.getInstance().onToolStart(toolName, claim.argsJson || '{}');

    const toolCall: ToolCall = {
      id: reqId,
      type: 'function',
      function: {
        name: toolName,
        arguments: claim.argsJson || '{}'
      }
    };

    const isScreenCaptureCmd = toolName === 'bash' &&
      (actionDesc.includes('snapshot_display') || actionDesc.includes('uitest screenCap'));
    let hidCapsuleForCapture = false;
    if (isScreenCaptureCmd) {
      hidCapsuleForCapture = await ThinkingCapsuleManager.getInstance().temporaryHideForAction('capture_screen');
    }

    let result: ToolResult;
    try {
      result = await ToolRegistry.executeRaw(toolCall);
    } catch (err) {
      result = {
        toolCallId: reqId,
        toolName: toolName,
        output: '',
        error: `Exception executing tool ${toolName}: ${err}`,
        isError: true
      };
    } finally {
      if (hidCapsuleForCapture) {
        ThinkingCapsuleManager.getInstance().restoreAfterTemporaryHide();
      }
    }

    const finishInput: DshToolFinishInput = {
      requestId: reqId,
      success: !result.isError,
      output: result.output || '',
      error: result.error || '',
      exitCode: result.isError ? 1 : 0
    };

    dshHostFinishNative(finishInput);
    ThinkingCapsuleManager.getInstance().onToolFinish(toolName, claim.argsJson || '{}', result.isError);
    this.notify(toolName, actionDesc, result.isError ? 'failed' : 'completed');
  }
}
