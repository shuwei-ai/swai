/*
 * Central Tool Registry for the HarmonyOS Pi Agent.
 * Registers bash, read, write, edit, ui, run_code, run_js, remote_bash,
 * browser, fetch, inspect_image, remember, and goal tools.
 * Dispatches all execution through the Harness ToolPipeline.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import { ToolCall, ToolDefinition, ToolResult } from '../types';
import { BashTool } from './BashTool';
import { ReadTool } from './ReadTool';
import { WriteTool } from './WriteTool';
import { EditTool } from './EditTool';
import { UiTool } from './UiTool';
import { RunCodeTool } from './RunCodeTool';
import { RunJsTool } from './RunJsTool';
import { RemoteBashTool } from './RemoteBashTool';
import { BrowserTool } from './BrowserTool';
import { FetchTool } from './FetchTool';
import { InspectImageTool } from './InspectImageTool';
import { RememberTool } from './RememberTool';
import { GoalTool } from './GoalTool';
import { ToolPipeline } from './ToolPipeline';

export class ToolRegistry {
  static getDefinitions(): ToolDefinition[] {
    return [
      BashTool.getDefinition(),
      ReadTool.getDefinition(),
      WriteTool.getDefinition(),
      EditTool.getDefinition(),
      UiTool.getDefinition(),
      RunCodeTool.getDefinition(),
      RunJsTool.getDefinition(),
      RemoteBashTool.getDefinition(),
      BrowserTool.getDefinition(),
      FetchTool.getDefinition(),
      InspectImageTool.getDefinition(),
      RememberTool.getDefinition(),
      GoalTool.getDefinition()
    ];
  }

  private static async dispatchTool(id: string, name: string, args: Record<string, Object>): Promise<ToolResult> {
    switch (name) {
      case 'bash':
        return await BashTool.execute(id, args);
      case 'read':
        return await ReadTool.execute(id, args);
      case 'write':
        return await WriteTool.execute(id, args);
      case 'edit':
        return await EditTool.execute(id, args);
      case 'ui':
        return await UiTool.execute(id, args);
      case 'run_code':
      case 'offline_code':
        return await RunCodeTool.execute(id, args);
      case 'run_js':
        return await RunJsTool.execute(id, args);
      case 'remote_bash':
        return await RemoteBashTool.execute(id, args);
      case 'browser':
        return await BrowserTool.execute(id, args);
      case 'fetch':
        return await FetchTool.execute(id, args);
      case 'inspect_image':
        return await InspectImageTool.execute(id, args);
      case 'remember':
        return await RememberTool.execute(id, args);
      case 'goal':
        return await GoalTool.execute(id, args);
      default:
        return {
          toolCallId: id,
          toolName: name,
          output: '',
          error: `Unknown tool: ${name}`,
          isError: true
        };
    }
  }

  static async execute(toolCall: ToolCall): Promise<ToolResult> {
    return ToolPipeline.execute(toolCall, async (id: string, args: Record<string, Object>) => {
      return await ToolRegistry.dispatchTool(id, toolCall.function.name, args);
    });
  }

  /**
   * Executes a tool directly without ToolPipeline structured header wrapping or pre-truncation.
   * Used by DshToolBridge so DeepSeek Harness manages spill/truncation and bash stdio cleanly.
   */
  static async executeRaw(toolCall: ToolCall): Promise<ToolResult> {
    const id = toolCall.id;
    const name = toolCall.function.name;
    const rawArgs = toolCall.function.arguments;

    let parsedArgs: Record<string, Object> = {};
    if (rawArgs && rawArgs.trim().length > 0) {
      try {
        parsedArgs = JSON.parse(rawArgs) as Record<string, Object>;
      } catch (err) {
        return {
          toolCallId: id,
          toolName: name,
          output: '',
          error: `Failed to parse tool arguments JSON: ${err}`,
          isError: true
        };
      }
    }

    try {
      return await ToolRegistry.dispatchTool(id, name, parsedArgs);
    } catch (toolEx) {
      return {
        toolCallId: id,
        toolName: name,
        output: '',
        error: `Tool exception: ${toolEx}`,
        isError: true
      };
    }
  }
}
