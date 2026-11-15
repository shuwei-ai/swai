/**
 * Swai ArkWeb Chrome DevTools Protocol (CDP) Driver
 * Runs inside DSH Node runtime, communicates directly with ArkWeb Chromium at 127.0.0.1:9222.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import http from 'node:http';

let WebSocketImpl = globalThis.WebSocket;
try {
  const wsMod = await import('ws');
  WebSocketImpl = wsMod.default || wsMod.WebSocket || globalThis.WebSocket;
} catch {}

export class CdpDriver {
  constructor(options = {}) {
    this.port = options.port || 9222;
    this.ws = null;
    this.wsUrl = '';
    this.currentTargetUrl = '';
    this.nextId = 1;
    this.pending = new Map(); // id -> { resolve, reject, timer }
    this.isConnected = false;
  }

  /**
   * Discover page targets from http://127.0.0.1:9222/json/list
   */
  async discoverTargets(timeoutMs = 3000) {
    return new Promise((resolve) => {
      const req = http.request({
        hostname: '127.0.0.1',
        port: this.port,
        path: '/json/list',
        method: 'GET',
        timeout: timeoutMs,
      }, (res) => {
        let body = '';
        res.on('data', chunk => body += chunk);
        res.on('end', () => {
          try {
            const list = JSON.parse(body);
            resolve(Array.isArray(list) ? list : []);
          } catch {
            resolve([]);
          }
        });
      });

      req.on('error', () => resolve([]));
      req.on('timeout', () => {
        req.destroy();
        resolve([]);
      });
      req.end();
    });
  }

  /**
   * Ensure active WebSocket connection to the first available page target
   */
  async ensureConnected(timeoutMs = 5000) {
    // If already connected to a legitimate external browser target, keep it
    if (this.isConnected && this.ws && (this.ws.readyState === 1 || this.ws.readyState === WebSocketImpl?.OPEN)) {
      if (!this.currentTargetUrl.includes(':38927') && !this.currentTargetUrl.includes('term.html')) {
        return true;
      }
    }

    // Clean up existing stale or internal connection
    if (this.ws) {
      try { this.ws.close(); } catch {}
      this.ws = null;
    }
    this.isConnected = false;
    this.currentTargetUrl = '';

    const targets = await this.discoverTargets(timeoutMs);
    // Prioritize external browser page target over internal DSH frontend or term console
    let target = targets.find(t =>
      t.type === 'page' &&
      t.webSocketDebuggerUrl &&
      !t.url.includes(':38927') &&
      !t.url.includes('term.html')
    );

    if (!target || !target.webSocketDebuggerUrl) {
      throw new Error(`No active external ArkWeb page target found on 127.0.0.1:${this.port}. Please ensure browser view is visible.`);
    }

    this.wsUrl = target.webSocketDebuggerUrl;
    this.currentTargetUrl = target.url || '';

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!this.isConnected) {
          try { ws.close(); } catch {}
          reject(new Error(`Timed out connecting to CDP WebSocket at ${this.wsUrl}`));
        }
      }, timeoutMs);

      const ws = new WebSocketImpl(this.wsUrl);

      ws.on('open', () => {
        clearTimeout(timer);
        this.ws = ws;
        this.isConnected = true;
        resolve(true);
      });

      ws.on('message', (data) => {
        try {
          const resp = JSON.parse(data.toString());
          if (resp && resp.id && this.pending.has(resp.id)) {
            const { resolve, reject, timer } = this.pending.get(resp.id);
            clearTimeout(timer);
            this.pending.delete(resp.id);
            if (resp.error) {
              reject(new Error(resp.error.message || JSON.stringify(resp.error)));
            } else {
              resolve(resp.result || {});
            }
          }
        } catch {}
      });

      ws.on('error', (err) => {
        if (!this.isConnected) {
          clearTimeout(timer);
          reject(err);
        }
      });

      ws.on('close', () => {
        this.isConnected = false;
        this.ws = null;
        for (const [_, item] of this.pending) {
          clearTimeout(item.timer);
          item.reject(new Error('CDP connection closed'));
        }
        this.pending.clear();
      });
    });
  }

  /**
   * Send JSON-RPC command over CDP WebSocket
   */
  async send(method, params = {}, timeoutMs = 20000) {
    await this.ensureConnected();

    const id = this.nextId++;
    const payload = JSON.stringify({ id, method, params });

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`CDP command ${method} timed out after ${timeoutMs}ms`));
        }
      }, timeoutMs);

      this.pending.set(id, { resolve, reject, timer });
      try {
        this.ws.send(payload);
      } catch (err) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(err);
      }
    });
  }

  /**
   * Evaluate JavaScript in the page context
   */
  async evaluate(expression, timeoutMs = 15000) {
    const res = await this.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true
    }, timeoutMs);

    if (res && res.exceptionDetails) {
      const desc = res.exceptionDetails.exception?.description || res.exceptionDetails.text;
      throw new Error(`JavaScript evaluation error: ${desc}`);
    }

    return res?.result?.value;
  }

  /**
   * Navigate to a URL and wait for DOM readiness
   */
  async navigate(url, timeoutMs = 20000) {
    let target = url.trim();
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      target = 'https://' + target;
    }

    await this.send('Page.enable');
    const start = Date.now();
    await this.send('Page.navigate', { url: target });

    // Poll document.readyState until 'interactive' or 'complete'
    const deadline = Date.now() + timeoutMs;
    let title = '';
    let currentUrl = target;

    while (Date.now() < deadline) {
      await new Promise(r => setTimeout(r, 400));
      try {
        const state = await this.evaluate('document.readyState');
        if (state === 'complete' || state === 'interactive') {
          title = await this.evaluate('document.title') || '';
          currentUrl = await this.evaluate('window.location.href') || target;
          break;
        }
      } catch {}
    }

    return {
      url: currentUrl,
      title: title || 'Loaded',
      durationMs: Date.now() - start
    };
  }

  /**
   * Extract readable text and interactive elements with index annotations
   */
  async snapshot(mode = 'both') {
    const script = `
      (() => {
        try {
          const getCleanText = () => {
            const clone = document.body ? document.body.cloneNode(true) : null;
            if (!clone) return '';
            const toRemove = ['script', 'style', 'noscript', 'svg', 'iframe', 'canvas', 'template'];
            toRemove.forEach(t => clone.querySelectorAll(t).forEach(e => e.remove()));
            return (clone.innerText || clone.textContent || '')
              .replace(/[ \\t]+/g, ' ')
              .replace(/\\n\\s*\\n/g, '\\n')
              .trim();
          };

          const getInteractive = () => {
            const candidates = Array.from(document.querySelectorAll('a, button, input, textarea, select, [role="button"], [onclick]'));
            const items = [];
            let idx = 1;
            for (const el of candidates) {
              const rect = el.getBoundingClientRect();
              const style = window.getComputedStyle(el);
              if (rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0') {
                let label = (el.innerText || el.getAttribute('placeholder') || el.getAttribute('aria-label') || el.getAttribute('title') || el.value || '').trim();
                if (label.length > 60) label = label.substring(0, 57) + '...';
                const tag = el.tagName.toLowerCase();
                const type = el.getAttribute('type') || '';
                const href = el.getAttribute('href') || '';
                el.setAttribute('data-pi-idx', String(idx));
                items.push({
                  idx: idx,
                  tag: tag,
                  type: type || undefined,
                  label: label || undefined,
                  href: href && !href.startsWith('javascript:') ? href : undefined
                });
                idx++;
                if (idx > 60) break;
              }
            }
            return items;
          };

          return JSON.stringify({
            title: document.title || '',
            url: window.location.href || '',
            text: getCleanText().substring(0, 6000),
            elements: getInteractive()
          });
        } catch (err) {
          return JSON.stringify({ error: String(err) });
        }
      })()
    `;

    const raw = await this.evaluate(script);
    try {
      const data = typeof raw === 'string' ? JSON.parse(raw) : (raw || {});
      if (mode === 'text') delete data.elements;
      if (mode === 'interactive') delete data.text;
      return data;
    } catch {
      return { text: String(raw) };
    }
  }

  /**
   * Click an interactive element by index or selector
   */
  async click({ index, selector }) {
    let script = '';
    if (index !== undefined && index !== null) {
      script = `
        (() => {
          const el = document.querySelector('[data-pi-idx="${index}"]');
          if (!el) return 'Element with index [${index}] not found';
          el.scrollIntoView({ behavior: 'instant', block: 'center' });
          el.click();
          return 'OK';
        })()
      `;
    } else if (selector) {
      const selEscaped = selector.replace(/"/g, '\\"');
      script = `
        (() => {
          const el = document.querySelector("${selEscaped}");
          if (!el) return 'Element matching selector "${selEscaped}" not found';
          el.scrollIntoView({ behavior: 'instant', block: 'center' });
          el.click();
          return 'OK';
        })()
      `;
    } else {
      throw new Error('Must provide either "index" or "selector"');
    }

    const res = await this.evaluate(script);
    if (res === 'OK') {
      // Small delay for DOM updates
      await new Promise(r => setTimeout(r, 600));
      return { success: true, message: `Clicked element successfully` };
    } else {
      return { success: false, message: String(res) };
    }
  }

  /**
   * Type text into an input field
   */
  async type({ text, index, selector }) {
    const textEscaped = (text || '').replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
    let script = '';
    if (index !== undefined && index !== null) {
      script = `
        (() => {
          const el = document.querySelector('[data-pi-idx="${index}"]');
          if (!el) return 'Element [${index}] not found';
          el.focus();
          el.value = "${textEscaped}";
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'OK';
        })()
      `;
    } else if (selector) {
      const selEscaped = selector.replace(/"/g, '\\"');
      script = `
        (() => {
          const el = document.querySelector("${selEscaped}");
          if (!el) return 'Element "${selEscaped}" not found';
          el.focus();
          el.value = "${textEscaped}";
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'OK';
        })()
      `;
    } else {
      throw new Error('Must provide either "index" or "selector"');
    }

    const res = await this.evaluate(script);
    return { success: res === 'OK', message: res === 'OK' ? 'Typed text successfully' : String(res) };
  }

  /**
   * Fast readable text extraction
   */
  async extractText() {
    const script = `
      (() => {
        const clone = document.body ? document.body.cloneNode(true) : null;
        if (!clone) return '';
        ['script', 'style', 'noscript', 'svg', 'iframe'].forEach(t => clone.querySelectorAll(t).forEach(e => e.remove()));
        return (clone.innerText || clone.textContent || '').replace(/[ \\t]+/g, ' ').replace(/\\n\\s*\\n/g, '\\n').trim();
      })()
    `;
    return await this.evaluate(script) || '';
  }
}
