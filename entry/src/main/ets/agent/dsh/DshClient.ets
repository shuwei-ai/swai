/*
 * Swai (Shuwei HShell) <-> DeepSeek Harness (DSH) Streaming Client
 *
 * Implements real-time WebSocket connection to DSH engine:
 * - Subscribes to Thinking (reasoning tokens)
 * - Subscribes to Assistant streaming response tokens
 * - Subscribes to Tool execution events
 * - Dispatches chat requests and cancellations
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import webSocket from '@ohos.net.webSocket';
import http from '@ohos.net.http';
import hilog from '@ohos.hilog';
import { ImageAttachment } from '../types';

export interface DshStreamEvent {
  kind: 'thinking' | 'token' | 'tool_call' | 'tool_result' | 'done' | 'error';
  content?: string;
  toolName?: string;
  toolArgs?: string;
  toolOutput?: string;
  images?: ImageAttachment[];
  error?: string;
}

export type DshStreamListener = (event: DshStreamEvent) => void;

export class DshClient {
  private static instance: DshClient | null = null;
  private ws: webSocket.WebSocket | null = null;
  private baseUrl: string = '';
  private token: string = '';
  private isConnected: boolean = false;
  private listeners: DshStreamListener[] = [];
  private currentSessionId: string = 'swai-default-session';

  static getInstance(): DshClient {
    if (!DshClient.instance) {
      DshClient.instance = new DshClient();
    }
    return DshClient.instance;
  }

  addListener(listener: DshStreamListener): void {
    this.listeners.push(listener);
  }

  removeListener(listener: DshStreamListener): void {
    this.listeners = this.listeners.filter(l => l !== listener);
  }

  emit(event: DshStreamEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(event);
      } catch (_) {}
    }
  }

  getIsConnected(): boolean {
    return this.isConnected;
  }

  getBaseUrl(): string {
    return this.baseUrl;
  }

  connect(baseUrl: string, token: string): Promise<boolean> {
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.token = token;

    if (this.ws) {
      try {
        this.ws.close();
      } catch (_) {}
      this.ws = null;
    }

    return new Promise((resolve) => {
      const wsUrl = `${this.baseUrl.replace(/^http/, 'ws')}/$events?token=${encodeURIComponent(this.token)}`;
      this.ws = webSocket.createWebSocket();

      this.ws.on('open', (_err, _value) => {
        this.isConnected = true;
        hilog.info(0x3F00, 'DshClient', 'WebSocket connected to DSH engine at %{public}s', this.baseUrl);
        resolve(true);
      });

      this.ws.on('message', (_err, value) => {
        let msg = '';
        if (typeof value === 'string') {
          msg = value;
        } else if (value instanceof ArrayBuffer) {
          const u8 = new Uint8Array(value);
          let str = '';
          for (let i = 0; i < u8.length; i++) {
            str += String.fromCharCode(u8[i]);
          }
          msg = str;
        }
        this.handleMessage(msg);
      });

      this.ws.on('close', (_err, _value) => {
        this.isConnected = false;
        hilog.info(0x3F00, 'DshClient', 'WebSocket closed from DSH engine');
      });

      this.ws.on('error', (err) => {
        this.isConnected = false;
        hilog.error(0x3F00, 'DshClient', 'WebSocket error: %{public}s', JSON.stringify(err));
        resolve(false);
      });

      this.ws.connect(wsUrl, {
        header: {
          'Origin': this.baseUrl,
          'User-Agent': 'Swai-HarmonyOS-Client'
        }
      }, (err, ok) => {
        if (err || !ok) {
          this.isConnected = false;
          resolve(false);
        }
      });
    });
  }

  disconnect(): void {
    if (this.ws) {
      try {
        this.ws.close();
      } catch (_) {}
      this.ws = null;
    }
    this.isConnected = false;
  }

  private handleMessage(raw: string): void {
    if (!raw || raw.trim().length === 0) {
      return;
    }

    try {
      const data = JSON.parse(raw) as Record<string, Object>;
      const type = (data['type'] as string) || (data['kind'] as string) || '';

      if (type === 'thinking' || type === 'reasoning') {
        this.emit({ kind: 'thinking', content: (data['content'] as string) || '' });
      } else if (type === 'token' || type === 'content' || type === 'chunk') {
        this.emit({ kind: 'token', content: (data['content'] as string) || (data['delta'] as string) || '' });
      } else if (type === 'tool_call') {
        this.emit({
          kind: 'tool_call',
          toolName: (data['name'] as string) || '',
          toolArgs: typeof data['args'] === 'string' ? data['args'] : JSON.stringify(data['args'] || {})
        });
      } else if (type === 'tool_result') {
        this.emit({
          kind: 'tool_result',
          toolName: (data['name'] as string) || '',
          toolOutput: (data['output'] as string) || ''
        });
      } else if (type === 'done' || type === 'finish') {
        this.emit({ kind: 'done' });
      } else if (type === 'error') {
        this.emit({ kind: 'error', error: (data['message'] as string) || 'DSH error' });
      }
    } catch (_) {
      // Raw string fallback
      this.emit({ kind: 'token', content: raw });
    }
  }

  async sendPrompt(prompt: string, images?: ImageAttachment[]): Promise<boolean> {
    if (!this.baseUrl) {
      this.emit({ kind: 'error', error: 'DSH engine is not connected.' });
      return false;
    }

    const client = http.createHttp();
    const endpoint = `${this.baseUrl}/api/v1/sessions/${this.currentSessionId}/messages`;
    const payloadObj: Record<string, Object> = {
      'role': 'user',
      'content': prompt,
      'stream': true
    };
    if (images && images.length > 0) {
      payloadObj['images'] = images as Object;
    }
    const payload = JSON.stringify(payloadObj);

    try {
      const res = await client.request(endpoint, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${this.token}`,
          'X-DSH-Token': this.token
        },
        extraData: payload,
        readTimeout: 60000,
        connectTimeout: 5000
      });

      if (res.responseCode >= 200 && res.responseCode < 300) {
        return true;
      } else {
        this.emit({ kind: 'error', error: `HTTP ${res.responseCode}: ${res.result}` });
        return false;
      }
    } catch (err) {
      this.emit({ kind: 'error', error: `Failed to send prompt: ${err}` });
      return false;
    } finally {
      client.destroy();
    }
  }

  async interrupt(): Promise<boolean> {
    if (!this.baseUrl) {
      return false;
    }

    const client = http.createHttp();
    const endpoint = `${this.baseUrl}/api/v1/sessions/${this.currentSessionId}/cancel`;

    try {
      const res = await client.request(endpoint, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${this.token}`
        },
        connectTimeout: 3000
      });
      return res.responseCode >= 200 && res.responseCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.destroy();
    }
  }
}
