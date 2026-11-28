/**
 * Swai Tools Plugin for DeepSeek Harness (DSH)
 * Exposes Swai's native privileged tools, ArkWeb CDP browser tools,
 * and WeChat Official Account publishing tools directly to DSH agent.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { defineTool } from '@deepseek-ai/dsh-tools';
import { dispatchSwaiTool } from './bridge-client.mjs';

export const name = 'swai-privileged-tools';
export const inject = ['tools', 'systemPrompt'];

const TEXT_OUTPUT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    text: { type: 'string', required: true }
  }
};

function renderTextOutput(_args, value) {
  return [{
    type: 'text',
    text: typeof value === 'string' ? value : (value?.text || JSON.stringify(value))
  }];
}

function resolveDshSkillsDir() {
  const dshHome = process.env.DSH_HOME || (process.env.HOME ? path.join(process.env.HOME, '.dsh') : null);
  if (dshHome && dshHome.trim().length > 0) {
    return path.join(dshHome.trim(), 'skills');
  }
  return path.join(process.cwd(), '.dsh', 'skills');
}

// Sanitized UI trajectory buffer (password/input text is NEVER stored verbatim; always redacted)
const UI_TRACE_MAX = 60;
const uiTraceBuffer = [];

function redactUiTargetSummary(action, args) {
  if (!args || typeof args !== 'object') return action;
  if (action === 'input_text') {
    const loc = args.ref || args.text || args.id || args.contains_text || (args.x !== undefined ? `(${args.x},${args.y})` : 'focused');
    return `${loc} <- <输入内容>${args.auto_send ? ' +auto_send' : ''}`;
  }
  if (action === 'run_sequence' && Array.isArray(args.steps)) {
    const ops = args.steps.slice(0, 12).map((s) => {
      const op = String(s?.op || 'step');
      if (op === 'type') {
        const tgt = s?.ref || s?.target || 'input';
        return `type(${tgt}, <输入内容>${s?.auto_send ? ', auto_send' : ''})`;
      }
      if (op === 'click_anchor' && s?.anchor) return `click_anchor(${s.anchor})`;
      if (op === 'launch' && s?.bundle_name) return `launch(${s.bundle_name})`;
      if (op === 'tap') return `tap(${s?.ref || s?.target || s?.text || ''})`;
      return op;
    });
    return ops.join(' -> ');
  }
  if (action === 'click_anchor') return String(args.anchor || '');
  if (action === 'click_point') return `(${args.x},${args.y})`;
  if (action === 'swipe') return String(args.direction || `(${args.x1},${args.y1})->(${args.x2},${args.y2})`);
  return String(args.ref || args.text || args.contains_text || args.id || args.bundle_name || '');
}

function extractUiOutputMeta(outputText, fallbackBundle) {
  const text = String(outputText || '');
  const appMatch = /\bApp:\s*([^\s|]+)/.exec(text);
  const pageMatch = /\bPage:\s*([^\s|]+)/.exec(text);
  const qualityMatch = /\bTreeQuality:\s*([^\s|]+)/.exec(text);
  const effectMatch = /\[ACTION EFFECT\]:\s*([^\r\n]+)/.exec(text);
  return {
    bundleName: appMatch && appMatch[1] !== 'unknown' ? appMatch[1] : (fallbackBundle || ''),
    pagePath: pageMatch && pageMatch[1] !== 'unknown' ? pageMatch[1] : '',
    treeQuality: qualityMatch ? qualityMatch[1] : '',
    effect: effectMatch ? effectMatch[1].trim() : ''
  };
}

function recordUiTrace(action, args, res) {
  const outputText = res?.ok ? (res.output || '') : (res?.error || '');
  const meta = extractUiOutputMeta(outputText, typeof args?.bundle_name === 'string' ? args.bundle_name.trim() : '');
  uiTraceBuffer.push({
    ts: new Date().toISOString(),
    action,
    bundleName: meta.bundleName || 'unknown',
    pagePath: meta.pagePath || '',
    target: redactUiTargetSummary(action, args),
    treeQuality: meta.treeQuality || '',
    effect: meta.effect || '',
    ok: Boolean(res?.ok)
  });
  if (uiTraceBuffer.length > UI_TRACE_MAX) {
    uiTraceBuffer.splice(0, uiTraceBuffer.length - UI_TRACE_MAX);
  }
}

export function getSanitizedUiTrace() {
  return uiTraceBuffer.map((entry) => ({ ...entry }));
}

export function clearSanitizedUiTrace() {
  uiTraceBuffer.length = 0;
}

const REQUIRED_SKILL_SECTIONS = [
  '入口',
  '步骤',
  '容易出错的地方',
  '怎样算办成',
  '什么时候停下交给用户'
];

const SENSITIVE_CONTENT_PATTERNS = [
  /\b\d{6}\b/, // potential 6-digit OTP / PIN
  /(password|passwd|pin_?code|验证码|密码)\s*[:：=]\s*[^\s<]{3,}/i,
  /\b\d{15,19}\b/ // bank card number
];

function validateUiSkillDraft(name, description, markdown) {
  const cleanName = String(name || '').trim().toLowerCase();
  if (!/^[a-z0-9][a-z0-9_-]{1,62}$/.test(cleanName)) {
    return { ok: false, error: 'Skill name must be kebab-case alphanumeric (2-63 chars, e.g. "wechat-daily-digest").' };
  }
  const cleanDesc = String(description || '').trim();
  if (cleanDesc.length < 6) {
    return { ok: false, error: 'Skill description must be a clear non-empty sentence.' };
  }
  const body = String(markdown || '').trim();
  if (body.length < 40) {
    return { ok: false, error: 'Skill markdown body is too short.' };
  }
  const missing = REQUIRED_SKILL_SECTIONS.filter((sec) => !body.includes(sec));
  if (missing.length > 0) {
    return {
      ok: false,
      error: `Skill markdown must contain the 5 standard sections (${REQUIRED_SKILL_SECTIONS.join(' / ')}). Missing: ${missing.join(', ')}`
    };
  }
  for (const pat of SENSITIVE_CONTENT_PATTERNS) {
    if (pat.test(body) || pat.test(cleanDesc)) {
      return {
        ok: false,
        error: 'Rejected potential literal sensitive data (OTP/password/card number). Parameterize user inputs with placeholders like <联系人> or <内容>.'
      };
    }
  }
  return { ok: true, name: cleanName, description: cleanDesc.replace(/\s+/g, ' '), markdown: body };
}

function shellSingleQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function resolveWritableTempDir() {
  const candidates = [
    process.env.TMPDIR,
    process.env.HOME ? path.join(process.env.HOME, '.tmp') : null,
    '/data/storage/el2/base/haps/entry/files/workspace/.tmp'
  ];
  for (const dir of candidates) {
    if (dir && dir !== '/tmp') {
      return dir;
    }
  }
  return '/data/storage/el2/base/haps/entry/files/workspace/.tmp';
}

function detectImageMediaType(targetPath, data) {
  const ext = path.extname(targetPath).toLowerCase();
  if (ext === '.png') return 'image/png';
  if (ext === '.webp') return 'image/webp';
  if (ext === '.gif') return 'image/gif';
  if (ext === '.jpg' || ext === '.jpeg') return 'image/jpeg';

  if (data && data.length >= 8 &&
      data[0] === 0x89 && data[1] === 0x50 && data[2] === 0x4e && data[3] === 0x47) {
    return 'image/png';
  }
  if (data && data.length >= 12 &&
      data.toString('ascii', 0, 4) === 'RIFF' && data.toString('ascii', 8, 12) === 'WEBP') {
    return 'image/webp';
  }
  if (data && data.length >= 6) {
    const sig = data.toString('ascii', 0, 6);
    if (sig === 'GIF87a' || sig === 'GIF89a') {
      return 'image/gif';
    }
  }
  return 'image/jpeg';
}

// Lazy-loaded drivers to keep DSH cold startup fast
let cdpDriverInstance = null;
async function getCdpDriver() {
  if (!cdpDriverInstance) {
    const mod = await import('./cdp-driver.mjs');
    cdpDriverInstance = new mod.CdpDriver({ port: 9222 });
  }
  return cdpDriverInstance;
}

let wechatPosterInstance = null;
async function getWeChatPoster() {
  if (!wechatPosterInstance) {
    const cdp = await getCdpDriver();
    const mod = await import('./wechat-poster.mjs');
    wechatPosterInstance = new mod.WeChatPoster(cdp);
  }
  return wechatPosterInstance;
}

function notifyShowBrowserOverlay(signal) {
  dispatchSwaiTool('ui', { action: 'show_browser_overlay' }, 5000, { signal }).catch(() => {});
}

const CAPTURE_IMAGE_VALUE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    attachmentId: { type: 'string', required: true },
    mediaType: {
      type: 'string',
      enum: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
      required: true
    },
    bytes: { type: 'integer', required: true },
    width: { type: 'integer', required: true },
    height: { type: 'integer', required: true },
    name: { type: 'string' },
    originalDimensions: {
      type: 'object',
      additionalProperties: false,
      properties: {
        width: { type: 'integer', required: true },
        height: { type: 'integer', required: true }
      }
    }
  }
};

const WECHAT_THEMES = [
  'default',
  'grace',
  'simple',
  'modern',
  'editorial',
  'cyber-minimal',
  'aurora-warm',
  'neo-brutalism'
];

export function apply(ctx) {
  // Inject system prompt guidance so DSH uses mobile-native tools efficiently
  if (ctx.systemPrompt && typeof ctx.systemPrompt.section === 'function') {
    ctx.systemPrompt.section({
      name: 'tool:swai-environment',
      order: 400,
      text: () => [
        '# Mobile Host Capabilities & Web Navigation',
        '- For viewing, opening, or interacting with webpages (including login pages, search engines, articles), ALWAYS prefer the in-app ArkWeb browser tools (`browser_navigate`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_evaluate`, `browser_extract_text`). This activates the in-app ArkWeb overlay and performs resilient CDP automation.',
        '- For WeChat Official Account formatting and draft publishing, use `wechat_render_article` and `wechat_post_draft`.',
        '- Do NOT attempt to launch external browser apps (like com.huawei.hmos.browser) via shell commands or `ui(action="launch_app")` unless explicitly requested by the user.',
        '- For HarmonyOS UI automation, check loaded DSH skills (such as `hmos-ui-automation` or app-specific skills like `wechat-ui-automation`) via `skill` tool when automating phone apps. Use `ui` (`action="list_apps"` to discover real HarmonyOS bundle names, `dump_tree` reading App/Page/TreeQuality/@ref/id, `click_anchor` for unlabeled icons, `ocr` automatically cropped to the target window, and `run_sequence` for deterministic multi-step flows). After completing a repeatable multi-step UI task, use `ui_skill_save` (`inspect_trace` -> `save`) to save a reusable 5-section skill.',
        '- For inspecting the current device screen, call `capture_screen` (hardware capture via `snapshot_display`/`uitest screenCap`). Vision-capable models receive the image inline; text-only models receive the saved file path and can follow up with `ui(action="ocr")` or `ui(action="dump_tree")`.',
        '- You have direct access to `glob` and `grep` (in-process native filesystem search), `read`/`write`/`edit` for workspace files, `bash` for HarmonyOS system commands (runs with `uid=2000` and automatically bridges `/data/storage/` sandbox paths via debug mount), `offline_code` for Python 3.13 / JS V8 execution (supports `code` or workspace `path`, `import hdc`, `import pip`, and `PIL`), and `remote_bash` for remote server execution via SSH.'
      ].join('\n')
    });
  }

  // 1. UI Automation Tool (`ui`)
  ctx.tools.register(defineTool({
    name: 'ui',
    description: 'High-level native HarmonyOS UI automation tool backed by uitest/uinput, CoreVision OCR, and in-process overlay management. Launches apps (supporting split screen), dumps visible element layout tree with auto-calculated coordinates, clicks by ref/text/id/anchor, types Chinese/UTF-8 text, and executes multi-step sequences.',
    parameters: {
      action: {
        type: 'string',
        enum: [
          'dump_tree',
          'find_and_click',
          'click_point',
          'click_anchor',
          'input_text',
          'run_sequence',
          'ocr',
          'swipe',
          'back',
          'home',
          'launch_app',
          'list_apps',
          'hide_overlay',
          'show_overlay',
          'minimize_overlay'
        ],
        description: 'UI action to perform',
        required: true
      },
      bundle_name: { type: 'string', description: 'Target bundle name to isolate layout or launch (e.g. "com.huawei.hmos.notepad")' },
      ability_name: { type: 'string', description: 'Target UIAbility name for launch_app (default: "EntryAbility")' },
      clone_index: { type: 'number', description: 'For launch_app when a "选择打开方式" app-clone chooser appears: 0-based index to auto-select (default: 0 = first/main app)' },
      auto_select_clone: { type: 'boolean', description: 'For launch_app: automatically select clone_index if "选择打开方式" chooser appears (default: true)' },
      text: { type: 'string', description: 'Exact or preferred visible text/hint/description to match' },
      contains_text: { type: 'string', description: 'Case-insensitive substring match against element text/hint/description/id' },
      id: { type: 'string', description: 'Component resource ID to match' },
      type: { type: 'string', description: 'Component type filter (e.g. "Button", "TextInput", "ListItem")' },
      ref: { type: 'string', description: 'Element reference tag from dump_tree e.g. "@4" or "4"' },
      index: { type: 'number', description: '0-based match index when multiple elements match (default: 0)' },
      clickable_only: { type: 'boolean', description: 'For dump_tree: only show clickable nodes (default: false)' },
      include_all: { type: 'boolean', description: 'For dump_tree: include unlabeled/non-interactive container nodes (default: false)' },
      limit: { type: 'number', description: 'For dump_tree: max nodes to return (default: 100)' },
      use_ocr: { type: 'boolean', description: 'For dump_tree or find_and_click: supplement or fallback to CoreVision OCR' },
      anchor: {
        type: 'string',
        enum: ['search', 'back', 'more', 'chat_input', 'voice_toggle', 'send'],
        description: 'Visual semantic anchor for click_anchor'
      },
      x: { type: 'number', description: 'Screen X coordinate (for click_point or input_text target focus)' },
      y: { type: 'number', description: 'Screen Y coordinate (for click_point or input_text target focus)' },
      click_mode: {
        type: 'string',
        enum: ['click', 'double', 'long'],
        description: 'Click variant for find_and_click / click_point (default: "click")'
      },
      content: { type: 'string', description: 'Text content to type (supports Chinese/UTF-8)' },
      clear_first: { type: 'boolean', description: 'For input_text: clear existing text before typing (default: true)' },
      auto_send: { type: 'boolean', description: 'For input_text: automatically click send button after typing (default: false)' },
      direction: { type: 'string', enum: ['up', 'down', 'left', 'right'], description: 'Swipe direction when coordinates are omitted' },
      x1: { type: 'number', description: 'Swipe start X coordinate' },
      y1: { type: 'number', description: 'Swipe start Y coordinate' },
      x2: { type: 'number', description: 'Swipe end X coordinate' },
      y2: { type: 'number', description: 'Swipe end Y coordinate' },
      duration_ms: { type: 'number', description: 'Swipe duration in ms (default: 350, range: 100-3000)' },
      steps: {
        type: 'array',
        description: 'Ordered step objects for run_sequence: {op: "launch"|"tap"|"click_anchor"|"type"|"clear"|"scroll"|"swipe"|"key"|"back"|"wait"|"assert", ...}',
        items: {
          type: 'object',
          additionalProperties: true
        }
      }
    },
    output: {
      schema: TEXT_OUTPUT_SCHEMA,
      render: renderTextOutput
    },
    async execute(args, exec) {
      const res = await dispatchSwaiTool('ui', args, 45000, { signal: exec?.signal });
      recordUiTrace(String(args?.action || 'unknown'), args, res);
      return { text: res.ok ? (res.output || 'Success') : `Error: ${res.error || 'UI action failed'}` };
    }
  }));

  // 2. Offline Native Code Execution Tool (`offline_code`)
  ctx.tools.register(defineTool({
    name: 'offline_code',
    description: 'Executes Python 3 (CPython 3.13) or JavaScript (V8 JSVM) in an isolated offline sandbox. Supports inline `code` or a workspace script `path`. Python supports privileged HarmonyOS shell commands via `import hdc; res = hdc.shell("cmd")` or `subprocess.run`, `import pip; pip.install("pkg")`, and graphics with `PIL`.',
    parameters: {
      path: { type: 'string', description: 'Optional relative or sandbox path of the script file to execute (e.g. "solution.py"). Either `code` or `path` must be provided.' },
      code: { type: 'string', description: 'Optional source code snippet to execute directly. Either `code` or `path` must be provided.' },
      language: { type: 'string', enum: ['python', 'javascript'], description: 'Language runtime (default: python, auto-detected from file extension when path is specified)' },
      input_json: { type: 'string', description: 'JSON string injected as __input__ (Python) or input (JS)' },
      timeout_ms: { type: 'number', description: 'Execution timeout in ms (100-60000, default: 15000)' }
    },
    output: {
      schema: TEXT_OUTPUT_SCHEMA,
      render: renderTextOutput
    },
    async execute(args, exec) {
      const hasCode = typeof args?.code === 'string' && args.code.trim().length > 0;
      const hasPath = typeof args?.path === 'string' && args.path.trim().length > 0;
      if (!hasCode && !hasPath) {
        return { text: 'Error: Either `code` or `path` must be provided.' };
      }
      const timeoutMs = typeof args?.timeout_ms === 'number' && Number.isFinite(args.timeout_ms)
        ? Math.min(Math.max(Math.round(args.timeout_ms), 100), 60000)
        : 15000;
      const res = await dispatchSwaiTool('offline_code', args, timeoutMs + 3000, { signal: exec?.signal });
      return { text: res.ok ? res.output : `Error: ${res.error || 'Execution failed'}` };
    }
  }));

  // 3. Remote Desktop/Server SSH Execution Tool (`remote_bash`)
  ctx.tools.register(defineTool({
    name: 'remote_bash',
    description: 'Executes shell commands on a remote desktop/server (Linux/macOS) via native SSH-2.0 over TCP. Use when heavy compilations, npm/pip builds, or git repos are required.',
    parameters: {
      command: { type: 'string', description: 'Remote shell command to execute', required: true },
      work_dir: { type: 'string', description: 'Optional remote directory' },
      timeout_seconds: { type: 'number', description: 'Timeout in seconds (3-300, default: 30)' }
    },
    output: {
      schema: TEXT_OUTPUT_SCHEMA,
      render: renderTextOutput
    },
    async execute(args, exec) {
      const timeoutSeconds = typeof args?.timeout_seconds === 'number' && Number.isFinite(args.timeout_seconds)
        ? Math.min(Math.max(Math.round(args.timeout_seconds), 3), 300)
        : 30;
      const res = await dispatchSwaiTool('remote_bash', args, (timeoutSeconds + 5) * 1000, { signal: exec?.signal });
      return { text: res.ok ? res.output : `SSH Exit ${res.exitCode}: ${res.error || res.output}` };
    }
  }));

  // 4. Native Hardware Screen Capture Tool (`capture_screen`)
  ctx.tools.register(defineTool({
    name: 'capture_screen',
    description: 'Captures the current HarmonyOS device screen natively using `snapshot_display` / `uitest screenCap` into the workspace and attaches the image for visual inspection when the active model supports image input.',
    parameters: {
      output_path: {
        type: 'string',
        description: 'Optional destination file path (defaults to a unique .jpeg inside the workspace .tmp directory)'
      }
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          text: { type: 'string', required: true },
          path: { type: 'string' },
          image: CAPTURE_IMAGE_VALUE_SCHEMA
        }
      },
      render: (_args, value) => {
        if (value?.image) {
          return [
            { type: 'text', text: value.text || `Captured screen to ${value.path || 'file'}.` },
            { type: 'image', attachment: value.image }
          ];
        }
        return [{ type: 'text', text: value?.text || '' }];
      },
      presentationMeta: (_args, value) => (value?.path ? { path: value.path } : undefined)
    },
    async execute(args, exec) {
      if (exec?.signal?.aborted) {
        return { text: 'Error: Screen capture aborted.' };
      }

      const tempDir = resolveWritableTempDir();
      const rawOut = typeof args?.output_path === 'string' ? args.output_path.trim() : '';
      const targetPath = rawOut.length > 0
        ? (path.isAbsolute(rawOut) ? rawOut : path.resolve(process.cwd(), rawOut))
        : path.join(tempDir, `screen_${Date.now()}_${randomUUID().slice(0, 8)}.jpeg`);

      await fsp.mkdir(path.dirname(targetPath), { recursive: true });

      const escapedTarget = shellSingleQuote(targetPath);
      const isJpeg = targetPath.toLowerCase().endsWith('.jpeg');
      const fallbackTmp = shellSingleQuote(path.join(tempDir, `_snap_${randomUUID().slice(0, 8)}.jpeg`));
      const tmpLocal = shellSingleQuote(`/data/local/tmp/_swai_cap_${randomUUID().slice(0, 8)}.jpeg`);
      const snapCmd = isJpeg
        ? `rm -f ${escapedTarget} ${tmpLocal} && ((snapshot_display -f ${escapedTarget} >/dev/null 2>&1 && [ -s ${escapedTarget} ]) || (snapshot_display -f ${tmpLocal} >/dev/null 2>&1 && [ -s ${tmpLocal} ] && cp ${tmpLocal} ${escapedTarget}) || (uitest screenCap -p ${tmpLocal} >/dev/null 2>&1 && [ -s ${tmpLocal} ] && cp ${tmpLocal} ${escapedTarget})) && chmod 666 ${escapedTarget} 2>/dev/null; rm -f ${tmpLocal}; [ -s ${escapedTarget} ]`
        : `rm -f ${escapedTarget} ${fallbackTmp} ${tmpLocal} && ((uitest screenCap -p ${escapedTarget} >/dev/null 2>&1 && [ -s ${escapedTarget} ]) || (uitest screenCap -p ${tmpLocal} >/dev/null 2>&1 && [ -s ${tmpLocal} ] && cp ${tmpLocal} ${escapedTarget}) || (snapshot_display -f ${tmpLocal} >/dev/null 2>&1 && [ -s ${tmpLocal} ] && cp ${tmpLocal} ${escapedTarget})) && chmod 666 ${escapedTarget} 2>/dev/null; rm -f ${tmpLocal}; [ -s ${escapedTarget} ]`;

      const snapRes = await dispatchSwaiTool('bash', { command: snapCmd, timeout_seconds: 15 }, 20000, { signal: exec?.signal });
      if (!snapRes.ok) {
        return {
          text: `Error: Screen capture failed at ${targetPath}: ${snapRes.error || snapRes.output || 'unknown error'}`
        };
      }

      let data;
      try {
        data = await fsp.readFile(targetPath);
      } catch (readErr) {
        return {
          text: `Screen captured at ${targetPath}, but failed to read file from sandbox: ${readErr?.message || String(readErr)}`,
          path: targetPath
        };
      }

      const mediaType = detectImageMediaType(targetPath, data);
      const attachments = typeof ctx.get === 'function' ? ctx.get('attachments') : undefined;
      const llm = typeof ctx.get === 'function' ? ctx.get('llm') : undefined;
      const routed = exec?.agent?.session?.requestHeader?.()?.config;
      const provider = routed?.provider ?? exec?.agent?.options?.provider;
      const model = routed?.model ?? exec?.agent?.options?.model;

      let supportsImages = false;
      if (attachments && llm && provider && model && typeof llm.resolveModelInfo === 'function') {
        try {
          const active = await llm.resolveModelInfo(provider, model, exec?.signal);
          supportsImages = Array.isArray(active?.inputModalities) && active.inputModalities.includes('image');
        } catch (_) {
          supportsImages = false;
        }
      }

      if (supportsImages && attachments && typeof attachments.saveImage === 'function') {
        try {
          const ref = await attachments.saveImage({
            data,
            mediaType,
            name: path.basename(targetPath)
          });
          const imageValue = {
            attachmentId: ref.attachmentId,
            mediaType: ref.mediaType,
            bytes: Math.trunc(ref.bytes),
            width: Math.trunc(ref.width),
            height: Math.trunc(ref.height),
            ...(ref.name !== undefined ? { name: ref.name } : {}),
            ...(ref.originalDimensions !== undefined
              ? {
                  originalDimensions: {
                    width: Math.trunc(ref.originalDimensions.width),
                    height: Math.trunc(ref.originalDimensions.height)
                  }
                }
              : {})
          };
          return {
            text: `Captured screen to ${targetPath} (${imageValue.width}x${imageValue.height}, ${Math.round(imageValue.bytes / 1024)} KB ${imageValue.mediaType}).`,
            path: targetPath,
            image: imageValue
          };
        } catch (attachErr) {
          return {
            text: `Captured screen to ${targetPath} (${data.length} bytes), but failed to attach image (${attachErr?.message || String(attachErr)}). You can inspect UI via ui(action="ocr") or ui(action="dump_tree").`,
            path: targetPath
          };
        }
      }

      return {
        text: `Captured screen to ${targetPath} (${data.length} bytes, ${mediaType}). Current model does not support direct image input or attachment service is unavailable; use ui(action="ocr") or ui(action="dump_tree") to inspect screen content.`,
        path: targetPath
      };
    }
  }));

  // 5. In-App ArkWeb CDP Browser Navigate (`browser_navigate`)
  ctx.tools.register(defineTool({
    name: 'browser_navigate',
    description: 'Navigate the in-app ArkWeb browser to a URL and inspect the loaded page.',
    parameters: {
      url: { type: 'string', description: 'Target website URL (e.g. https://developer.huawei.com)', required: true },
      timeoutMs: { type: 'number', description: 'Navigation timeout in ms (default 20000)' }
    },
    output: {
      schema: TEXT_OUTPUT_SCHEMA,
      render: renderTextOutput
    },
    async execute(args, exec) {
      notifyShowBrowserOverlay(exec?.signal);
      const cdp = await getCdpDriver();
      const navRes = await cdp.navigate(args.url, args.timeoutMs || 20000);
      const snap = await cdp.snapshot('both');

      let out = `Successfully navigated to: ${navRes.url}\nTitle: ${navRes.title}\nLoad duration: ${navRes.durationMs}ms\n\n`;
      if (snap.text) {
        out += `--- Content Summary ---\n${snap.text.substring(0, 3000)}\n\n`;
      }
      if (snap.elements && snap.elements.length > 0) {
        out += `--- Key Interactive Elements (${snap.elements.length} found) ---\n`;
        const maxShow = Math.min(snap.elements.length, 25);
        for (let i = 0; i < maxShow; i++) {
          const el = snap.elements[i];
          let desc = `[${el.idx}] <${el.tag}`;
          if (el.type) desc += ` type="${el.type}"`;
          desc += `> ${el.label || el.href || ''}`;
          out += `${desc}\n`;
        }
      }
      return { text: out.trim() };
    }
  }));

  // 6. Browser Snapshot (`browser_snapshot`)
  ctx.tools.register(defineTool({
    name: 'browser_snapshot',
    description: 'Capture readable page text and index-mapped interactive elements from current browser tab.',
    parameters: {
      mode: { type: 'string', enum: ['both', 'text', 'interactive'], description: 'Snapshot mode (default "both")' }
    },
    output: {
      schema: TEXT_OUTPUT_SCHEMA,
      render: renderTextOutput
    },
    async execute(args) {
      const cdp = await getCdpDriver();
      const snap = await cdp.snapshot(args?.mode || 'both');
      let out = `Page Title: ${snap.title}\nURL: ${snap.url}\n\n`;
      if (snap.text) {
        out += `--- Page Text ---\n${snap.text}\n\n`;
      }
      if (snap.elements && snap.elements.length > 0) {
        out += `--- Interactive Elements ---\n`;
        for (const el of snap.elements) {
          out += `[${el.idx}] <${el.tag}${el.type ? ' type="' + el.type + '"' : ''}> ${el.label || el.href || ''}\n`;
        }
      }
      return { text: out.trim() };
    }
  }));

  // 7. Browser Click (`browser_click`)
  ctx.tools.register(defineTool({
    name: 'browser_click',
    description: 'Click an interactive button, link, or element on the current webpage by index [1], [2] or selector.',
    parameters: {
      index: { type: 'number', description: 'Numeric index from previous snapshot e.g. 1, 2' },
      selector: { type: 'string', description: 'Optional CSS selector' }
    },
    output: {
      schema: TEXT_OUTPUT_SCHEMA,
      render: renderTextOutput
    },
    async execute(args) {
      const cdp = await getCdpDriver();
      const res = await cdp.click(args || {});
      return { text: res.success ? res.message : `Error: ${res.message}` };
    }
  }));

  // 8. Browser Type (`browser_type`)
  ctx.tools.register(defineTool({
    name: 'browser_type',
    description: 'Type text into an input box or textarea on the current webpage.',
    parameters: {
      text: { type: 'string', description: 'Text to input', required: true },
      index: { type: 'number', description: 'Numeric index from previous snapshot' },
      selector: { type: 'string', description: 'Optional CSS selector' }
    },
    output: {
      schema: TEXT_OUTPUT_SCHEMA,
      render: renderTextOutput
    },
    async execute(args) {
      const cdp = await getCdpDriver();
      const res = await cdp.type(args || {});
      return { text: res.success ? res.message : `Error: ${res.message}` };
    }
  }));

  // 9. Browser Evaluate (`browser_evaluate`)
  ctx.tools.register(defineTool({
    name: 'browser_evaluate',
    description: 'Execute arbitrary JavaScript expression in the ArkWeb page context.',
    parameters: {
      script: { type: 'string', description: 'JavaScript code expression', required: true }
    },
    output: {
      schema: TEXT_OUTPUT_SCHEMA,
      render: renderTextOutput
    },
    async execute(args) {
      const cdp = await getCdpDriver();
      const val = await cdp.evaluate(args.script);
      return { text: typeof val === 'string' ? val : JSON.stringify(val, null, 2) };
    }
  }));

  // 10. Browser Extract Text (`browser_extract_text`)
  ctx.tools.register(defineTool({
    name: 'browser_extract_text',
    description: 'Quickly extract clean, readable article body text without HTML boilerplate.',
    parameters: {},
    output: {
      schema: TEXT_OUTPUT_SCHEMA,
      render: renderTextOutput
    },
    async execute() {
      const cdp = await getCdpDriver();
      const txt = await cdp.extractText();
      return { text: txt };
    }
  }));

  // 11. WeChat Article Renderer (`wechat_render_article`)
  ctx.tools.register(defineTool({
    name: 'wechat_render_article',
    description: 'Convert Markdown into WeChat Official Account ready HTML with inline CSS styles.',
    parameters: {
      markdown: { type: 'string', description: 'Markdown source text or file path on device', required: true },
      theme: { type: 'string', enum: WECHAT_THEMES, description: 'Typography theme' },
      color: { type: 'string', description: 'Primary color (e.g. blue, green, #07c160)' },
      title: { type: 'string', description: 'Optional title override' },
      author: { type: 'string', description: 'Optional author override' }
    },
    output: {
      schema: TEXT_OUTPUT_SCHEMA,
      render: renderTextOutput
    },
    async execute(args) {
      try {
        let mdContent = args.markdown;
        if (typeof mdContent === 'string' && fs.existsSync(mdContent)) {
          mdContent = fs.readFileSync(mdContent, 'utf-8');
        }
        const { formatMarkdownToWechat } = await import('./wechat-formatter.mjs');
        const formatted = await formatMarkdownToWechat(mdContent, {
          theme: args.theme || 'default',
          color: args.color,
          title: args.title,
          author: args.author
        });
        const out = `Title: ${formatted.title}\nAuthor: ${formatted.author || '(none)'}\nSummary: ${formatted.summary}\nHTML Length: ${formatted.html.length} chars\n\nPreview HTML (first 500 chars):\n${formatted.html.slice(0, 500)}...`;
        return { text: out };
      } catch (err) {
        return { text: `Error: Markdown 排版失败: ${err.message}` };
      }
    }
  }));

  // 12. WeChat Article Draft Publisher (`wechat_post_draft`)
  ctx.tools.register(defineTool({
    name: 'wechat_post_draft',
    description: 'Automatically publish or save a Markdown article to WeChat Official Account (微信公众号) draft box via ArkWeb browser automation.',
    parameters: {
      markdown: { type: 'string', description: 'Markdown text content or local file path to publish', required: true },
      title: { type: 'string', description: 'Optional article title override' },
      author: { type: 'string', description: 'Optional author name override' },
      summary: { type: 'string', description: 'Optional summary / description override' },
      theme: { type: 'string', enum: WECHAT_THEMES, description: 'Typography theme (default "default")' },
      color: { type: 'string', description: 'Primary theme color preset or hex' },
      saveDraft: { type: 'boolean', description: 'Whether to click save draft automatically (default true)' }
    },
    output: {
      schema: TEXT_OUTPUT_SCHEMA,
      render: renderTextOutput
    },
    async execute(args, exec) {
      try {
        notifyShowBrowserOverlay(exec?.signal);
        let mdContent = args.markdown;
        if (typeof mdContent === 'string' && fs.existsSync(mdContent)) {
          mdContent = fs.readFileSync(mdContent, 'utf-8');
        }
        const poster = await getWeChatPoster();
        const res = await poster.publishMarkdown(mdContent, {
          title: args.title,
          author: args.author,
          summary: args.summary,
          theme: args.theme || 'default',
          color: args.color,
          saveDraft: args.saveDraft !== false
        });

        if (res.status === 'need_login') {
          return {
            text: `⚠️ 微信公众号尚未登录！\n\n${res.message}\n已解析文章标题: ${res.title}\n摘要: ${res.summary}\n\n👉 提示：请在真机屏幕右侧浏览器中扫码登录微信公众号，登录完成后再次调用此命令即可直接保存草稿！`
          };
        }

        return {
          text: `✅ 微信公众号草稿创建成功！\n\n标题: ${res.title}\n作者: ${res.author || '(未设置)'}\n摘要: ${res.summary}\n保存状态: ${res.saveResult}${res.appmsgid ? '\nDraft ID: ' + res.appmsgid : ''}`
        };
      } catch (err) {
        return { text: `Error: 微信公众号草稿自动化失败: ${err.message}` };
      }
    }
  }));

  // 13. UI Automation Trajectory Inspector & Skill Saver (`ui_skill_save`)
  ctx.tools.register(defineTool({
    name: 'ui_skill_save',
    description: 'Inspect sanitized HarmonyOS UI automation action trajectory (with typed inputs redacted) or save a verified 5-section UI automation SKILL.md directly into DSH native skills directory (.dsh/skills) for immediate reuse.',
    parameters: {
      mode: {
        type: 'string',
        enum: ['inspect_trace', 'save'],
        description: 'Operation mode: "inspect_trace" returns recent sanitized ui actions (bundle, pagePath, target, effect); "save" validates and writes SKILL.md (default: "save").'
      },
      name: { type: 'string', description: 'Kebab-case skill name (e.g. "wechat-group-summary"). Required when mode="save".' },
      description: { type: 'string', description: 'One-sentence description of when to use this skill. Required when mode="save".' },
      markdown: {
        type: 'string',
        description: 'Structured skill body containing the 5 sections: 入口, 步骤, 容易出错的地方, 怎样算办成, 什么时候停下交给用户. Use placeholders like <联系人> instead of literal typed text.'
      },
      status: {
        type: 'string',
        enum: ['trial', 'active'],
        description: 'Lifecycle maturity of the saved skill (default: "trial").'
      },
      apps: {
        type: 'array',
        description: 'Optional HarmonyOS bundle names used by this skill (e.g. ["com.tencent.wechat"]).',
        items: { type: 'string' }
      }
    },
    output: {
      schema: TEXT_OUTPUT_SCHEMA,
      render: renderTextOutput
    },
    async execute(args) {
      const mode = String(args?.mode || 'save').trim();
      if (mode === 'inspect_trace') {
        if (uiTraceBuffer.length === 0) {
          return { text: 'No UI automation steps recorded in this session yet.' };
        }
        const lines = [`Sanitized UI Trajectory (${uiTraceBuffer.length} steps, typed inputs redacted):`];
        for (let i = 0; i < uiTraceBuffer.length; i++) {
          const item = uiTraceBuffer[i];
          const pageSuffix = item.pagePath ? ` page=${item.pagePath}` : '';
          const effSuffix = item.effect ? ` -> ${item.effect}` : '';
          const status = item.ok ? 'OK' : 'FAIL';
          lines.push(`${i + 1}. [${status}] app=${item.bundleName}${pageSuffix} | ${item.action} ${item.target}${effSuffix}`);
        }
        return { text: lines.join('\n') };
      }

      if (mode !== 'save') {
        return { text: `Error: Unknown ui_skill_save mode "${mode}". Use "inspect_trace" or "save".` };
      }

      const validation = validateUiSkillDraft(args?.name, args?.description, args?.markdown);
      if (!validation.ok) {
        return { text: `Error: ${validation.error}` };
      }

      const status = args?.status === 'active' ? 'active' : 'trial';
      const appsList = Array.isArray(args?.apps)
        ? args.apps.map((a) => String(a || '').trim()).filter((a) => a.length > 0)
        : [];
      const metadataLines = [
        'metadata:',
        `  status: ${JSON.stringify(status)}`,
        '  source: "ui-automation"'
      ];
      if (appsList.length > 0) {
        metadataLines.push('  apps:');
        for (const appPkg of appsList) {
          metadataLines.push(`    - ${JSON.stringify(appPkg)}`);
        }
      }

      const skillDoc = [
        '---',
        `name: ${JSON.stringify(validation.name)}`,
        `description: ${JSON.stringify(validation.description)}`,
        ...metadataLines,
        '---',
        '',
        validation.markdown,
        ''
      ].join('\n');

      const skillsRoot = resolveDshSkillsDir();
      const targetDir = path.join(skillsRoot, validation.name);
      const targetPath = path.join(targetDir, 'SKILL.md');
      await fsp.mkdir(targetDir, { recursive: true });
      await fsp.writeFile(targetPath, skillDoc, 'utf-8');

      return {
        text: `Saved UI automation skill "${validation.name}" (status=${status}) to ${targetPath}. It is now discoverable via the DSH skill catalog and /${validation.name}.`
      };
    }
  }));

  // 14. Background Thinking Capsule lifecycle hooks (DSH Cordis agent events -> Swai host)
  if (typeof ctx?.on === 'function') {
    const activeAgents = new Set();
    const latestReplyByAgent = new Map();
    const latestErrorByAgent = new Map();
    let lastThinkingEmitMs = 0;

    const extractReplyText = (chunk) => {
      if (!chunk) return '';
      if (typeof chunk === 'string') return chunk;
      if (typeof chunk === 'object') {
        const ctype = String(chunk.type || '').toLowerCase();
        if (ctype.includes('reason') || ctype.includes('thinking') || ctype.includes('tool')) {
          return '';
        }
        if (typeof chunk.text === 'string') return chunk.text;
        if (typeof chunk.delta === 'string') return chunk.delta;
        if (typeof chunk.content === 'string') return chunk.content;
      }
      return '';
    };

    const sanitizeSummary = (raw) => {
      if (!raw || typeof raw !== 'string') return '';
      const oneLine = raw
        .replace(/```[\s\S]*?```/g, ' ')
        .replace(/[*_`#>]+/g, '')
        .replace(/\s+/g, ' ')
        .trim();
      return oneLine.length > 32 ? `${oneLine.slice(0, 32)}…` : oneLine;
    };

    try {
      ctx.on('agent/status', (payload) => {
        try {
          const agentId = String(payload?.agent?.id || payload?.agentId || 'default');
          const status = String(payload?.status || '');
          if (status === 'running') {
            activeAgents.add(agentId);
            latestErrorByAgent.delete(agentId);
            latestReplyByAgent.set(agentId, '');
            dispatchSwaiTool('swai_capsule_event', { event: 'turn_start' }, 2000).catch(() => {});
          } else if (status === 'idle') {
            activeAgents.delete(agentId);
            if (activeAgents.size === 0) {
              const errMsg = latestErrorByAgent.get(agentId) || '';
              latestErrorByAgent.delete(agentId);
              const summary = sanitizeSummary(latestReplyByAgent.get(agentId) || '');
              latestReplyByAgent.delete(agentId);
              dispatchSwaiTool(
                'swai_capsule_event',
                {
                  event: errMsg ? 'turn_error' : 'turn_done',
                  summary,
                  error: errMsg
                },
                2000
              ).catch(() => {});
            }
          }
        } catch (_) {}
      }, { global: true });

      ctx.on('agent/error', (payload) => {
        try {
          const agentId = String(payload?.agent?.id || payload?.agentId || 'default');
          const rawErr = payload?.error?.message || payload?.error || '任务执行出错';
          const shortErr = String(rawErr).replace(/\s+/g, ' ').trim().slice(0, 48);
          latestErrorByAgent.set(agentId, shortErr);
          dispatchSwaiTool('swai_capsule_event', { event: 'turn_error', error: shortErr }, 2000).catch(() => {});
        } catch (_) {}
      }, { global: true });

      ctx.on('agent/assistant-stream', (payload) => {
        try {
          const agentId = String(payload?.agent?.id || payload?.agentId || 'default');
          const frame = payload?.frame;
          if (!frame) return;
          if (frame.type === 'start') {
            latestReplyByAgent.set(agentId, '');
            const now = Date.now();
            if (now - lastThinkingEmitMs >= 1500) {
              lastThinkingEmitMs = now;
              dispatchSwaiTool('swai_capsule_event', { event: 'thinking' }, 2000).catch(() => {});
            }
          } else if (frame.type === 'chunk') {
            const delta = extractReplyText(frame.chunk);
            if (delta.length > 0) {
              const prev = latestReplyByAgent.get(agentId) || '';
              if (prev.length < 240) {
                latestReplyByAgent.set(agentId, (prev + delta).slice(0, 240));
              }
            }
          }
        } catch (_) {}
      }, { global: true });
    } catch (_) {
      // Ignore if host Cordis instance restricts global subscriptions
    }
  }
}
