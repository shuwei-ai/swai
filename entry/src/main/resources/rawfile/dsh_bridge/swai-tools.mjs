/**
 * Swai Tools Plugin for DeepSeek Harness (DSH)
 * Exposes Swai's native privileged tools to DSH agent.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import { defineTool } from '@deepseek-ai/dsh-tools';
import { dispatchSwaiTool } from './bridge-client.mjs';

export const name = 'swai-privileged-tools';
export const inject = ['tools', 'systemPrompt'];

export function apply(ctx) {
  // Inject system prompt guidance so DSH prioritizes native tools
  if (ctx.systemPrompt && typeof ctx.systemPrompt.section === 'function') {
    ctx.systemPrompt.section({
      name: 'tool:swai-environment',
      order: 400,
      text: () => [
        '# Mobile Host Capabilities & Web Navigation',
        '- For viewing, opening, or interacting with webpages (including login pages, search engines, articles), ALWAYS prefer the standard MCP browser tools (`mcp__swai__browser_navigate`, `mcp__swai__browser_snapshot`, `mcp__swai__browser_click`, `mcp__swai__browser_type`, `mcp__swai__browser_evaluate`). This activates the in-app browser overlay and performs resilient CDP automation.',
        '- Do NOT attempt to launch external browser apps (like com.huawei.hmos.browser) via shell commands or ui launch_app unless explicitly requested by the user.',
        '- You have direct access to `bash` for system shell commands (runs with uid 2000), `ui` for HarmonyOS UI automation (uitest/uinput), `offline_code` for Python/JS offline evaluation, and `remote_bash` for remote server execution via SSH.'
      ].join('\n')
    });
  }

  // 1. UI Automation Tool (`ui`)
  ctx.tools.register(defineTool({
    name: 'ui',
    description: 'Native HarmonyOS UI automation tool backed by uitest/uinput and in-process overlay management. Launches apps, dumps visible element layout tree with auto-calculated coordinates, clicks by text/id, types Chinese/UTF-8 text, and handles gestures/swipes.',
    parameters: {
      action: {
        type: 'string',
        enum: ['dump_tree', 'find_and_click', 'click_point', 'click_anchor', 'input_text', 'run_sequence', 'ocr', 'swipe', 'back', 'home', 'launch_app'],
        description: 'UI action to perform',
        required: true
      },
      bundle_name: { type: 'string', description: 'Target bundle name to isolate layout or launch' },
      text: { type: 'string', description: 'Visible text or description to match' },
      id: { type: 'string', description: 'Component resource ID to match' },
      ref: { type: 'string', description: 'Element reference tag e.g. "@4"' },
      x: { type: 'number', description: 'X screen coordinate' },
      y: { type: 'number', description: 'Y screen coordinate' },
      content: { type: 'string', description: 'Text content to type (supports Chinese)' },
      direction: { type: 'string', enum: ['up', 'down', 'left', 'right'], description: 'Swipe direction' },
      steps: { type: 'array', description: 'Ordered step objects for run_sequence' }
    },
    output: {
      schema: {
        type: 'object',
        properties: {
          text: { type: 'string' }
        }
      },
      render: (_args, value) => [{
        type: 'text',
        text: typeof value === 'string' ? value : (value?.text || JSON.stringify(value))
      }]
    },
    async execute(args) {
      const res = await dispatchSwaiTool('ui', args, 45000);
      return { text: res.ok ? (res.output || 'Success') : `Error: ${res.error || 'UI action failed'}` };
    }
  }));

  // 2. High-Privilege HDC Shell Tool (`bash`)
  ctx.tools.register(defineTool({
    name: 'bash',
    description: 'Executes shell commands directly on the HarmonyOS device with uid=2000 (shell) privileges via Swai loopback HDC bridge. Use this for aa/bm/param/hidumper/system inspection commands.',
    parameters: {
      command: { type: 'string', description: 'The shell command line to execute', required: true },
      bundle_name: { type: 'string', description: 'Optional target bundle context' },
      timeout: { type: 'number', description: 'Execution timeout in seconds (default 30)' }
    },
    output: {
      schema: {
        type: 'object',
        properties: {
          text: { type: 'string' }
        }
      },
      render: (_args, value) => [{
        type: 'text',
        text: typeof value === 'string' ? value : (value?.text || JSON.stringify(value))
      }]
    },
    async execute(args) {
      const res = await dispatchSwaiTool('bash', args, ((args.timeout || 30) + 5) * 1000);
      return { text: res.ok ? res.output : `Exit ${res.exitCode}: ${res.error || res.output}` };
    }
  }));

  // 3. Offline Native Code Execution Tool (`offline_code`)
  ctx.tools.register(defineTool({
    name: 'offline_code',
    description: 'Executes Python 3 (CPython 3.13) or JavaScript (V8 JSVM) in an isolated offline sandbox. Ideal for math, regex, complex JSON parsing, and data transformation.',
    parameters: {
      code: { type: 'string', description: 'Source code snippet to execute', required: true },
      language: { type: 'string', enum: ['python', 'javascript'], description: 'Language runtime (default: python)' },
      input_json: { type: 'string', description: 'JSON string injected as __input__ (Python) or input (JS)' },
      timeout_ms: { type: 'number', description: 'Execution timeout in ms (default 15000)' }
    },
    output: {
      schema: {
        type: 'object',
        properties: {
          text: { type: 'string' }
        }
      },
      render: (_args, value) => [{
        type: 'text',
        text: typeof value === 'string' ? value : (value?.text || JSON.stringify(value))
      }]
    },
    async execute(args) {
      const res = await dispatchSwaiTool('offline_code', args, (args.timeout_ms || 15000) + 3000);
      return { text: res.ok ? res.output : `Error: ${res.error || 'Execution failed'}` };
    }
  }));

  // 4. Remote Desktop/Server SSH Execution Tool (`remote_bash`)
  ctx.tools.register(defineTool({
    name: 'remote_bash',
    description: 'Executes shell commands on a remote desktop/server (Linux/macOS) via native SSH-2.0 over TCP. Use when heavy compilations, npm/pip builds, or git repos are required.',
    parameters: {
      command: { type: 'string', description: 'Remote shell command to execute', required: true },
      work_dir: { type: 'string', description: 'Optional remote directory' },
      timeout_seconds: { type: 'number', description: 'Timeout in seconds (default 30)' }
    },
    output: {
      schema: {
        type: 'object',
        properties: {
          text: { type: 'string' }
        }
      },
      render: (_args, value) => [{
        type: 'text',
        text: typeof value === 'string' ? value : (value?.text || JSON.stringify(value))
      }]
    },
    async execute(args) {
      const res = await dispatchSwaiTool('remote_bash', args, ((args.timeout_seconds || 30) + 5) * 1000);
      return { text: res.ok ? res.output : `SSH Exit ${res.exitCode}: ${res.error || res.output}` };
    }
  }));

  // 5. Built-in Browser & CDP Automation Tool (`browser`)
  ctx.tools.register(defineTool({
    name: 'browser',
    description: 'Control the built-in ArkWeb browser on the device via Chrome DevTools Protocol (CDP 9222). Allows navigating to webpages (with live visual popup), extracting readable page content, inspecting interactive elements, clicking buttons/links by index or selector, typing text into form fields, evaluating JavaScript in page context, and drafting/publishing WeChat Official Account articles.',
    parameters: {
      action: {
        type: 'string',
        enum: ['navigate', 'snapshot', 'click', 'type', 'evaluate', 'extract_text', 'wechat_publish'],
        description: 'Browser action to perform: "navigate" (open URL), "snapshot" (extract content & clickable elements), "click" (click element), "type" (input text), "evaluate" (run JS script), "extract_text" (clean text only), "wechat_publish" (draft WeChat article).',
        required: true
      },
      url: { type: 'string', description: 'Target URL to visit (for action: "navigate")' },
      mode: { type: 'string', enum: ['text', 'interactive', 'both'], description: 'Snapshot mode (default: "both")' },
      selector: { type: 'string', description: 'CSS selector of the target element' },
      index: { type: 'number', description: 'Numeric index of element from previous snapshot [1], [2], ...' },
      text: { type: 'string', description: 'Text to type into input field' },
      script: { type: 'string', description: 'JavaScript code to execute in the page context' },
      timeoutMs: { type: 'number', description: 'Navigation timeout in ms (default: 15000)' },
      title: { type: 'string', description: 'WeChat article title (for wechat_publish)' },
      content: { type: 'string', description: 'WeChat article content in Markdown/HTML (for wechat_publish)' },
      author: { type: 'string', description: 'Author name (for wechat_publish)' },
      summary: { type: 'string', description: 'Article summary (for wechat_publish)' },
      themeColor: { type: 'string', description: 'Theme color e.g. blue, green, orange, purple (for wechat_publish)' }
    },
    output: {
      schema: {
        type: 'object',
        properties: {
          text: { type: 'string' }
        }
      },
      render: (_args, value) => [{
        type: 'text',
        text: typeof value === 'string' ? value : (value?.text || JSON.stringify(value))
      }]
    },
    async execute(args) {
      const res = await dispatchSwaiTool('browser', args, ((args.timeoutMs || 25000) + 5000));
      return { text: res.ok ? (res.output || 'Browser action completed successfully') : `Error: ${res.error || res.output || 'Browser action failed'}` };
    }
  }));
}
