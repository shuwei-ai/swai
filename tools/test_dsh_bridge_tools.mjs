#!/usr/bin/env node
/**
 * Contract, integration, and startup-benchmark tests for DSH bridge tools:
 * - swai-tools.mjs (schema validation via real @deepseek-ai/dsh-tools, 12 tools, capture_screen, lazy loading)
 * - bridge-client.mjs (AbortController -> POST /v1/tool/cancel)
 * - swai-mcp-server.mjs (backward-compatible standalone server check)
 * - Real `node --jitless @deepseek-ai/dsh web` boot benchmark:
 *   baseline (unoptimized plugins, no compile cache) vs optimized cold vs optimized warm NODE_COMPILE_CACHE
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');
const ZIP_PATH = path.join(REPO_ROOT, 'entry/src/main/resources/rawfile/dsh-runtime.zip');
const BRIDGE_DIR = path.join(REPO_ROOT, 'entry/src/main/resources/rawfile/dsh_bridge');

// 1x1 valid JPEG bytes for mock capture_screen
const TINY_JPEG = Buffer.from([
  0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01,
  0x01, 0x01, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43,
  0x00, 0x03, 0x02, 0x02, 0x03, 0x02, 0x02, 0x03, 0x03, 0x03, 0x03, 0x04,
  0x03, 0x03, 0x04, 0x05, 0x08, 0x05, 0x05, 0x04, 0x04, 0x05, 0x0a, 0x07,
  0x07, 0x06, 0x08, 0x0c, 0x0a, 0x0c, 0x0c, 0x0b, 0x0a, 0x0b, 0x0b, 0x0d,
  0x0e, 0x12, 0x10, 0x0d, 0x0e, 0x11, 0x0e, 0x0b, 0x0b, 0x10, 0x16, 0x10,
  0x11, 0x13, 0x14, 0x15, 0x15, 0x15, 0x0c, 0x0f, 0x17, 0x18, 0x16, 0x14,
  0x18, 0x12, 0x14, 0x15, 0x14, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x01,
  0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xff, 0xc4, 0x00, 0x14, 0x00, 0x01,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x09, 0xff, 0xc4, 0x00, 0x14, 0x10, 0x01, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00,
  0xd2, 0xcf, 0x20, 0xff, 0xd9
]);

async function bootRealDshWeb({ staging, dshHome, compileCacheDir, patchContent, label }) {
  fs.mkdirSync(dshHome, { recursive: true });
  fs.writeFileSync(path.join(dshHome, 'cordis.patch.yml'), patchContent, 'utf8');
  if (compileCacheDir) {
    fs.mkdirSync(compileCacheDir, { recursive: true });
  }

  const preloadPath = path.join(staging, 'test-preload.cjs');
  if (!fs.existsSync(preloadPath)) {
    fs.writeFileSync(preloadPath, `
const Module = require('module');
const origRequire = Module.prototype.require;
Module.prototype.require = function(id) {
  if (id === 'node-addon-require-builtin') {
    return {
      requireBuiltin(mid) {
        try { return origRequire.call(this, mid); } catch (e) {
          return origRequire.call(this, mid.startsWith('internal/') ? mid : 'internal/' + mid);
        }
      },
      isAllowedInternalId() { return true; },
      getBindingInfo() { return { backend: 'native-internal', abi: 'v24' }; }
    };
  }
  return origRequire.apply(this, arguments);
};
`, 'utf8');
  }

  const binJs = path.join(staging, 'node_modules/@deepseek-ai/dsh/lib/bin.js');
  const env = {
    ...process.env,
    HOME: path.dirname(dshHome),
    DSH_HOME: dshHome,
    NODE_PATH: path.join(staging, 'node_modules')
  };
  if (compileCacheDir) {
    env.NODE_COMPILE_CACHE = compileCacheDir;
  } else {
    delete env.NODE_COMPILE_CACHE;
  }

  const startMs = Date.now();
  const child = spawn(
    process.execPath,
    ['--jitless', '--no-opt', '--expose-internals', '-r', preloadPath, binJs, 'web', '--host', '127.0.0.1', '--port', '0', '--no-open'],
    { cwd: staging, env, stdio: ['ignore', 'pipe', 'pipe'] }
  );

  let stdout = '';
  let stderr = '';
  const url = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`[${label}] DSH web boot timed out after 30s.\nstdout:\n${stdout}\nstderr:\n${stderr}`));
    }, 30000);

    const checkReady = () => {
      const m = /http:\/\/127\.0\.0\.1:(\d+)\/\?token=([A-Za-z0-9_-]+)/.exec(stdout);
      if (m) {
        clearTimeout(timer);
        resolve({ baseUrl: `http://127.0.0.1:${m[1]}`, fullUrl: m[0] });
      }
    };

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
      checkReady();
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    child.on('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`[${label}] DSH exited early with code ${code}.\nstdout:\n${stdout}\nstderr:\n${stderr}`));
    });
  });

  const bootMs = Date.now() - startMs;

  // Verify direct GET / returns HTTP 200 (SWAI_AUTH_BYPASS applied)
  const statusCode = await new Promise((resolve, reject) => {
    const req = http.get(`${url.baseUrl}/`, (res) => {
      res.resume();
      resolve(res.statusCode);
    });
    req.on('error', reject);
  });

  child.kill('SIGTERM');
  await new Promise((resolve) => {
    const t = setTimeout(() => {
      child.kill('SIGKILL');
      resolve();
    }, 3000);
    child.on('exit', () => {
      clearTimeout(t);
      resolve();
    });
  });

  return { bootMs, statusCode, stderr, stdout, url };
}

async function runTests() {
  const staging = fs.mkdtempSync(path.join(os.tmpdir(), 'swai-dsh-test-'));
  let mockServer = null;

  try {
    // Extract full runtime zip for contract tests + real DSH boot test
    execFileSync('unzip', ['-q', ZIP_PATH, '-d', staging], { stdio: 'inherit' });

    // Start mock tool bridge HTTP server
    const receivedExecute = [];
    const receivedCancel = [];
    let holdExecuteResolve = null;

    mockServer = http.createServer((req, res) => {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        const parsed = body ? JSON.parse(body) : {};
        if (req.url === '/v1/tool/cancel') {
          receivedCancel.push(parsed);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true, cancelled: true }));
          if (holdExecuteResolve) {
            holdExecuteResolve();
            holdExecuteResolve = null;
          }
          return;
        }
        if (req.url === '/v1/tool/execute') {
          receivedExecute.push(parsed);
          if (parsed.tool === 'ui' && parsed.args?.action === 'hang_test') {
            new Promise((resolve) => {
              holdExecuteResolve = resolve;
            }).then(() => {
              if (!res.writableEnded) {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ ok: false, output: '', error: 'cancelled', exitCode: -1 }));
              }
            });
            return;
          }
          if (parsed.tool === 'bash' && typeof parsed.args?.command === 'string' && parsed.args.command.includes('snapshot_display')) {
            const m = /snapshot_display -f '([^']+)'/.exec(parsed.args.command);
            if (m && m[1]) {
              fs.mkdirSync(path.dirname(m[1]), { recursive: true });
              fs.writeFileSync(m[1], TINY_JPEG);
            }
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ ok: true, output: '', exitCode: 0 }));
            return;
          }
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true, output: `mock-ok:${parsed.tool}`, exitCode: 0 }));
          return;
        }
        res.writeHead(404);
        res.end();
      });
    });

    await new Promise((resolve) => mockServer.listen(0, '127.0.0.1', resolve));
    const port = mockServer.address().port;
    process.env.SWAI_TOOL_BRIDGE_PORT = String(port);
    process.env.TMPDIR = path.join(staging, 'tmp');
    fs.mkdirSync(process.env.TMPDIR, { recursive: true });

    // 1. Load bridge/swai-tools.mjs (which imports real @deepseek-ai/dsh-tools defineTool)
    const swaiToolsMod = await import(pathToFileURL(path.join(staging, 'bridge/swai-tools.mjs')).href);

    // Verify source bridge matches zipped bridge
    assert.equal(
      fs.readFileSync(path.join(BRIDGE_DIR, 'swai-tools.mjs'), 'utf8'),
      fs.readFileSync(path.join(staging, 'bridge/swai-tools.mjs'), 'utf8'),
      'dsh-runtime.zip bridge/swai-tools.mjs should match source'
    );
    assert.equal(
      fs.readFileSync(path.join(BRIDGE_DIR, 'swai-host.patch.json'), 'utf8'),
      fs.readFileSync(path.join(staging, 'bridge/swai-host.patch.json'), 'utf8'),
      'dsh-runtime.zip bridge/swai-host.patch.json should match source'
    );
    assert.equal(
      fs.existsSync(path.join(staging, 'bridge/swai-subprocess.mjs')),
      false,
      'swai-subprocess.mjs should be removed from zip'
    );

    const registered = new Map();
    const promptSections = [];
    let currentModalities = ['text', 'image'];

    const mockCtx = {
      tools: {
        register(def) {
          assert.equal(def.parameters.type, 'object');
          assert.equal(typeof def.output.render, 'function');
          registered.set(def.name, def);
          return () => registered.delete(def.name);
        }
      },
      systemPrompt: {
        section(sec) {
          promptSections.push(sec);
        }
      },
      get(serviceName) {
        if (serviceName === 'llm') {
          return {
            async resolveModelInfo() {
              return { inputModalities: currentModalities };
            }
          };
        }
        if (serviceName === 'attachments') {
          return {
            async saveImage({ data, mediaType, name }) {
              return {
                attachmentId: 'att-mock-1',
                mediaType,
                bytes: data.length,
                width: 1,
                height: 1,
                name
              };
            }
          };
        }
        return undefined;
      }
    };

    swaiToolsMod.apply(mockCtx);

    // Verify exact 12 registered tools (4 native + 6 browser_* + 2 wechat_*)
    assert.deepEqual(
      [...registered.keys()].sort(),
      [
        'browser_click',
        'browser_evaluate',
        'browser_extract_text',
        'browser_navigate',
        'browser_snapshot',
        'browser_type',
        'capture_screen',
        'offline_code',
        'remote_bash',
        'ui',
        'wechat_post_draft',
        'wechat_render_article'
      ],
      'swai-tools should register exactly 12 unified tools'
    );
    assert.equal(promptSections.length, 1);
    assert.ok(promptSections[0].text().includes('browser_navigate'));
    assert.ok(!promptSections[0].text().includes('mcp__swai__'));
    assert.ok(promptSections[0].text().includes('capture_screen'));
    assert.ok(promptSections[0].text().includes('run_sequence'));

    // Verify ui schema updates
    const uiTool = registered.get('ui');
    for (const key of [
      'anchor', 'use_ocr', 'auto_send', 'clear_first', 'ability_name',
      'contains_text', 'clickable_only', 'include_all', 'limit', 'click_mode',
      'x1', 'y1', 'x2', 'y2', 'duration_ms', 'type'
    ]) {
      assert.ok(key in uiTool.parameters.properties, `ui tool missing parameter: ${key}`);
    }
    for (const act of ['hide_overlay', 'show_overlay', 'minimize_overlay', 'run_sequence', 'click_anchor', 'ocr']) {
      assert.ok(uiTool.parameters.properties.action.enum.includes(act), `ui tool missing action: ${act}`);
    }

    // Verify offline_code supports path without requiring code
    const codeTool = registered.get('offline_code');
    assert.equal(codeTool.parameters.required, undefined);
    assert.ok('path' in codeTool.parameters.properties);
    const missingBoth = await codeTool.execute({}, {});
    assert.ok(missingBoth.text.startsWith('Error:'));
    const pathExec = await codeTool.execute({ path: 'demo.py' }, {});
    assert.equal(pathExec.text, 'mock-ok:offline_code');

    // Verify wechat_render_article lazy-loads formatter cleanly
    const wechatRenderTool = registered.get('wechat_render_article');
    const renderedWechat = await wechatRenderTool.execute({ markdown: '# Hello\n\nTest body.' }, {});
    assert.ok(renderedWechat.text.includes('Title: Hello'));

    // Verify capture_screen with vision model
    const capTool = registered.get('capture_screen');
    const outPathVision = path.join(staging, 'tmp', 'screen-vision.jpeg');
    const capVision = await capTool.execute(
      { output_path: outPathVision },
      { agent: { options: { provider: 'mock', model: 'vision-model' } } }
    );
    assert.ok(capVision.image, 'capture_screen should attach image for vision model');
    assert.equal(capVision.image.attachmentId, 'att-mock-1');
    const renderedVision = capTool.output.render({}, capVision);
    assert.equal(renderedVision.length, 2);
    assert.equal(renderedVision[1].type, 'image');

    // Verify capture_screen graceful fallback for text-only model
    currentModalities = ['text'];
    const outPathText = path.join(staging, 'tmp', 'screen-text.jpeg');
    const capText = await capTool.execute(
      { output_path: outPathText },
      { agent: { options: { provider: 'deepseek', model: 'deepseek-chat' } } }
    );
    assert.equal(capText.image, undefined);
    assert.ok(capText.text.includes('does not support direct image input'));
    const renderedText = capTool.output.render({}, capText);
    assert.equal(renderedText.length, 1);
    assert.equal(renderedText[0].type, 'text');

    // Verify AbortSignal propagates to POST /v1/tool/cancel
    const bridgeMod = await import(pathToFileURL(path.join(staging, 'bridge/bridge-client.mjs')).href);
    const ac = new AbortController();
    const pendingPromise = bridgeMod.dispatchSwaiTool('ui', { action: 'hang_test' }, 10000, { signal: ac.signal });
    setTimeout(() => ac.abort(), 50);
    const abortRes = await pendingPromise;
    assert.equal(abortRes.ok, false);
    assert.ok(abortRes.error.includes('aborted'));
    await new Promise((r) => setTimeout(r, 50));
    assert.ok(receivedCancel.length >= 1, 'AbortController should trigger POST /v1/tool/cancel');

    // Verify standalone SwaiMcpServer compatibility
    const mcpMod = await import(pathToFileURL(path.join(staging, 'bridge/swai-mcp-server.mjs')).href);
    const mcpServer = new mcpMod.SwaiMcpServer({ port: 0 });
    const listResp = await mcpServer.handleJsonRpc({ id: 1, method: 'tools/list', params: {} });
    const mcpNames = listResp.result.tools.map((t) => t.name);
    assert.deepEqual(mcpNames, [
      'browser_navigate',
      'browser_snapshot',
      'browser_click',
      'browser_type',
      'browser_evaluate',
      'browser_extract_text',
      'wechat_render_article',
      'wechat_post_draft'
    ]);

    // 2. Patch auth token in staging to simulate SWAI_AUTH_BYPASS & verify real `dsh web` boot
    const authPath = path.join(staging, 'node_modules/@deepseek-ai/dsh-host-authentication-token/lib/index.js');
    const authSrc = fs.readFileSync(authPath, 'utf8');
    fs.writeFileSync(
      authPath,
      authSrc.replace('isAuthenticated(request, secure = false) {', 'isAuthenticated(request, secure = false) { /* SWAI_AUTH_BYPASS */ return true;')
    );

    const toolsMjsPath = path.join(staging, 'bridge/swai-tools.mjs');
    const baselinePatch = `- insert:\n    - id: swai-tools\n      name: "${toolsMjsPath}"\n`;
    const optimizedPatch = [
      '- insert:',
      '    - id: swai-tools',
      `      name: "${toolsMjsPath}"`,
      '- id: otel',
      '  disabled: true',
      '- id: session-telemetry-otel',
      '  disabled: true',
      '- id: desktop-product-telemetry',
      '  disabled: true',
      '- id: product-analytics',
      '  disabled: true',
      '- id: hmr',
      '  disabled: true',
      '- id: client-hmr',
      '  disabled: true',
      '- id: office-kit',
      '  disabled: true',
      '- id: skill-office',
      '  disabled: true',
      '- id: action-cards',
      '  disabled: true',
      '- id: client-ui-action-cards',
      '  disabled: true',
      '- id: creation-recommendations',
      '  disabled: true',
      '- id: client-ui-creation-recommendations',
      '  disabled: true',
      '- id: plugin-recommendations',
      '  disabled: true',
      '- id: client-ui-plugin-recommendations',
      '  disabled: true',
      '- id: open-in-app',
      '  disabled: true',
      '- id: ui-open-in-app',
      '  disabled: true',
      '- id: pwsh-sandbox',
      '  disabled: true',
      '- id: tool-pwsh',
      '  disabled: true',
      '- id: plugin-inventory',
      '  disabled: true',
      '- id: plugin-package-inventory-deepseek',
      '  disabled: true',
      '- id: message-feedback',
      '  disabled: true',
      '- id: ui-message-feedback',
      '  disabled: true',
      ''
    ].join('\n');

    const baselineRes = await bootRealDshWeb({
      staging,
      dshHome: path.join(staging, 'home-baseline/.dsh'),
      compileCacheDir: null,
      patchContent: baselinePatch,
      label: 'baseline-no-cache'
    });
    assert.equal(baselineRes.statusCode, 200);

    const compileCacheDir = path.join(staging, '.compile-cache');
    const optColdRes = await bootRealDshWeb({
      staging,
      dshHome: path.join(staging, 'home-opt/.dsh'),
      compileCacheDir,
      patchContent: optimizedPatch,
      label: 'optimized-cold-cache'
    });
    assert.equal(optColdRes.statusCode, 200);
    assert.ok(!optColdRes.stderr.includes('did not activate'), `Unexpected Cordis plugin warning:\n${optColdRes.stderr}`);

    const optWarmRes = await bootRealDshWeb({
      staging,
      dshHome: path.join(staging, 'home-opt/.dsh'),
      compileCacheDir,
      patchContent: optimizedPatch,
      label: 'optimized-warm-cache'
    });
    assert.equal(optWarmRes.statusCode, 200);
    assert.ok(!optWarmRes.stderr.includes('did not activate'), `Unexpected Cordis plugin warning:\n${optWarmRes.stderr}`);

    console.log(
      `[DSH Boot Benchmark --jitless] baseline=${baselineRes.bootMs}ms | opt_cold=${optColdRes.bootMs}ms | opt_warm=${optWarmRes.bootMs}ms`
    );
    console.log('All DSH bridge & tool contract tests PASSED!');
  } finally {
    if (mockServer) {
      await new Promise((resolve) => mockServer.close(resolve));
    }
    fs.rmSync(staging, { recursive: true, force: true });
  }
}

runTests().catch((err) => {
  console.error(err);
  process.exit(1);
});
