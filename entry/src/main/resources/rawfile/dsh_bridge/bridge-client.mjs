/**
 * Swai <-> DSH Node Bridge Client
 * Communicates with Swai Native C ABI / ArkTS Tools.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import http from 'node:http';
import { randomUUID } from 'node:crypto';

let nativePort = null;
try {
  // If registered as linked binding in libnode
  if (typeof process._linkedBinding === 'function') {
    try {
      nativePort = process._linkedBinding('swai_bridge');
    } catch (_) {}
    if (!nativePort) {
      try {
        nativePort = process._linkedBinding('piha_bridge');
      } catch (_) {}
    }
  }
} catch (_) {}

/**
 * Resolve loopback bridge port from environment.
 * @returns {number}
 */
function resolveBridgePort() {
  const raw = process.env.SWAI_TOOL_BRIDGE_PORT || process.env.PIHA_TOOL_BRIDGE_PORT;
  const parsed = raw ? Number(raw) : 38081;
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 38081;
}

/**
 * Sends a fire-and-forget cancellation request to the loopback tool bridge.
 * @param {number} port
 * @param {string} requestId
 */
function sendHttpCancel(port, requestId) {
  try {
    const cancelBody = JSON.stringify({ requestId });
    const cancelReq = http.request({
      hostname: '127.0.0.1',
      port,
      path: '/v1/tool/cancel',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(cancelBody),
      },
      timeout: 1500,
    }, (res) => {
      res.resume();
    });
    cancelReq.on('error', () => {});
    cancelReq.on('timeout', () => {
      cancelReq.destroy();
    });
    cancelReq.write(cancelBody);
    cancelReq.end();
  } catch (_) {}
}

/**
 * Dispatches a tool execution to Swai host and awaits the result.
 * @param {string} tool - Tool name: "ui" | "bash" | "run_code" | "offline_code" | "remote_bash"
 * @param {object} args - Tool arguments object
 * @param {number} timeoutMs - Max wait timeout in ms
 * @param {{ signal?: AbortSignal }} [options] - Optional execution options including AbortSignal
 * @returns {Promise<{ ok: boolean, output: string, error?: string, exitCode?: number }>}
 */
export async function dispatchSwaiTool(tool, args = {}, timeoutMs = 30000, options = {}) {
  const signal = options?.signal;
  if (signal?.aborted) {
    return { ok: false, output: '', error: 'Tool execution aborted', exitCode: -1 };
  }

  const requestId = `swai-${tool}-${randomUUID()}`;
  const argsJson = JSON.stringify(args);

  // 1. If Native Port C ABI is linked
  if (nativePort && typeof nativePort.dispatch === 'function') {
    nativePort.dispatch(requestId, tool, argsJson, Date.now() + timeoutMs);
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (signal?.aborted) {
        nativePort.cancel?.(requestId);
        return { ok: false, output: '', error: 'Tool execution aborted', exitCode: -1 };
      }
      const res = nativePort.poll(requestId);
      if (res && res.status === 1) { // Succeeded
        return { ok: true, output: res.data || '', exitCode: res.exitCode || 0 };
      }
      if (res && res.status === 2) { // Failed
        return { ok: false, output: '', error: res.data || 'Tool execution failed', exitCode: res.exitCode || -1 };
      }
      if (res && res.status === 3) { // Cancelled
        return { ok: false, output: '', error: 'Tool execution cancelled', exitCode: -1 };
      }
      await new Promise(r => setTimeout(r, 50));
    }
    nativePort.cancel?.(requestId);
    return { ok: false, output: '', error: 'Tool execution timed out', exitCode: -1 };
  }

  // 2. Loopback HTTP fallback (if Swai runs a local tool bridge HTTP port on 127.0.0.1:38081)
  const port = resolveBridgePort();
  return new Promise((resolve) => {
    let settled = false;
    const postData = JSON.stringify({ requestId, tool, args, deadlineMs: Date.now() + timeoutMs });
    let req = null;

    const cleanup = () => {
      if (signal && onAbort) {
        signal.removeEventListener('abort', onAbort);
      }
    };

    const finish = (result) => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      resolve(result);
    };

    const onAbort = () => {
      if (settled) {
        return;
      }
      try {
        req?.destroy();
      } catch (_) {}
      sendHttpCancel(port, requestId);
      finish({ ok: false, output: '', error: 'Tool execution aborted', exitCode: -1 });
    };

    if (signal) {
      signal.addEventListener('abort', onAbort, { once: true });
    }

    req = http.request({
      hostname: '127.0.0.1',
      port: port,
      path: '/v1/tool/execute',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData),
      },
      timeout: timeoutMs,
    }, (res) => {
      let body = '';
      res.on('data', chunk => body += chunk);
      res.on('end', () => {
        if (settled) {
          return;
        }
        try {
          const parsed = JSON.parse(body);
          finish(parsed);
        } catch (e) {
          finish({ ok: false, output: body, error: `Invalid JSON response: ${e.message}`, exitCode: -1 });
        }
      });
    });

    req.on('error', (err) => {
      finish({ ok: false, output: '', error: `Bridge connect error: ${err.message}`, exitCode: -1 });
    });

    req.on('timeout', () => {
      req.destroy();
      sendHttpCancel(port, requestId);
      finish({ ok: false, output: '', error: 'Bridge request timeout', exitCode: -1 });
    });

    req.write(postData);
    req.end();
  });
}

// Backward compatibility alias for PiHA tools and subagents
export const dispatchPihaTool = dispatchSwaiTool;
