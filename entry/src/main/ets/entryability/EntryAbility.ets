import UIAbility from '@ohos.app.ability.UIAbility';
import type Want from '@ohos.app.ability.Want';
import type window from '@ohos.window';
import { AbilityConstant } from '@kit.AbilityKit';
import hilog from '@ohos.hilog';
import webview from '@ohos.web.webview';
import { BridgeController } from '../common/BridgeController';
import { FloatWindowManager } from '../window/FloatWindowManager';
import { ThinkingCapsuleManager } from '../window/ThinkingCapsuleManager';
import { AgentWorkspace } from '../agent/tools/AgentWorkspace';
import { DshAgentManager } from '../agent/dsh/DshAgentManager';
import { BackgroundKeepAliveManager } from '../service/BackgroundKeepAliveManager';

const TAG: string = 'SwShell';
const DOMAIN: number = 0x3201;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const startMs = Date.now();
    AppStorage.setOrCreate('appStartEpochMs', startMs);
    hilog.info(DOMAIN, TAG, '[Startup] EntryAbility.onCreate');

    AppStorage.setOrCreate('abilityContext', this.context);
    AppStorage.setOrCreate('appForegroundTick', 0);

    // Pre-warm DSH runtime and embedded Node engine FIRST so libnode.so + Node boot run in parallel
    // with synchronous WebView engine initialization (~190ms) and window creation.
    const filesDir = this.context.filesDir;
    AgentWorkspace.getInstance().init(this.context);
    AgentWorkspace.getInstance().ensureDshRuntime().then((runtimeDir: string) => {
      hilog.info(DOMAIN, TAG, '[Startup] ensureDshRuntime ready at %{public}d ms', Date.now() - startMs);
      if (!runtimeDir || runtimeDir.length === 0) {
        hilog.error(DOMAIN, TAG, '[Startup] ensureDshRuntime returned empty path; skipping Node launch');
        DshAgentManager.getInstance().reportStartError('DSH 运行时解压失败，请重启应用或检查存储空间');
        return;
      }
      DshAgentManager.getInstance().startEngine(runtimeDir, filesDir + '/workspace');
    }).catch((err: Object) => {
      hilog.error(DOMAIN, TAG, '[Startup] ensureDshRuntime failed: %{public}s', `${err}`);
      DshAgentManager.getInstance().reportStartError(`DSH 运行时初始化失败: ${err}`);
    });

    // Pre-warm ArkWeb Chromium engine asynchronously in parallel with Node startup
    try {
      webview.WebviewController.initializeWebEngine();
    } catch (_webInitErr) {}

    BridgeController.getInstance().init(this.context);
    FloatWindowManager.getInstance().init(this.context);
    ThinkingCapsuleManager.getInstance().init(this.context);
    BackgroundKeepAliveManager.getInstance().init(this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    AppStorage.setOrCreate('windowStage', windowStage);
    let mainWin: window.Window | null = null;
    let pageLoaded = false;
    const tryBindCapsule = (): void => {
      if (mainWin !== null && pageLoaded) {
        try {
          ThinkingCapsuleManager.getInstance().bindUIContext(this.context, mainWin.getUIContext());
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'failed to bind ThinkingCapsule UIContext: %{public}s', JSON.stringify(err));
        }
      }
    };
    windowStage.getMainWindow().then((win: window.Window) => {
      mainWin = win;
      AppStorage.setOrCreate('mainWindow', win);
      tryBindCapsule();
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'failed to get main window: %{public}s', JSON.stringify(err));
    });

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'failed to load the index page: %{public}s', JSON.stringify(err));
        return;
      }
      const startMs = AppStorage.get<number>('appStartEpochMs') ?? Date.now();
      hilog.info(DOMAIN, TAG, '[Startup] index page loaded in %{public}d ms', Date.now() - startMs);
      pageLoaded = true;
      tryBindCapsule();
    });
  }

  onDestroy(): void {
    BackgroundKeepAliveManager.getInstance().stop();
    ThinkingCapsuleManager.getInstance().destroy();
    FloatWindowManager.getInstance().destroy();
  }

  onForeground(): void {
    BackgroundKeepAliveManager.getInstance().onAppForeground();
    ThinkingCapsuleManager.getInstance().onAppForeground();
    FloatWindowManager.getInstance().onAppForeground();
    const prevTick = AppStorage.get<number>('appForegroundTick') ?? 0;
    AppStorage.setOrCreate('appForegroundTick', prevTick + 1);
  }

  onBackground(): void {
    BackgroundKeepAliveManager.getInstance().onAppBackground();
    ThinkingCapsuleManager.getInstance().onAppBackground();
    FloatWindowManager.getInstance().onAppBackground();
  }
}
