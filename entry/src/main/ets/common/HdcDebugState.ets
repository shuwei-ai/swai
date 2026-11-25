/*
 * Pure state-machine types and helpers for HarmonyOS developer wireless
 * debugging setup & connection status.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

export type HdcDebugPhase =
  'checking' |
  'not_enabled' |
  'awaiting_auth' |
  'auth_rejected' |
  'need_port' |
  'connected';

export interface HdcDebugSnapshot {
  phase: HdcDebugPhase;
  connected: boolean;
  host: string;
  port: number;
  lastPort: number;
  lastError: string;
  lastReason: string;
  uidVerified: boolean;
  uidInfo: string;
  publicKey: string;
  updatedAt: number;
}

export interface DebugPhaseUiCopy {
  title: string;
  subtitle: string;
  badgeText: string;
  headerText: string;
  actionText: string;
  isReady: boolean;
}

export function createInitialDebugSnapshot(): HdcDebugSnapshot {
  return {
    phase: 'checking',
    connected: false,
    host: '127.0.0.1',
    port: 0,
    lastPort: 0,
    lastError: '',
    lastReason: '',
    uidVerified: false,
    uidInfo: '',
    publicKey: '',
    updatedAt: 0
  };
}

export function cloneDebugSnapshot(source: HdcDebugSnapshot): HdcDebugSnapshot {
  return {
    phase: source.phase,
    connected: source.connected,
    host: source.host,
    port: source.port,
    lastPort: source.lastPort,
    lastError: source.lastError,
    lastReason: source.lastReason,
    uidVerified: source.uidVerified,
    uidInfo: source.uidInfo,
    publicKey: source.publicKey,
    updatedAt: source.updatedAt
  };
}

export function mapConnectFailureToPhase(reason: string, isManualPort: boolean): HdcDebugPhase {
  if (reason === 'auth_rejected' || reason === 'auth_timeout') {
    return 'auth_rejected';
  }
  if (reason === 'need_port' || reason === 'connect_timeout') {
    return 'need_port';
  }
  if (isManualPort) {
    return 'need_port';
  }
  return 'not_enabled';
}

export function parsePortInput(portText: string): number {
  const trimmed = portText.trim();
  if (trimmed.length === 0) {
    return 0;
  }
  for (let i = 0; i < trimmed.length; i++) {
    const code = trimmed.charCodeAt(i);
    if (code < 48 || code > 57) {
      return 0;
    }
  }
  const parsed = Number.parseInt(trimmed, 10);
  if (!Number.isFinite(parsed) || parsed < 1 || parsed > 65535) {
    return 0;
  }
  return parsed;
}

export function isValidPortInput(portText: string): boolean {
  return parsePortInput(portText) > 0;
}

export function formatPublicKeyFingerprint(pem: string): string {
  const trimmed = pem.trim();
  if (trimmed.length === 0) {
    return '未生成';
  }
  const lines = trimmed.split(/\r?\n/);
  const bodyParts: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.length === 0 || line.startsWith('-----BEGIN') || line.startsWith('-----END')) {
      continue;
    }
    bodyParts.push(line);
  }
  const body = bodyParts.join('');
  if (body.length === 0) {
    return '未生成';
  }
  if (body.length <= 20) {
    return body;
  }
  return `${body.slice(0, 10)}...${body.slice(body.length - 10)}`;
}

export function getDebugPhaseSummary(phase: HdcDebugPhase, port: number): DebugPhaseUiCopy {
  switch (phase) {
    case 'connected':
      return {
        title: '开发者调试',
        subtitle: port > 0 ? `端口 ${port} · uid 2000 已就绪` : 'uid 2000 通道已就绪',
        badgeText: port > 0 ? `:${port}` : '已就绪',
        headerText: '开发者调试已就绪',
        actionText: '管理 ›',
        isReady: true
      };
    case 'checking':
      return {
        title: '开发者调试',
        subtitle: '正在检测本机无线调试服务...',
        badgeText: '检测中',
        headerText: '正在检测调试服务...',
        actionText: '查看 ›',
        isReady: false
      };
    case 'awaiting_auth':
      return {
        title: '开启开发者调试',
        subtitle: '请在系统弹窗中勾选「始终允许」',
        badgeText: '待授权',
        headerText: '请在系统弹窗允许调试',
        actionText: '去查看 ›',
        isReady: false
      };
    case 'auth_rejected':
      return {
        title: '开启开发者调试',
        subtitle: '调试授权未通过，请重新连接并允许',
        badgeText: '待重试',
        headerText: '调试授权未通过 · 点击重试',
        actionText: '去重试 ›',
        isReady: false
      };
    case 'need_port':
      return {
        title: '开启开发者调试',
        subtitle: '未自动识别端口，可手动填写端口号',
        badgeText: '需配置',
        headerText: '调试端口未识别 · 点击配置',
        actionText: '填端口 ›',
        isReady: false
      };
    case 'not_enabled':
    default:
      return {
        title: '开启开发者调试',
        subtitle: '开启无线调试，解锁跨应用自动化与 Shell',
        badgeText: '未开启',
        headerText: '未开启开发者调试 · 点击配置',
        actionText: '去开启 ›',
        isReady: false
      };
  }
}
