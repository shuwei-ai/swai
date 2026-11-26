/*
 * Pi Bash Tool implementation for HarmonyOS.
 * Executes shell commands at uid 2000 (shell) via the native HDC bridge.
 */
import { BridgeController } from '../../common/BridgeController';
import { runPythonNative } from '../../common/NativeBridge';
import { ToolDefinition, ToolFunctionDefinition, ToolParameters, ToolProperty, ToolResult } from '../types';
import { SecurityGuardrail } from '../security/SecurityGuardrail';
import { AgentWorkspace } from './AgentWorkspace';

export class BashTool {
  private static readonly DEFAULT_TIMEOUT_SECONDS = 30;
  private static readonly MAX_TIMEOUT_SECONDS = 300;

  static getDefinition(): ToolDefinition {
    const props: Record<string, ToolProperty> = {
      'command': new ToolProperty('string', 'The shell command to execute.'),
      'bundle_name': new ToolProperty(
        'string',
        'Optional target debug bundle name when inspecting a debuggable app sandbox (defaults to current app sandbox when /data/storage/ paths are referenced).'
      ),
      'timeout_seconds': new ToolProperty(
        'number',
        'Optional timeout in seconds (1-300, default: 30). Increase for long operations or keep bounded commands (e.g. ping -c 4, hilog -x | tail -n 50).'
      )
    };
    const params = new ToolParameters(props, ['command']);
    const func = new ToolFunctionDefinition(
      'bash',
      'Execute a shell command on the HarmonyOS NEXT device with uid 2000 (shell). ' +
      'SUPPORTED CAPABILITIES: ' +
      '(1) aa: Ability lifecycle (aa start -a <ability> -b <bundle> [-u 100], aa force-stop <bundle>, aa stop-service); ' +
      '(2) bm: Package management (bm dump -a, bm dump -n <bundle>, bm install -p <hap> -r, bm uninstall, bm clean, bm get --udid); ' +
      '(3) uitest: UI layout & input (uitest dumpLayout -p /data/local/tmp/layout.json, uitest uiInput text \'<chinese>\', uitest uiInput click/swipe/keyEvent); ' +
      '(4) hidumper: System diagnostics (hidumper -s <service> -a, hidumper --mem <pid>, hidumper --cpu); ' +
      '(5) hilog: Logging (ALWAYS pass non-blocking -x: e.g. `hilog -x -P <pid> | tail -n 50`, `hilog -x -T <tag> | tail -n 50`); ' +
      '(6) param: System properties (param get <key>, param dump); ' +
      '(7) power-shell: Screen wakeup & power mode (power-shell wakeup); ' +
      '(8) toybox utilities: ps -ef, kill, ls, rm, mkdir -p, df, grep, find. ' +
      'App sandbox paths under /data/storage/ are automatically bridged to the HarmonyOS debug mount (/mnt/debug/<userId>/debug_hap/<bundle>/data/storage/). ' +
      'STRICT RESTRICTIONS: ' +
      'Prefer "read"/"write"/"edit"/"glob"/"grep" tools for workspace file operations. ' +
      'DO NOT run python, node, npm in shell (none exist in /system/bin; use "offline_code" / "run_code" tool instead). ' +
      'DO NOT run curl or wget (use "fetch" tool instead).',
      params
    );
    return new ToolDefinition(func);
  }

  /**
   * Rewrites app sandbox `/data/storage` paths in shell commands to the HarmonyOS
   * debug mount (`/mnt/debug/<userId>/debug_hap/<bundleName>/data/storage`) so uid 2000
   * shell commands can seamlessly traverse, read, and write debuggable app sandbox files
   * without hitting Mount Namespace / SELinux Permission denied errors.
   */
  static rewriteCommandForShell(command: string, explicitBundleName?: string): string {
    const ws = AgentWorkspace.getInstance();
    const targetBundle = (explicitBundleName && explicitBundleName.trim().length > 0)
      ? explicitBundleName.trim()
      : ws.getBundleName();
    const debugRoot = ws.getDebugSandboxRoot(targetBundle);

    let rewritten = command.replace(
      /(^|[^A-Za-z0-9_.\-\/])(\/data\/storage(?=\/|$|\s|"|'|;|\)|&|\||`))/g,
      `$1${debugRoot}$2`
    );

    if (explicitBundleName && explicitBundleName.trim().length > 0) {
      const trimmed = rewritten.trimStart();
      if (!trimmed.startsWith('cd ') && !trimmed.startsWith('cd/') && !trimmed.startsWith('if ! cd ')) {
        const safeRoot = debugRoot.replace(/'/g, "'\\''");
        rewritten = `if ! cd '${safeRoot}' 2>/dev/null; then cd /data/local/tmp 2>/dev/null || true; fi\n${rewritten}`;
      }
    }

    return rewritten;
  }

  /**
   * Normalizes `/mnt/debug/<userId>/debug_hap/<ownBundle>/data/storage` prefixes in shell
   * output back to canonical `/data/storage` so paths stay unified across bash, read/write,
   * glob/grep, and offline_code.
   */
  static normalizeShellOutput(text: string): string {
    if (!text || text.length === 0) {
      return text;
    }
    const ownDebugStorage = `${AgentWorkspace.getInstance().getDebugSandboxRoot()}/data/storage`;
    if (!text.includes(ownDebugStorage)) {
      return text;
    }
    return text.split(ownDebugStorage).join('/data/storage');
  }

  static clampTimeoutSeconds(rawTimeout?: number, rawTimeoutMs?: number): number {
    let seconds = BashTool.DEFAULT_TIMEOUT_SECONDS;
    if (typeof rawTimeout === 'number' && !Number.isNaN(rawTimeout) && Number.isFinite(rawTimeout)) {
      seconds = Math.round(rawTimeout);
    } else if (typeof rawTimeoutMs === 'number' && !Number.isNaN(rawTimeoutMs) && Number.isFinite(rawTimeoutMs)) {
      seconds = Math.max(1, Math.round(rawTimeoutMs / 1000));
    }
    if (seconds < 1) {
      return 1;
    }
    if (seconds > BashTool.MAX_TIMEOUT_SECONDS) {
      return BashTool.MAX_TIMEOUT_SECONDS;
    }
    return seconds;
  }

  static async execute(toolCallId: string, args: Record<string, Object>): Promise<ToolResult> {
    const command = (args['command'] as string) ?? '';
    if (!command || command.trim().length === 0) {
      return {
        toolCallId: toolCallId,
        toolName: 'bash',
        output: '',
        error: 'Command cannot be empty',
        isError: true
      };
    }

    // Intercept pip commands and route in-process to Python's pip package manager
    const trimmed = command.trim();
    if (trimmed.startsWith('pip ') || trimmed === 'pip' || trimmed.startsWith('pip3 ') || trimmed === 'pip3') {
      const parts = trimmed.split(/\s+/).slice(1);
      const pyCode = `import pip\npip.main(${JSON.stringify(parts)})\n`;
      try {
        const pyRes = await runPythonNative(pyCode, '', 60000);
        return {
          toolCallId: toolCallId,
          toolName: 'bash',
          output: pyRes.stdout.length > 0 ? pyRes.stdout : (pyRes.ok ? 'pip command executed successfully.' : ''),
          error: pyRes.stderr.length > 0 ? pyRes.stderr : (pyRes.ok ? undefined : 'pip command failed.'),
          isError: !pyRes.ok
        };
      } catch (err) {
        return {
          toolCallId: toolCallId,
          toolName: 'bash',
          output: '',
          error: `pip execution error: ${err}`,
          isError: true
        };
      }
    }

    const guardrailCheck = SecurityGuardrail.inspectCommand(command);
    if (guardrailCheck.isBlocked) {
      return {
        toolCallId: toolCallId,
        toolName: 'bash',
        output: '',
        error: `[SECURITY GUARDRAIL BLOCKED] ${guardrailCheck.reason}. This high-risk destructive action was blocked to protect device integrity. Please use a safer, bounded alternative.`,
        isError: true
      };
    }

    const timeoutSeconds = BashTool.clampTimeoutSeconds(
      (args['timeout_seconds'] as number | undefined) ?? (args['timeout'] as number | undefined),
      args['timeout_ms'] as number | undefined
    );

    const explicitBundle = typeof args['bundle_name'] === 'string'
      ? (args['bundle_name'] as string).trim()
      : '';
    const effectiveCommand = BashTool.rewriteCommandForShell(command, explicitBundle);
    if (effectiveCommand !== command) {
      const rewrittenCheck = SecurityGuardrail.inspectCommand(effectiveCommand);
      if (rewrittenCheck.isBlocked) {
        return {
          toolCallId: toolCallId,
          toolName: 'bash',
          output: '',
          error: `[SECURITY GUARDRAIL BLOCKED] ${rewrittenCheck.reason}. This high-risk destructive action was blocked to protect device integrity. Please use a safer, bounded alternative.`,
          isError: true
        };
      }
    }

    try {
      const result = await BridgeController.getInstance().exec(effectiveCommand, '', timeoutSeconds);
      const normalizedOutput = BashTool.normalizeShellOutput(result.output);
      const normalizedError = BashTool.normalizeShellOutput(result.error);
      if (result.ok) {
        return {
          toolCallId: toolCallId,
          toolName: 'bash',
          output: normalizedOutput,
          isError: false
        };
      } else {
        const isTimeout = result.exitCode === -124 || normalizedError.toLowerCase().includes('timed out');
        let errMsg = normalizedError.length > 0 ? normalizedError : `Exit code: ${result.exitCode}`;
        if (isTimeout) {
          errMsg += ' — Do NOT repeat an unbounded streaming command (e.g. use `hilog -x`, `ping -c 4`, or pass `timeout_seconds` up to 300 if genuinely long-running).';
        }
        return {
          toolCallId: toolCallId,
          toolName: 'bash',
          output: normalizedOutput,
          error: errMsg,
          isError: true
        };
      }
    } catch (err) {
      return {
        toolCallId: toolCallId,
        toolName: 'bash',
        output: '',
        error: `Execution error: ${err}`,
        isError: true
      };
    }
  }
}
