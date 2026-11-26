/**
 * Swai Unified MCP (Model Context Protocol) Server for HarmonyOS
 * Exposes ArkWeb CDP Browser automation and high-privilege system tools over Streamable HTTP.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import http from 'node:http';
import fs from 'node:fs';
import { randomUUID } from 'node:crypto';
import { CdpDriver } from './cdp-driver.mjs';
import { dispatchSwaiTool } from './bridge-client.mjs';

let wechatPosterInstance = null;
async function getWeChatPoster(cdpDriver) {
  if (!wechatPosterInstance) {
    const mod = await import('./wechat-poster.mjs');
    wechatPosterInstance = new mod.WeChatPoster(cdpDriver);
  }
  return wechatPosterInstance;
}

export class SwaiMcpServer {
  constructor(options = {}) {
    this.port = options.port || 39001;
    this.cdpDriver = new CdpDriver({ port: options.cdpPort || 9222 });
    this.httpServer = null;
    this.tools = [];
    this.toolHandlers = new Map();
    this.initTools();
  }

  /**
   * Request ArkTS UI to show the BrowserView overlay
   */
  async notifyShowOverlay() {
    try {
      await dispatchSwaiTool('ui', { action: 'show_browser_overlay' }, 5000);
    } catch {}
  }

  registerTool(toolDef, handler) {
    this.tools.push(toolDef);
    this.toolHandlers.set(toolDef.name, handler);
  }

  initTools() {
    // 1. Browser Navigate
    this.registerTool({
      name: 'browser_navigate',
      description: 'Navigate the in-app ArkWeb browser to a URL and inspect the loaded page.',
      inputSchema: {
        type: 'object',
        properties: {
          url: { type: 'string', description: 'Target website URL (e.g. https://developer.huawei.com)' },
          timeoutMs: { type: 'number', description: 'Navigation timeout in ms (default 20000)' }
        },
        required: ['url']
      }
    }, async (args) => {
      this.notifyShowOverlay();
      const navRes = await this.cdpDriver.navigate(args.url, args.timeoutMs || 20000);
      const snap = await this.cdpDriver.snapshot('both');
      
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
      return { output: out.trim(), isError: false };
    });

    // 2. Browser Snapshot
    this.registerTool({
      name: 'browser_snapshot',
      description: 'Capture readable page text and index-mapped interactive elements from current browser tab.',
      inputSchema: {
        type: 'object',
        properties: {
          mode: { type: 'string', enum: ['both', 'text', 'interactive'], description: 'Snapshot mode (default "both")' }
        }
      }
    }, async (args) => {
      const snap = await this.cdpDriver.snapshot(args.mode || 'both');
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
      return { output: out.trim(), isError: false };
    });

    // 3. Browser Click
    this.registerTool({
      name: 'browser_click',
      description: 'Click an interactive button, link, or element on the current webpage by index [1], [2] or selector.',
      inputSchema: {
        type: 'object',
        properties: {
          index: { type: 'number', description: 'Numeric index from previous snapshot e.g. 1, 2' },
          selector: { type: 'string', description: 'Optional CSS selector' }
        }
      }
    }, async (args) => {
      const res = await this.cdpDriver.click(args);
      return { output: res.message, isError: !res.success };
    });

    // 4. Browser Type
    this.registerTool({
      name: 'browser_type',
      description: 'Type text into an input box or textarea on the current webpage.',
      inputSchema: {
        type: 'object',
        properties: {
          text: { type: 'string', description: 'Text to input' },
          index: { type: 'number', description: 'Numeric index from previous snapshot' },
          selector: { type: 'string', description: 'Optional CSS selector' }
        },
        required: ['text']
      }
    }, async (args) => {
      const res = await this.cdpDriver.type(args);
      return { output: res.message, isError: !res.success };
    });

    // 5. Browser Evaluate
    this.registerTool({
      name: 'browser_evaluate',
      description: 'Execute arbitrary JavaScript expression in the ArkWeb page context.',
      inputSchema: {
        type: 'object',
        properties: {
          script: { type: 'string', description: 'JavaScript code expression' }
        },
        required: ['script']
      }
    }, async (args) => {
      const val = await this.cdpDriver.evaluate(args.script);
      return { output: typeof val === 'string' ? val : JSON.stringify(val, null, 2), isError: false };
    });

    // 6. Browser Extract Text
    this.registerTool({
      name: 'browser_extract_text',
      description: 'Quickly extract clean, readable article body text without HTML boilerplate.',
      inputSchema: { type: 'object', properties: {} }
    }, async () => {
      const txt = await this.cdpDriver.extractText();
      return { output: txt, isError: false };
    });

    // 7. WeChat Article Renderer (wechat_render_article)
    this.registerTool({
      name: 'wechat_render_article',
      description: 'Convert Markdown into WeChat Official Account ready HTML with beautiful inline CSS styles (baoyu-md engine).',
      inputSchema: {
        type: 'object',
        properties: {
          markdown: { type: 'string', description: 'Markdown source text or file path on device' },
          theme: { type: 'string', enum: ['default', 'grace', 'simple', 'modern', 'editorial', 'cyber-minimal', 'aurora-warm', 'neo-brutalism'], description: 'Typography theme' },
          color: { type: 'string', description: 'Primary color (e.g. blue, green, #07c160)' },
          title: { type: 'string', description: 'Optional title override' },
          author: { type: 'string', description: 'Optional author override' }
        },
        required: ['markdown']
      }
    }, async (args) => {
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
        return { output: out, isError: false };
      } catch (err) {
        return { output: `Markdown 排版失败: ${err.message}\n${err.stack || ''}`, isError: true };
      }
    });

    // 8. WeChat Article Draft Publisher (wechat_post_draft)
    this.registerTool({
      name: 'wechat_post_draft',
      description: 'Automatically publish or save a Markdown article to WeChat Official Account (微信公众号) draft box via ArkWeb browser automation.',
      inputSchema: {
        type: 'object',
        properties: {
          markdown: { type: 'string', description: 'Markdown text content or local file path to publish' },
          title: { type: 'string', description: 'Optional article title override' },
          author: { type: 'string', description: 'Optional author name override' },
          summary: { type: 'string', description: 'Optional summary / description override' },
          theme: { type: 'string', enum: ['default', 'grace', 'simple', 'modern', 'editorial', 'cyber-minimal', 'aurora-warm', 'neo-brutalism'], description: 'Typography theme (default "default")' },
          color: { type: 'string', description: 'Primary theme color preset or hex' },
          saveDraft: { type: 'boolean', description: 'Whether to click save draft automatically (default true)' }
        },
        required: ['markdown']
      }
    }, async (args) => {
      try {
        this.notifyShowOverlay();
        let mdContent = args.markdown;
        if (typeof mdContent === 'string' && fs.existsSync(mdContent)) {
          mdContent = fs.readFileSync(mdContent, 'utf-8');
        }
        const poster = await getWeChatPoster(this.cdpDriver);
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
            output: `⚠️ 微信公众号尚未登录！\n\n${res.message}\n已解析文章标题: ${res.title}\n摘要: ${res.summary}\n\n👉 提示：请在真机屏幕右侧浏览器中扫码登录微信公众号，登录完成后再次调用此命令即可直接保存草稿！`,
            isError: false
          };
        }

        return {
          output: `✅ 微信公众号草稿创建成功！\n\n标题: ${res.title}\n作者: ${res.author || '(未设置)'}\n摘要: ${res.summary}\n保存状态: ${res.saveResult}${res.appmsgid ? '\nDraft ID: ' + res.appmsgid : ''}`,
          isError: false
        };
      } catch (err) {
        return { output: `微信公众号草稿自动化失败: ${err.message}\n${err.stack || ''}`, isError: true };
      }
    });
  }

  start() {
    return new Promise((resolve, reject) => {
      this.httpServer = http.createServer(async (req, res) => {
        res.setHeader('Access-Control-Allow-Origin', '*');
        res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
        res.setHeader('Access-Control-Allow-Headers', '*');

        if (req.method === 'OPTIONS') {
          res.writeHead(204);
          res.end();
          return;
        }

        if (req.method === 'GET') {
          res.writeHead(405, { 'Content-Type': 'text/plain' });
          res.end('Method Not Allowed');
          return;
        }

        if (req.method === 'POST') {
          let body = '';
          req.on('data', chunk => body += chunk);
          req.on('end', async () => {
            try {
              const msg = JSON.parse(body);
              const responseMsg = await this.handleJsonRpc(msg);

              if (responseMsg === null) {
                res.writeHead(202, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ status: 'accepted' }));
                return;
              }

              const resJson = JSON.stringify(responseMsg);
              res.writeHead(200, {
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(resJson),
                'mcp-session-id': randomUUID()
              });
              res.end(resJson);
            } catch (err) {
              const errJson = JSON.stringify({
                jsonrpc: '2.0',
                id: null,
                error: { code: -32700, message: err.message }
              });
              res.writeHead(400, {
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(errJson)
              });
              res.end(errJson);
            }
          });
          return;
        }

        res.writeHead(404);
        res.end();
      });

      this.httpServer.listen(this.port, '127.0.0.1', () => {
        console.log(`[SwaiMcpServer] Listening on http://127.0.0.1:${this.port}/mcp`);
        resolve(this.port);
      });
      this.httpServer.on('error', reject);
    });
  }

  async handleJsonRpc(msg) {
    const { id, method, params } = msg;

    if (id === undefined || id === null) {
      return null;
    }

    switch (method) {
      case 'initialize': {
        return {
          jsonrpc: '2.0',
          id,
          result: {
            protocolVersion: '2024-11-05',
            capabilities: {
              tools: { listChanged: false }
            },
            serverInfo: {
              name: 'swai-mcp-server',
              version: '1.0.0'
            }
          }
        };
      }

      case 'ping': {
        return { jsonrpc: '2.0', id, result: {} };
      }

      case 'tools/list': {
        return {
          jsonrpc: '2.0',
          id,
          result: {
            tools: this.tools
          }
        };
      }

      case 'tools/call': {
        const { name, arguments: args } = params || {};
        let handler = this.toolHandlers.get(name);
        if (!handler && typeof name === 'string') {
          const cleanName = name
            .replace(/^mcp__(?:swai|piha)__/, '')
            .replace(/^(?:swai|piha)__/, '');
          handler = this.toolHandlers.get(cleanName);
        }
        if (!handler) {
          return {
            jsonrpc: '2.0',
            id,
            error: { code: -32601, message: `Tool not found: ${name}` }
          };
        }

        try {
          const res = await handler(args || {});
          return {
            jsonrpc: '2.0',
            id,
            result: {
              content: [
                {
                  type: 'text',
                  text: typeof res === 'string' ? res : (res?.output || JSON.stringify(res))
                }
              ],
              isError: Boolean(res?.isError)
            }
          };
        } catch (err) {
          return {
            jsonrpc: '2.0',
            id,
            result: {
              content: [{ type: 'text', text: `Execution error: ${err.message}` }],
              isError: true
            }
          };
        }
      }

      default: {
        return {
          jsonrpc: '2.0',
          id,
          error: { code: -32601, message: `Method not found: ${method}` }
        };
      }
    }
  }

  stop() {
    if (this.httpServer) {
      this.httpServer.close();
    }
  }
}

// Auto-start singleton on module load if executed in Node or requested
let g_server = null;
export function startSwaiMcpServer(port = 39001) {
  if (!g_server) {
    g_server = new SwaiMcpServer({ port });
    g_server.start().catch((err) => {
      console.error('[SwaiMcpServer] Failed to start:', err);
    });
  }
  return g_server;
}

if (process.env.SWAI_AUTO_START_MCP === '1') {
  startSwaiMcpServer();
}
