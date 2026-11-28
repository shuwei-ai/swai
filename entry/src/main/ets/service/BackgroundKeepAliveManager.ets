/*
 * BackgroundKeepAliveManager: Migrates ClashBox's HarmonyOS continuous background task strategies
 * (low-power simulated location, simulated download/dataTransfer live-view, tablet taskKeeping,
 * plus suspendDelay safety net) to prevent Swai & embedded DSH/Node from being frozen in background.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import { abilityAccessCtrl, common, Permissions, WantAgent, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { geoLocationManager } from '@kit.LocationKit';
import { notificationManager } from '@kit.NotificationKit';
import dataPreferences from '@ohos.data.preferences';
import hilog from '@ohos.hilog';

const DOMAIN: number = 0x3205;
const TAG: string = 'BackgroundKeepAlive';
const PREF_STORE = 'swshell_keep_alive';
const PREF_KEY_MODE = 'keep_alive_mode';

export type KeepAliveMode = 'location' | 'dataTransfer' | 'taskKeeping' | 'off';

export class BackgroundKeepAliveManager {
  private static instance: BackgroundKeepAliveManager = new BackgroundKeepAliveManager();

  private context: common.UIAbilityContext | null = null;
  private mode: KeepAliveMode = 'location';
  private activeMode: KeepAliveMode | null = null;
  private notificationId: number | undefined = undefined;
  private locationCallback: ((location: geoLocationManager.Location) => void) | undefined = undefined;
  private downloadHeartbeatTimer: number = -1;
  private downloadProgressTick: number = 0;
  private suspendDelayId: number = -1;
  private startPromise: Promise<void> | null = null;

  static getInstance(): BackgroundKeepAliveManager {
    return BackgroundKeepAliveManager.instance;
  }

  private syncAppStorage(statusText: string): void {
    AppStorage.setOrCreate('bgKeepAliveMode', this.mode);
    AppStorage.setOrCreate('bgKeepAliveActive', this.activeMode !== null);
    AppStorage.setOrCreate('bgKeepAliveStatusText', statusText);
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    try {
      const store = await dataPreferences.getPreferences(context, { name: PREF_STORE });
      const saved = (await store.get(PREF_KEY_MODE, 'location')) as string;
      if (saved === 'location' || saved === 'dataTransfer' || saved === 'taskKeeping' || saved === 'off') {
        this.mode = saved as KeepAliveMode;
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to read keep-alive mode preference: %{public}s', JSON.stringify(err));
    }
    this.syncAppStorage(this.mode === 'off' ? '已关闭' : '准备启动');
  }

  getMode(): KeepAliveMode {
    return this.mode;
  }

  isRunning(): boolean {
    return this.activeMode !== null;
  }

  async setMode(newMode: KeepAliveMode): Promise<void> {
    this.mode = newMode;
    if (this.context) {
      try {
        const store = await dataPreferences.getPreferences(this.context, { name: PREF_STORE });
        await store.put(PREF_KEY_MODE, newMode);
        await store.flush();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'Failed to save keep-alive mode: %{public}s', JSON.stringify(err));
      }
    }

    await this.stop();
    if (newMode === 'off') {
      this.syncAppStorage('已关闭');
      return;
    }
    await this.ensureStarted();
  }

  async ensureStarted(): Promise<void> {
    if (this.mode === 'off' || !this.context) {
      this.syncAppStorage(this.mode === 'off' ? '已关闭' : '等待初始化');
      return;
    }
    if (this.activeMode !== null) {
      return;
    }
    if (this.startPromise) {
      return await this.startPromise;
    }

    this.startPromise = this.doStart(this.context, this.mode);
    try {
      await this.startPromise;
    } finally {
      this.startPromise = null;
    }
  }

  private async doStart(context: common.UIAbilityContext, targetMode: KeepAliveMode): Promise<void> {
    if (targetMode === 'taskKeeping') {
      const ok = await this.startTaskKeepingMode(context);
      if (ok) {
        return;
      }
      // Phone devices do not support taskKeeping; fall back to location -> dataTransfer
      const locOk = await this.startLocationMode(context);
      if (!locOk) {
        await this.startDataTransferMode(context);
      }
      return;
    }

    if (targetMode === 'location') {
      const ok = await this.startLocationMode(context);
      if (!ok) {
        hilog.warn(DOMAIN, TAG, 'Location keep-alive unavailable, falling back to dataTransfer mode');
        await this.startDataTransferMode(context);
      }
      return;
    }

    if (targetMode === 'dataTransfer') {
      await this.startDataTransferMode(context);
    }
  }

  private async buildWantAgent(context: common.UIAbilityContext): Promise<WantAgent> {
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.applicationInfo.name,
          abilityName: 'EntryAbility'
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(wantAgentInfo);
  }

  private async ensureNotificationEnabled(context: common.UIAbilityContext): Promise<void> {
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        await notificationManager.requestEnableNotification(context);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Notification enable check skipped/rejected: %{public}s', JSON.stringify(err));
    }
  }

  private async requestLocationPermissions(context: common.UIAbilityContext): Promise<boolean> {
    const atManager = abilityAccessCtrl.createAtManager();
    const basePerms: Permissions[] = [
      'ohos.permission.APPROXIMATELY_LOCATION',
      'ohos.permission.LOCATION'
    ];
    try {
      const result = await atManager.requestPermissionsFromUser(context, basePerms);
      const granted = result.authResults.length > 0 && result.authResults.some(code => code === 0);
      if (!granted) {
        return false;
      }
      try {
        await atManager.requestPermissionsFromUser(context, ['ohos.permission.LOCATION_IN_BACKGROUND']);
      } catch (_bgErr) {
        // Optional background location grant; location continuous task can still activate while active/granted
      }
      return true;
    } catch (err) {
      const bErr = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'requestPermissionsFromUser failed: code=%{public}d msg=%{public}s', bErr.code ?? -1, bErr.message ?? '');
      return false;
    }
  }

  private async startLocationMode(context: common.UIAbilityContext): Promise<boolean> {
    this.syncAppStorage('请求定位权限...');
    await this.ensureNotificationEnabled(context);

    const hasPerm = await this.requestLocationPermissions(context);
    if (!hasPerm) {
      hilog.warn(DOMAIN, TAG, 'Location permission denied by user');
      this.syncAppStorage('定位权限未授');
      return false;
    }

    try {
      const wantAgentObj = await this.buildWantAgent(context);
      const res = await backgroundTaskManager.startBackgroundRunning(context, ['location'], wantAgentObj);
      this.notificationId = res.notificationId;

      // Ultra-low-power periodic location listener keeps HarmonyOS location continuous-task watchdog satisfied
      const request: geoLocationManager.LocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.LOW_POWER,
        timeInterval: 7200,
        distanceInterval: 10000,
        maxAccuracy: 1000
      };
      this.locationCallback = (_location: geoLocationManager.Location) => {
        // Intentionally lightweight no-op heartbeat
      };
      geoLocationManager.on('locationChange', request, this.locationCallback);

      this.activeMode = 'location';
      this.syncAppStorage('模拟定位保活中');
      hilog.info(DOMAIN, TAG, 'Started location background keep-alive (notificationId=%{public}d)', res.notificationId);
      return true;
    } catch (err) {
      const bErr = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'startLocationMode failed: code=%{public}d msg=%{public}s', bErr.code ?? -1, bErr.message ?? '');
      try {
        await backgroundTaskManager.stopBackgroundRunning(context);
      } catch (_stopErr) {
        // ignore
      }
      this.notificationId = undefined;
      this.activeMode = null;
      return false;
    }
  }

  private async startDataTransferMode(context: common.UIAbilityContext): Promise<boolean> {
    this.syncAppStorage('启动模拟下载保活...');
    await this.ensureNotificationEnabled(context);

    try {
      const wantAgentObj = await this.buildWantAgent(context);
      const res = await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], wantAgentObj);
      this.notificationId = res.notificationId;
      this.activeMode = 'dataTransfer';
      this.syncAppStorage('模拟下载保活中');

      this.publishDownloadKeepAliveNotification(res.notificationId);
      if (this.downloadHeartbeatTimer !== -1) {
        clearInterval(this.downloadHeartbeatTimer);
      }
      this.downloadHeartbeatTimer = setInterval(() => {
        if (this.notificationId !== undefined && this.activeMode === 'dataTransfer') {
          this.publishDownloadKeepAliveNotification(this.notificationId);
        }
      }, 10000);

      hilog.info(DOMAIN, TAG, 'Started dataTransfer background keep-alive (notificationId=%{public}d)', res.notificationId);
      return true;
    } catch (err) {
      const bErr = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'startDataTransferMode failed: code=%{public}d msg=%{public}s', bErr.code ?? -1, bErr.message ?? '');
      this.syncAppStorage('保活未激活');
      return false;
    }
  }

  private publishDownloadKeepAliveNotification(id: number): void {
    notificationManager.isSupportTemplate('downloadTemplate').then((supported: boolean) => {
      if (!supported) {
        return;
      }
      this.downloadProgressTick = (this.downloadProgressTick + 1) % 2;
      const template: notificationManager.NotificationTemplate = {
        name: 'downloadTemplate',
        data: {
          title: 'Swai 后台任务运行中',
          fileName: '智能体保活通道运行中，请勿划掉通知',
          progressValue: this.downloadProgressTick === 0 ? 98 : 99
        }
      };
      const request: notificationManager.NotificationRequest = {
        id: id,
        notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
        template: template,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: {
            typeCode: 8,
            title: 'Swai 智能体后台运行中',
            text: '后台任务保护中，切换应用不被冻结'
          }
        }
      };
      notificationManager.publish(request).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'publish live-view notification failed: code=%{public}d', err.code ?? -1);
      });
    }).catch((_err: BusinessError) => {
      // ignore if template check fails
    });
  }

  private async startTaskKeepingMode(context: common.UIAbilityContext): Promise<boolean> {
    if (deviceInfo.deviceType !== 'tablet' && deviceInfo.deviceType !== '2in1') {
      hilog.info(DOMAIN, TAG, 'taskKeeping skipped on deviceType=%{public}s', deviceInfo.deviceType);
      return false;
    }
    try {
      const wantAgentObj = await this.buildWantAgent(context);
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.TASK_KEEPING,
        wantAgentObj
      );
      this.notificationId = undefined;
      this.activeMode = 'taskKeeping';
      this.syncAppStorage('任务保持运行中');
      hilog.info(DOMAIN, TAG, 'Started taskKeeping background keep-alive');
      return true;
    } catch (err) {
      const bErr = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'startTaskKeepingMode failed: code=%{public}d msg=%{public}s', bErr.code ?? -1, bErr.message ?? '');
      return false;
    }
  }

  async stop(): Promise<void> {
    if (this.downloadHeartbeatTimer !== -1) {
      clearInterval(this.downloadHeartbeatTimer);
      this.downloadHeartbeatTimer = -1;
    }
    if (this.locationCallback) {
      try {
        geoLocationManager.off('locationChange', this.locationCallback);
      } catch (_err) {
        // ignore
      }
      this.locationCallback = undefined;
    }
    this.cancelTransientSuspendDelay();

    const wasActive = this.activeMode !== null;
    this.activeMode = null;
    this.notificationId = undefined;

    if (wasActive && this.context) {
      try {
        await backgroundTaskManager.stopBackgroundRunning(this.context);
        hilog.info(DOMAIN, TAG, 'Stopped continuous background keep-alive');
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'stopBackgroundRunning error: %{public}s', JSON.stringify(err));
      }
    }
    this.syncAppStorage(this.mode === 'off' ? '已关闭' : '未激活');
  }

  onAppForeground(): void {
    this.cancelTransientSuspendDelay();
    if (this.mode !== 'off' && this.activeMode === null) {
      this.ensureStarted();
    }
  }

  onAppBackground(): void {
    if (this.mode === 'off') {
      return;
    }
    if (this.activeMode === null) {
      this.ensureStarted();
      this.requestTransientSuspendDelay();
    } else {
      hilog.info(DOMAIN, TAG, 'Entered background with active keep-alive mode=%{public}s', this.activeMode);
    }
  }

  private requestTransientSuspendDelay(): void {
    if (this.suspendDelayId !== -1) {
      return;
    }
    try {
      const info = backgroundTaskManager.requestSuspendDelay('SwaiBackgroundGuard', () => {
        hilog.warn(DOMAIN, TAG, 'Transient suspend delay expiring');
        this.cancelTransientSuspendDelay();
      });
      this.suspendDelayId = info.requestId;
      hilog.info(DOMAIN, TAG, 'Requested transient suspend delay id=%{public}d', this.suspendDelayId);
    } catch (_err) {
      // ignore if quota exhausted
    }
  }

  private cancelTransientSuspendDelay(): void {
    if (this.suspendDelayId === -1) {
      return;
    }
    try {
      backgroundTaskManager.cancelSuspendDelay(this.suspendDelayId);
    } catch (_err) {
      // ignore
    }
    this.suspendDelayId = -1;
  }
}
