/*
 * The bridge's shared state: the device connection, setup state machine,
 * persisted port cache, and the commands that run on it.
 *
 * The UI and the service extension both use this, so there is exactly one
 * native session in the process.
 */
import common from '@ohos.app.ability.common';
import dataPreferences from '@ohos.data.preferences';

import {
  cloneDebugSnapshot,
  createInitialDebugSnapshot,
  HdcDebugSnapshot,
  mapConnectFailureToPhase
} from './HdcDebugState';
import {
  abortNative,
  connectNative,
  disconnectNative,
  discoverNative,
  execNative,
  execStreamNative,
  getSessionStateNative,
  initNative,
  isConnectedNative,
  listPortsNative,
  publicKeyNative,
  ShellConnectResult,
  ShellDiscoveryResult,
  ShellExecResult
} from './NativeBridge';

const PREF_STORE_NAME: string = 'swshell_bridge_prefs';
const KEY_LAST_HOST: string = 'last_host';
const KEY_LAST_PORT: string = 'last_port';

export interface BridgeStatus {
  connected: boolean;
  host: string;
  port: number;
  lastError: string;
  publicKey: string;
}

export type DebugStateListener = (snapshot: HdcDebugSnapshot) => void;

export class BridgeController {
  private static instance: BridgeController = new BridgeController();
  private initialized: boolean = false;
  private host: string = '127.0.0.1';
  private port: number = 0;
  private lastHost: string = '127.0.0.1';
  private lastPort: number = 0;
  private lastError: string = '';
  private prefs: dataPreferences.Preferences | undefined = undefined;
  private prefsLoaded: boolean = false;
  private debugSnapshot: HdcDebugSnapshot = createInitialDebugSnapshot();
  private listeners: DebugStateListener[] = [];
  private connectSeq: number = 0;
  private inFlightAutoConnect: Promise<ShellConnectResult> | null = null;

  static getInstance(): BridgeController {
    return BridgeController.instance;
  }

  /**
   * Prepares the native layer.  The keypair lives in the app's own files
   * directory: the device remembers the public key, so a stable keypair is
   * what keeps the permit dialog from appearing on every connect.
   */
  init(context: common.Context): boolean {
    if (this.initialized) {
      return true;
    }
    const ok = initNative(context.filesDir);
    this.initialized = ok;
    if (!ok) {
      this.lastError = 'failed to initialise the native library';
      this.debugSnapshot.lastError = this.lastError;
      this.debugSnapshot.phase = 'not_enabled';
    } else {
      this.loadPersistedTarget(context).catch(() => {});
    }
    return ok;
  }

  addStateListener(listener: DebugStateListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  removeStateListener(listener: DebugStateListener): void {
    this.listeners = this.listeners.filter((l: DebugStateListener) => l !== listener);
  }

  getDebugSnapshot(): HdcDebugSnapshot {
    const nativeState = getSessionStateNative();
    if (nativeState.connected) {
      this.debugSnapshot.connected = true;
      this.debugSnapshot.phase = 'connected';
      if (nativeState.port > 0) {
        this.debugSnapshot.port = nativeState.port;
        this.port = nativeState.port;
      }
    } else if (this.debugSnapshot.connected) {
      this.debugSnapshot.connected = false;
      this.debugSnapshot.phase = 'not_enabled';
      this.debugSnapshot.port = 0;
      this.debugSnapshot.uidVerified = false;
      this.debugSnapshot.uidInfo = '';
    }
    if (this.initialized && this.debugSnapshot.publicKey.length === 0) {
      this.debugSnapshot.publicKey = publicKeyNative();
    }
    return cloneDebugSnapshot(this.debugSnapshot);
  }

  private emitSnapshot(): void {
    const snap = cloneDebugSnapshot(this.debugSnapshot);
    for (let i = 0; i < this.listeners.length; i++) {
      try {
        this.listeners[i](snap);
      } catch (_err) {
        // Ignore listener exceptions
      }
    }
  }

  private async openPreferences(context: common.Context): Promise<dataPreferences.Preferences | undefined> {
    if (this.prefs === undefined) {
      try {
        this.prefs = await dataPreferences.getPreferences(context, { name: PREF_STORE_NAME });
      } catch (_err) {
        return undefined;
      }
    }
    return this.prefs;
  }

  private async loadPersistedTarget(context: common.Context): Promise<void> {
    if (this.prefsLoaded) {
      return;
    }
    try {
      const store = await this.openPreferences(context);
      if (store === undefined) {
        return;
      }
      const savedHost = await store.get(KEY_LAST_HOST, '127.0.0.1') as string;
      const savedPort = await store.get(KEY_LAST_PORT, 0) as number;
      if (typeof savedHost === 'string' && savedHost.trim().length > 0) {
        this.lastHost = savedHost.trim();
      }
      if (typeof savedPort === 'number' && Number.isFinite(savedPort) && savedPort > 0 && savedPort <= 65535) {
        this.lastPort = savedPort;
        this.debugSnapshot.lastPort = savedPort;
      }
    } catch (_err) {
      // Ignore storage failures
    } finally {
      this.prefsLoaded = true;
    }
  }

  private async savePersistedTarget(context: common.Context, host: string, port: number): Promise<void> {
    if (port <= 0 || port > 65535) {
      return;
    }
    this.lastHost = host;
    this.lastPort = port;
    this.debugSnapshot.lastPort = port;
    try {
      const store = await this.openPreferences(context);
      if (store === undefined) {
        return;
      }
      await store.put(KEY_LAST_HOST, host);
      await store.put(KEY_LAST_PORT, port);
      await store.flush();
    } catch (_err) {
      // Ignore storage failures
    }
  }

  status(): BridgeStatus {
    const nativeState = getSessionStateNative();
    if (nativeState.connected && nativeState.port > 0) {
      this.port = nativeState.port;
    }
    return {
      connected: nativeState.connected,
      host: this.host,
      port: this.port,
      lastError: this.lastError,
      publicKey: publicKeyNative()
    };
  }

  /**
   * Asks the device which port its hdc daemon is listening on.  The user
   * can still type the port instead - this only saves them the trouble.
   */
  async discover(): Promise<ShellDiscoveryResult> {
    return await discoverNative();
  }

  /** The TCP ports the device is listening on. */
  listPorts(): number[] {
    return listPortsNative();
  }

  private async connectWithStatePolling(targetHost: string, targetPort: number): Promise<ShellConnectResult> {
    const timerId = setInterval(() => {
      try {
        const nativeState = getSessionStateNative();
        if (nativeState.awaitingAuth && this.debugSnapshot.phase !== 'awaiting_auth') {
          this.debugSnapshot.phase = 'awaiting_auth';
          if (nativeState.port > 0) {
            this.debugSnapshot.port = nativeState.port;
          } else if (targetPort > 0) {
            this.debugSnapshot.port = targetPort;
          }
          this.debugSnapshot.updatedAt = Date.now();
          this.emitSnapshot();
        }
      } catch (_err) {
        // Ignore polling errors
      }
    }, 300);

    try {
      return await connectNative(targetHost, targetPort);
    } finally {
      clearInterval(timerId);
    }
  }

  private async handleConnectSuccess(
    context: common.Context,
    targetHost: string,
    connectedPort: number
  ): Promise<void> {
    this.host = targetHost;
    this.port = connectedPort;
    this.lastError = '';
    this.debugSnapshot.phase = 'connected';
    this.debugSnapshot.connected = true;
    this.debugSnapshot.host = targetHost;
    this.debugSnapshot.port = connectedPort;
    if (connectedPort > 0) {
      this.debugSnapshot.lastPort = connectedPort;
    }
    this.debugSnapshot.lastError = '';
    this.debugSnapshot.lastReason = 'ok';
    this.debugSnapshot.publicKey = publicKeyNative();
    this.debugSnapshot.updatedAt = Date.now();
    this.emitSnapshot();

    await this.savePersistedTarget(context, targetHost, connectedPort);
    this.verifyUid().catch(() => '');
  }

  /**
   * Runs `id` over the connected HDC bridge to confirm uid 2000 (shell) context.
   */
  async verifyUid(): Promise<string> {
    if (!isConnectedNative()) {
      this.handleUnexpectedDisconnect('not connected to the device');
      return '';
    }
    const res = await execNative('id', '', 5);
    if (res.ok && res.output.trim().length > 0) {
      const firstLine = res.output.trim().split('\n')[0].trim();
      this.debugSnapshot.uidInfo = firstLine;
      this.debugSnapshot.uidVerified = firstLine.includes('uid=2000') || firstLine.includes('shell');
      this.debugSnapshot.updatedAt = Date.now();
      this.emitSnapshot();
      return firstLine;
    }
    if (!isConnectedNative()) {
      this.handleUnexpectedDisconnect(res.error);
    }
    return '';
  }

  /**
   * Zero-config auto discovery and connection flow:
   * 1. Cached last successful port
   * 2. UDP 8710 daemon discovery broadcast
   * 3. Filtered /proc/net/tcp + /proc/net/tcp6 loopback candidate scan
   */
  async autoConnect(context: common.Context): Promise<ShellConnectResult> {
    if (this.inFlightAutoConnect !== null) {
      return await this.inFlightAutoConnect;
    }
    const seq = ++this.connectSeq;
    const promise = this.doAutoConnect(context, seq);
    this.inFlightAutoConnect = promise;
    try {
      return await promise;
    } finally {
      if (this.inFlightAutoConnect === promise) {
        this.inFlightAutoConnect = null;
      }
    }
  }

  private async doAutoConnect(context: common.Context, seq: number): Promise<ShellConnectResult> {
    if (!this.init(context)) {
      this.debugSnapshot.phase = 'not_enabled';
      this.debugSnapshot.connected = false;
      this.debugSnapshot.lastError = this.lastError;
      this.debugSnapshot.lastReason = 'error';
      this.debugSnapshot.updatedAt = Date.now();
      this.emitSnapshot();
      return { ok: false, port: 0, reason: 'error', error: this.lastError };
    }

    const existingState = getSessionStateNative();
    if (existingState.connected) {
      const resolvedPort = existingState.port > 0 ? existingState.port : this.port;
      this.port = resolvedPort;
      this.debugSnapshot.phase = 'connected';
      this.debugSnapshot.connected = true;
      this.debugSnapshot.port = resolvedPort;
      this.debugSnapshot.publicKey = publicKeyNative();
      this.debugSnapshot.updatedAt = Date.now();
      this.emitSnapshot();
      if (!this.debugSnapshot.uidVerified) {
        this.verifyUid().catch(() => '');
      }
      return { ok: true, port: resolvedPort, reason: 'ok', error: '' };
    }

    this.debugSnapshot.phase = 'checking';
    this.debugSnapshot.connected = false;
    this.debugSnapshot.lastError = '';
    this.debugSnapshot.lastReason = '';
    this.debugSnapshot.uidVerified = false;
    this.debugSnapshot.uidInfo = '';
    this.debugSnapshot.publicKey = publicKeyNative();
    this.debugSnapshot.updatedAt = Date.now();
    this.emitSnapshot();

    await this.loadPersistedTarget(context);

    let lastResult: ShellConnectResult = {
      ok: false,
      port: 0,
      reason: 'not_running',
      error: '未检测到本地无线调试服务'
    };

    // 1. Try cached port first
    if (this.lastPort > 0) {
      const cachedResult = await this.connectWithStatePolling(this.lastHost, this.lastPort);
      if (cachedResult.ok) {
        const p = cachedResult.port > 0 ? cachedResult.port : this.lastPort;
        await this.handleConnectSuccess(context, this.lastHost, p);
        return { ok: true, port: p, reason: 'ok', error: '' };
      }
      lastResult = cachedResult;
      if (cachedResult.reason === 'auth_rejected' || cachedResult.reason === 'auth_timeout') {
        this.applyConnectFailure(seq, cachedResult, false);
        return cachedResult;
      }
    }

    // 2. Scan /proc/net/tcp + /proc/net/tcp6 with uid=2000 (hdcd) prioritized first
    const scanResult = await this.connectWithStatePolling('127.0.0.1', 0);
    if (scanResult.ok) {
      await this.handleConnectSuccess(context, '127.0.0.1', scanResult.port);
      return scanResult;
    }
    lastResult = scanResult;
    if (scanResult.reason === 'auth_rejected' || scanResult.reason === 'auth_timeout') {
      this.applyConnectFailure(seq, scanResult, false);
      return scanResult;
    }

    // 3. Fallback: UDP 8710 discovery broadcast (useful if /proc/net/tcp is restricted)
    const disc = await discoverNative();
    if (disc.port > 0 && disc.port !== this.lastPort) {
      const discResult = await this.connectWithStatePolling('127.0.0.1', disc.port);
      if (discResult.ok) {
        const p = discResult.port > 0 ? discResult.port : disc.port;
        await this.handleConnectSuccess(context, '127.0.0.1', p);
        return { ok: true, port: p, reason: 'ok', error: '' };
      }
      lastResult = discResult;
    }

    this.applyConnectFailure(seq, lastResult, false);
    return lastResult;
  }

  private applyConnectFailure(seq: number, result: ShellConnectResult, isManualPort: boolean): void {
    if (seq !== this.connectSeq || isConnectedNative()) {
      return;
    }
    this.lastError = result.error;
    this.debugSnapshot.phase = mapConnectFailureToPhase(result.reason, isManualPort);
    this.debugSnapshot.connected = false;
    this.debugSnapshot.port = 0;
    this.debugSnapshot.lastError = result.error;
    this.debugSnapshot.lastReason = result.reason;
    this.debugSnapshot.uidVerified = false;
    this.debugSnapshot.uidInfo = '';
    this.debugSnapshot.publicKey = publicKeyNative();
    this.debugSnapshot.updatedAt = Date.now();
    this.emitSnapshot();
  }

  /**
   * Connects to the device's hdc daemon.  When `port` is 0, delegates to the
   * full autoConnect pipeline.  When `port > 0`, connects to the explicit port.
   */
  async connect(context: common.Context, host: string, port: number): Promise<ShellConnectResult> {
    if (port <= 0) {
      return await this.autoConnect(context);
    }
    if (!this.init(context)) {
      this.debugSnapshot.phase = 'not_enabled';
      this.debugSnapshot.connected = false;
      this.debugSnapshot.lastError = this.lastError;
      this.debugSnapshot.lastReason = 'error';
      this.debugSnapshot.updatedAt = Date.now();
      this.emitSnapshot();
      return { ok: false, port: 0, reason: 'error', error: this.lastError };
    }
    const targetHost = host.trim().length > 0 ? host.trim() : '127.0.0.1';
    const seq = ++this.connectSeq;
    this.host = targetHost;
    this.port = port;
    this.debugSnapshot.phase = 'checking';
    this.debugSnapshot.connected = false;
    this.debugSnapshot.host = targetHost;
    this.debugSnapshot.port = port;
    this.debugSnapshot.lastError = '';
    this.debugSnapshot.lastReason = '';
    this.debugSnapshot.uidVerified = false;
    this.debugSnapshot.uidInfo = '';
    this.debugSnapshot.publicKey = publicKeyNative();
    this.debugSnapshot.updatedAt = Date.now();
    this.emitSnapshot();

    const result = await this.connectWithStatePolling(targetHost, port);
    if (result.ok) {
      const resolvedPort = result.port > 0 ? result.port : port;
      await this.handleConnectSuccess(context, targetHost, resolvedPort);
      return { ok: true, port: resolvedPort, reason: 'ok', error: '' };
    }
    this.applyConnectFailure(seq, result, true);
    return result;
  }

  disconnect(): void {
    ++this.connectSeq;
    disconnectNative();
    this.port = 0;
    this.lastError = '';
    this.debugSnapshot.phase = 'not_enabled';
    this.debugSnapshot.connected = false;
    this.debugSnapshot.port = 0;
    this.debugSnapshot.lastError = '';
    this.debugSnapshot.lastReason = '';
    this.debugSnapshot.uidVerified = false;
    this.debugSnapshot.uidInfo = '';
    this.debugSnapshot.updatedAt = Date.now();
    this.emitSnapshot();
  }

  private handleUnexpectedDisconnect(errorDetail: string): void {
    if (!this.debugSnapshot.connected && this.debugSnapshot.phase !== 'connected') {
      return;
    }
    this.port = 0;
    this.lastError = errorDetail;
    this.debugSnapshot.phase = 'not_enabled';
    this.debugSnapshot.connected = false;
    this.debugSnapshot.port = 0;
    this.debugSnapshot.lastError = errorDetail;
    this.debugSnapshot.lastReason = 'not_running';
    this.debugSnapshot.uidVerified = false;
    this.debugSnapshot.uidInfo = '';
    this.debugSnapshot.updatedAt = Date.now();
    this.emitSnapshot();
  }

  /**
   * Runs a command on the device with streaming output.
   * onData is called as chunks arrive in real time.
   */
  async execStream(
    command: string,
    onData?: (chunk: string) => void,
    bundleName: string = '',
    timeoutSeconds: number = 0
  ): Promise<ShellExecResult> {
    const result = await execStreamNative(command, bundleName, onData, timeoutSeconds);
    if (!result.ok && !isConnectedNative()) {
      this.handleUnexpectedDisconnect(result.error);
    }
    return result;
  }

  /**
   * Interrupts the currently executing command on the daemon.
   */
  abort(): boolean {
    return abortNative();
  }

  /**
   * Runs a command on the device.  The command executes as uid 2000 (shell).
   * Defaults to a 30s timeout to prevent infinite hangs on blocking tools.
   */
  async exec(
    command: string,
    bundleName: string = '',
    timeoutSeconds: number = 30
  ): Promise<ShellExecResult> {
    const result = await execNative(command, bundleName, timeoutSeconds);
    if (!result.ok && !isConnectedNative()) {
      this.handleUnexpectedDisconnect(result.error);
    }
    return result;
  }
}
