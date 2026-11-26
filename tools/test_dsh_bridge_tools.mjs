#!/usr/bin/env node
/**
 * Contract & integration tests for DSH bridge tools:
 * - swai-tools.mjs (schema validation via real @deepseek-ai/dsh-tools, tool set, capture_screen, AbortSignal)
 * - bridge-client.mjs (AbortController -> POST /v1/tool/cancel)
 * - swai-mcp-server.mjs (tools/list has 8 tools without bash/ui)
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
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

async function runTests() {
  const staging = fs.mkdtempSync(path.join(os.tmpdir(), 'swai-dsh-test-'));
  let mockServer = null;

  try {
    // Extract runtime zip bridge + needed node_modules for real defineTool schema validation
    execFileSync('unzip', ['-q', ZIP_PATH, 'bridge/*', 'node_modules/*', '-d', staging], { stdio: 'inherit' });

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
          // defineTool() already compiled & validated parameters + output.schema
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

    // Verify exact registered tool set
    assert.deepEqual(
      [...registered.keys()].sort(),
      ['capture_screen', 'offline_code', 'remote_bash', 'ui'],
      'swai-tools should register exactly ui, offline_code, remote_bash, capture_screen'
    );
    assert.equal(promptSections.length, 1);
    assert.ok(promptSections[0].text().includes('capture_screen'));
    assert.ok(promptSections[0].text().includes('run_sequence'));

    // Verify ui schema updates (compiled into JSON Schema properties)
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

    // Verify SwaiMcpServer exposes exactly 8 tools (no bash/ui)
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
