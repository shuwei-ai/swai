/*
 * ThinkingCapsuleManager: 3-tier adaptive HarmonyOS Thinking Capsule for cross-app UI automation.
 *
 * Tier 1: @kit.LiveViewKit LiveView Island Capsule (with ProgressLayout).
 * Tier 2: @kit.ArkUI PiPWindow (VIDEO_LIVE + compact size + corner adsorption) + BuilderNode
 *         edge-to-edge Dynamic-Island glass capsule without requiring SYSTEM_FLOAT_WINDOW.
 * Tier 3: @kit.NotificationKit ongoing/completion notification fallback (tappable to return to Swai).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import { common, Want, WantAgent, wantAgent } from '@kit.AbilityKit';
import { BuilderNode, FrameNode, NodeController, PiPWindow, typeNode, UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { liveViewManager } from '@kit.LiveViewKit';
import { notificationManager } from '@kit.NotificationKit';
import dataPreferences from '@ohos.data.preferences';
import hilog from '@ohos.hilog';
import { AppKnowledgeBase } from '../agent/knowledge/AppKnowledgeBase';

const DOMAIN: number = 0x3206;
const TAG: string = 'ThinkingCapsule';
const PREF_STORE: string = 'swshell_capsule';
const PREF_KEY_ENABLED: string = 'capsule_enabled';
const LIVE_VIEW_ID: number = 9051;
const NOTIFICATION_ID: number = 291;
const DONE_AUTO_DISMISS_SEC: number = 6;
const ERROR_AUTO_DISMISS_SEC: number = 8;
const SAFETY_IDLE_TIMEOUT_MS: number = 25000;

export interface CapsuleScreenRect {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

export class CapsuleUiParams {
  badgeLabel: string = '执行中';
  headline: string = '准备执行任务';
  subtext: string = '后台保活运行中 · 点击返回 Swai';
  appLabel: string = '';
  stepCount: number = 0;
  elapsedSec: number = 0;
  animTick: number = 0;
  status: string = 'running'; // 'running' | 'done' | 'error'

  clone(): CapsuleUiParams {
    const copy = new CapsuleUiParams();
    copy.badgeLabel = this.badgeLabel;
    copy.headline = this.headline;
    copy.subtext = this.subtext;
    copy.appLabel = this.appLabel;
    copy.stepCount = this.stepCount;
    copy.elapsedSec = this.elapsedSec;
    copy.animTick = this.animTick;
    copy.status = this.status;
    return copy;
  }
}

function capsuleBgColors(status: string): Array<[ResourceColor, number]> {
  if (status === 'done') {
    return [['#072E23', 0.0], ['#091E19', 0.58], ['#0D362B', 1.0]];
  }
  if (status === 'error') {
    return [['#311218', 0.0], ['#1B0D12', 0.58], ['#2D1219', 1.0]];
  }
  return [['#11192E', 0.0], ['#0B1120', 0.55], ['#101C36', 1.0]];
}

function capsuleAccentColors(status: string): Array<[ResourceColor, number]> {
  if (status === 'done') {
    return [['#34D399', 0.0], ['#10B981', 1.0]];
  }
  if (status === 'error') {
    return [['#FB7185', 0.0], ['#EF4444', 1.0]];
  }
  return [['#38BDF8', 0.0], ['#818CF8', 1.0]];
}

function capsulePillBg(status: string): string {
  if (status === 'done') {
    return '#10B98133';
  }
  if (status === 'error') {
    return '#F43F5E33';
  }
  return '#38BDF826';
}

function capsulePillColor(status: string): string {
  if (status === 'done') {
    return '#6EE7B7';
  }
  if (status === 'error') {
    return '#FDA4AF';
  }
  return '#7DD3FC';
}

function capsuleDots(status: string, tick: number): string {
  if (status !== 'running') {
    return '';
  }
  const mod = tick % 3;
  if (mod === 0) {
    return ' ·';
  }
  if (mod === 1) {
    return ' ··';
  }
  return ' ···';
}

function formatMetaCounter(stepCount: number, elapsedSec: number): string {
  if (stepCount > 0 && elapsedSec > 0) {
    return `#${stepCount} · ${elapsedSec}s`;
  }
  if (stepCount > 0) {
    return `#${stepCount}`;
  }
  if (elapsedSec > 0) {
    return `${elapsedSec}s`;
  }
  return 'Swai';
}

@Builder
function ThinkingCapsuleBuilder(params: CapsuleUiParams) {
  Column() {
    // Top 3vp gradient accent hairline (full-bleed inside PiP system mask)
    Row()
      .width('100%')
      .height(3)
      .linearGradient({
        direction: GradientDirection.Right,
        colors: capsuleAccentColors(params.status)
      })

    Column({ space: 6 }) {
      // Header bar: mini status glyph + tinted pill + target app + step/time counter
      Row({ space: 6 }) {
        if (params.status === 'done') {
          Text('✓')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .width(18)
            .height(18)
            .borderRadius(9)
            .backgroundColor('#10B981')
        } else if (params.status === 'error') {
          Text('!')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .width(18)
            .height(18)
            .borderRadius(9)
            .backgroundColor('#EF4444')
        } else {
          Stack({ alignContent: Alignment.BottomEnd }) {
            Image($r('app.media.startIcon'))
              .width(18)
              .height(18)
              .borderRadius(5)
            Circle({ width: 6, height: 6 })
              .fill('#38BDF8')
          }
          .width(18)
          .height(18)
        }

        Text(`${params.badgeLabel}${capsuleDots(params.status, params.animTick)}`)
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(capsulePillColor(params.status))
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor(capsulePillBg(params.status))
          .borderRadius(10)

        if (params.appLabel.length > 0) {
          Text(params.appLabel)
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor('#CBD5E1')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        } else {
          Blank().layoutWeight(1)
        }

        Text(formatMetaCounter(params.stepCount, params.elapsedSec))
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor('#94A3B8')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('#1E293B80')
          .borderRadius(8)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // Center primary action / completion headline
      Column() {
        Text(params.headline)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F8FAFC')
          .lineHeight(18)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Start)

      // Bottom micro caption
      Text(params.subtext)
        .fontSize(10)
        .fontColor(params.status === 'done' ? '#6EE7B7' : '#94A3B8')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: 14, right: 14, top: 9, bottom: 10 })
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(HorizontalAlign.Start)
  }
  .width('100%')
  .height('100%')
  .linearGradient({
    angle: 135,
    colors: capsuleBgColors(params.status)
  })
}

class ThinkingCapsuleNodeController extends NodeController {
  private capsuleNode: BuilderNode<[CapsuleUiParams]> | null = null;
  private wrapBuilder: WrappedBuilder<[CapsuleUiParams]> = wrapBuilder(ThinkingCapsuleBuilder);
  private currentParams: CapsuleUiParams = new CapsuleUiParams();

  makeNode(uiContext: UIContext): FrameNode | null {
    if (this.capsuleNode === null) {
      this.capsuleNode = new BuilderNode<[CapsuleUiParams]>(uiContext);
      this.capsuleNode.build(this.wrapBuilder, this.currentParams.clone());
    }
    return this.capsuleNode.getFrameNode();
  }

  updateParams(next: CapsuleUiParams): void {
    this.currentParams = next.clone();
    if (this.capsuleNode !== null) {
      this.capsuleNode.update(this.currentParams.clone());
    }
  }
}

class CapsuleXComponentController extends XComponentController {
  onSurfaceCreated(surfaceId: string): void {
    hilog.debug(DOMAIN, TAG, 'Capsule XComponent surface created: %{public}s', surfaceId);
  }

  onSurfaceDestroyed(surfaceId: string): void {
    hilog.debug(DOMAIN, TAG, 'Capsule XComponent surface destroyed: %{public}s', surfaceId);
  }
}

export class ThinkingCapsuleManager {
  private static instance: ThinkingCapsuleManager = new ThinkingCapsuleManager();

  private context: common.UIAbilityContext | null = null;
  private uiContext: UIContext | null = null;
  private enabled: boolean = true;
  private inBackground: boolean = false;
  private turnActive: boolean = false;
  private automationActive: boolean = false;
  private activeToolDepth: number = 0;

  private params: CapsuleUiParams = new CapsuleUiParams();
  private turnStartMs: number = 0;
  private lastActivityMs: number = 0;
  private tickerTimer: number = -1;
  private dismissTimer: number = -1;
  private dismissCountdownSec: number = 0;
  private safetyIdleTimer: number = -1;

  // Tier 1: LiveViewKit
  private liveViewSupported: boolean | null = null;
  private liveViewActive: boolean = false;
  private liveViewSequence: number = 0;
  private liveViewStopTimer: number = -1;

  // Tier 2: PiPWindow + BuilderNode
  private xComponentController: CapsuleXComponentController = new CapsuleXComponentController();
  private xComponentNode: typeNode.XComponent | null = null;
  private nodeController: ThinkingCapsuleNodeController = new ThinkingCapsuleNodeController();
  private pipController: PiPWindow.PiPController | null = null;
  private pipCreating: boolean = false;
  private pipStarting: boolean = false;
  private pipActive: boolean = false;
  private observedOverlayRects: CapsuleScreenRect[] = [];
  private temporarilyHidden: boolean = false;

  // Tier 3: Ongoing / completion notification fallback
  private notificationActive: boolean = false;
  private lastNotifyMs: number = 0;

  static getInstance(): ThinkingCapsuleManager {
    return ThinkingCapsuleManager.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    try {
      const store = await dataPreferences.getPreferences(context, { name: PREF_STORE });
      const saved = await store.get(PREF_KEY_ENABLED, true);
      this.enabled = saved !== false;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to load capsule preference: %{public}s', JSON.stringify(err));
      this.enabled = true;
    }
    this.syncAppStorage();
  }

  async bindUIContext(context: common.UIAbilityContext, uiContext: UIContext): Promise<void> {
    this.context = context;
    this.uiContext = uiContext;
    await this.ensurePipController();
    this.syncAppStorage();
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  isCapsuleVisible(): boolean {
    return this.pipActive || this.pipStarting;
  }

  updateObservedOverlayBounds(rects: CapsuleScreenRect[]): void {
    if (rects.length > 0) {
      const copies: CapsuleScreenRect[] = [];
      for (let i = 0; i < rects.length; i++) {
        const r = rects[i];
        copies.push({ left: r.left, top: r.top, right: r.right, bottom: r.bottom });
      }
      this.observedOverlayRects = copies;
    } else if (!this.pipActive && !this.pipStarting && !this.temporarilyHidden) {
      this.observedOverlayRects = [];
    }
  }

  getExcludeBounds(): CapsuleScreenRect[] {
    if (!this.isCapsuleVisible()) {
      return [];
    }
    const copies: CapsuleScreenRect[] = [];
    for (let i = 0; i < this.observedOverlayRects.length; i++) {
      const r = this.observedOverlayRects[i];
      copies.push({ left: r.left, top: r.top, right: r.right, bottom: r.bottom });
    }
    return copies;
  }

  pointHitsCapsule(x: number, y: number, pad: number = 18): boolean {
    const rects = this.getExcludeBounds();
    for (let i = 0; i < rects.length; i++) {
      const r = rects[i];
      if (x >= r.left - pad && x <= r.right + pad && y >= r.top - pad && y <= r.bottom + pad) {
        return true;
      }
    }
    return false;
  }

  async temporaryHideForAction(reason: string): Promise<boolean> {
    if (!this.pipActive && !this.pipStarting) {
      return false;
    }
    this.temporarilyHidden = true;
    hilog.debug(DOMAIN, TAG, 'Temporarily hiding PiP capsule for %{public}s', reason);
    this.stopPiP();
    await new Promise<void>((resolve) => setTimeout(resolve, 220));
    return true;
  }

  restoreAfterTemporaryHide(): void {
    if (!this.temporarilyHidden) {
      return;
    }
    this.temporarilyHidden = false;
    if (this.enabled && (this.turnActive || this.automationActive) && this.inBackground) {
      this.ensurePiPStarted();
    }
  }

  async setEnabled(next: boolean): Promise<void> {
    this.enabled = next;
    if (this.context) {
      try {
        const store = await dataPreferences.getPreferences(this.context, { name: PREF_STORE });
        await store.put(PREF_KEY_ENABLED, next);
        await store.flush();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'Failed to save capsule preference: %{public}s', JSON.stringify(err));
      }
    }

    if (!next) {
      this.turnActive = false;
      this.automationActive = false;
      this.activeToolDepth = 0;
      this.clearAllTimers();
      await this.stopAllSurfaces();
    } else if (this.uiContext) {
      await this.ensurePipController();
    }
    this.syncAppStorage();
  }

  prepareForExternalApp(bundleOrApp: string): void {
    if (!this.enabled) {
      return;
    }
    this.clearDismissTimer();
    this.clearSafetyIdleTimer();
    this.clearLiveViewStopTimer();
    this.automationActive = true;
    this.turnActive = true;

    const now = Date.now();
    if (this.turnStartMs === 0 || this.params.status !== 'running' || now - this.lastActivityMs > 45000) {
      this.turnStartMs = now;
      this.params.stepCount = 0;
      this.params.elapsedSec = 0;
    }
    this.lastActivityMs = now;

    const appLabel = this.resolveAppLabel(bundleOrApp);
    this.params.appLabel = appLabel;
    this.params.status = 'running';
    this.params.badgeLabel = '执行中';
    this.params.headline = appLabel.length > 0 ? `正在打开 ${appLabel}` : '正在切换目标应用';
    this.params.subtext = '后台保活运行中 · 点击返回 Swai';
    this.nodeController.updateParams(this.params);

    this.setPipAutoStart(true);
    this.startTicker();
    this.syncSurfaces(true);
    this.syncAppStorage();
  }

  onCapsuleEvent(argsJson: string): void {
    let eventName = '';
    let summary = '';
    let errMsg = '';
    try {
      const parsed = JSON.parse(argsJson || '{}') as Record<string, Object>;
      if (typeof parsed['event'] === 'string') {
        eventName = parsed['event'] as string;
      }
      if (typeof parsed['summary'] === 'string') {
        summary = parsed['summary'] as string;
      }
      if (typeof parsed['error'] === 'string') {
        errMsg = parsed['error'] as string;
      }
    } catch (_err) {
      return;
    }

    if (eventName === 'turn_start') {
      this.onTurnStart();
    } else if (eventName === 'thinking') {
      this.onAgentThinking();
    } else if (eventName === 'turn_done') {
      this.onTurnComplete(summary);
    } else if (eventName === 'turn_error') {
      this.onTurnError(errMsg);
    }
  }

  onTurnStart(): void {
    if (!this.enabled) {
      return;
    }
    this.clearDismissTimer();
    this.clearSafetyIdleTimer();
    this.clearLiveViewStopTimer();

    const now = Date.now();
    this.turnActive = true;
    this.turnStartMs = now;
    this.lastActivityMs = now;
    this.params.status = 'running';
    this.params.badgeLabel = '思考中';
    this.params.stepCount = 0;
    this.params.elapsedSec = 0;
    this.params.appLabel = '';
    this.params.headline = '正在理解任务需求';
    this.params.subtext = '后台保活运行中 · 点击返回 Swai';
    this.nodeController.updateParams(this.params);

    if (this.inBackground || this.automationActive || this.pipActive) {
      this.startTicker();
      this.syncSurfaces(false);
    }
    this.syncAppStorage();
  }

  onAgentThinking(): void {
    if (!this.enabled || !this.turnActive || this.activeToolDepth > 0) {
      return;
    }
    this.lastActivityMs = Date.now();
    this.params.status = 'running';
    this.params.badgeLabel = '思考中';
    this.params.headline = this.params.stepCount > 0 ? '正在分析界面并规划下一步' : '正在规划执行步骤';
    this.params.subtext = '后台保活运行中 · 点击返回 Swai';
    this.nodeController.updateParams(this.params);
    if (this.inBackground || this.automationActive || this.pipActive) {
      this.syncSurfaces(false);
    }
    this.syncAppStorage();
  }

  onToolStart(toolName: string, argsJson: string): void {
    if (!this.enabled) {
      return;
    }
    this.clearDismissTimer();
    this.clearSafetyIdleTimer();
    this.clearLiveViewStopTimer();

    const now = Date.now();
    if (!this.turnActive || this.turnStartMs === 0 || now - this.lastActivityMs > 45000) {
      this.turnActive = true;
      this.turnStartMs = now;
      this.params.stepCount = 0;
      this.params.elapsedSec = 0;
      if (this.activeToolDepth === 0 && !this.automationActive) {
        this.params.appLabel = '';
      }
    }
    this.activeToolDepth += 1;
    this.lastActivityMs = now;

    const stepDesc = this.formatToolStep(toolName, argsJson);
    this.params.stepCount += 1;
    this.params.status = 'running';
    this.params.badgeLabel = '执行中';
    this.params.headline = stepDesc;
    this.params.subtext = '后台保活运行中 · 点击返回 Swai';
    this.nodeController.updateParams(this.params);

    if (this.inBackground || this.automationActive || this.pipActive) {
      this.setPipAutoStart(true);
      this.startTicker();
      this.syncSurfaces(false);
    }
    this.syncAppStorage();
  }

  onToolFinish(toolName: string, argsJson: string, isError: boolean): void {
    if (!this.enabled) {
      return;
    }
    if (this.activeToolDepth > 0) {
      this.activeToolDepth -= 1;
    }
    this.lastActivityMs = Date.now();
    if (isError && this.turnActive) {
      const baseDesc = this.formatToolStep(toolName, argsJson);
      this.params.status = 'running';
      this.params.badgeLabel = '重试中';
      this.params.headline = `${baseDesc} · 调整中`;
      this.nodeController.updateParams(this.params);
      if (this.inBackground || this.automationActive || this.pipActive) {
        this.syncSurfaces(false);
      }
    }
    this.scheduleSafetyIdleDone();
    this.syncAppStorage();
  }

  onTurnComplete(summary: string): void {
    if (!this.enabled) {
      return;
    }
    this.clearSafetyIdleTimer();
    this.stopTicker();
    this.turnActive = false;
    this.automationActive = false;
    this.activeToolDepth = 0;
    this.setPipAutoStart(false);

    if (this.turnStartMs > 0) {
      this.params.elapsedSec = Math.max(this.params.elapsedSec, Math.floor((Date.now() - this.turnStartMs) / 1000));
    }
    const cleanSummary = summary.trim();
    this.params.status = 'done';
    this.params.badgeLabel = '已完成';
    this.params.headline = cleanSummary.length > 0 ? `✓ ${cleanSummary}` : '✓ 任务已执行完成';
    this.nodeController.updateParams(this.params);

    const hasFloatingVisible = this.inBackground || this.pipActive || this.liveViewActive || this.notificationActive;
    if (!hasFloatingVisible) {
      this.stopAllSurfaces();
      this.syncAppStorage();
      return;
    }

    hilog.info(DOMAIN, TAG, 'ThinkingCapsule turn complete: %{public}s', this.params.headline);
    this.updateLiveViewSurface().then(() => {
      this.scheduleLiveViewStop(3000);
    });
    this.publishCompletionNotification(false, '');
    this.startAutoDismissCountdown(DONE_AUTO_DISMISS_SEC);
    this.syncAppStorage();
  }

  onTurnError(reason: string): void {
    if (!this.enabled) {
      return;
    }
    this.clearSafetyIdleTimer();
    this.stopTicker();
    this.turnActive = false;
    this.automationActive = false;
    this.activeToolDepth = 0;
    this.setPipAutoStart(false);

    const shortErr = reason.replace(/\s+/g, ' ').trim();
    const clipped = shortErr.length > 28 ? `${shortErr.slice(0, 28)}…` : shortErr;
    this.params.status = 'error';
    this.params.badgeLabel = '已中断';
    this.params.headline = clipped.length > 0 ? `执行中断: ${clipped}` : '任务执行已中断';
    this.nodeController.updateParams(this.params);

    const hasFloatingVisible = this.inBackground || this.pipActive || this.liveViewActive || this.notificationActive;
    if (!hasFloatingVisible) {
      this.stopAllSurfaces();
      this.syncAppStorage();
      return;
    }

    this.stopLiveViewSurface();
    this.publishCompletionNotification(true, clipped);
    this.startAutoDismissCountdown(ERROR_AUTO_DISMISS_SEC);
    this.syncAppStorage();
  }

  onTurnStopped(): void {
    this.onTurnError('已手动停止');
  }

  onAppForeground(): void {
    this.inBackground = false;
    this.clearDismissTimer();
    this.clearLiveViewStopTimer();
    this.setPipAutoStart(false);

    if (this.pipActive || this.pipStarting) {
      this.stopPiP();
    }
    if (!this.turnActive && this.activeToolDepth === 0) {
      this.automationActive = false;
      this.stopTicker();
      this.stopLiveViewSurface();
      this.cancelNotificationFallback();
    }
    this.syncAppStorage();
  }

  onAppBackground(): void {
    this.inBackground = true;
    if (!this.enabled) {
      return;
    }
    if (this.turnActive || this.automationActive || this.activeToolDepth > 0) {
      if (this.params.status !== 'running') {
        this.params.status = 'running';
        this.params.badgeLabel = '执行中';
      }
      if (this.params.headline.length === 0) {
        this.params.headline = '后台继续执行任务';
      }
      this.params.subtext = '后台保活运行中 · 点击返回 Swai';
      this.nodeController.updateParams(this.params);
      this.setPipAutoStart(true);
      this.startTicker();
      this.syncSurfaces(true);
    }
    this.syncAppStorage();
  }

  async destroy(): Promise<void> {
    this.clearAllTimers();
    this.turnActive = false;
    this.automationActive = false;
    this.activeToolDepth = 0;
    await this.stopAllSurfaces();
    if (this.pipController) {
      try {
        this.pipController.off('stateChange');
      } catch (_err) {
        // ignore
      }
      this.pipController = null;
    }
    this.xComponentNode = null;
    this.uiContext = null;
    this.syncAppStorage();
  }

  private async ensurePipController(): Promise<void> {
    if (!this.enabled || !this.context || !this.uiContext) {
      return;
    }
    if (this.pipController !== null || this.pipCreating) {
      return;
    }
    let pipEnabled = false;
    try {
      pipEnabled = PiPWindow.isPiPEnabled();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'PiPWindow.isPiPEnabled failed: %{public}s', JSON.stringify(err));
      return;
    }
    if (!pipEnabled) {
      hilog.info(DOMAIN, TAG, 'PiPWindow is not enabled on this device');
      return;
    }

    this.pipCreating = true;
    try {
      if (this.xComponentNode === null) {
        this.xComponentNode = typeNode.createNode(this.uiContext, 'XComponent', {
          type: XComponentType.SURFACE,
          controller: this.xComponentController
        });
      }
      const config: PiPWindow.PiPConfiguration = {
        context: this.context,
        componentController: this.xComponentController,
        templateType: PiPWindow.PiPTemplateType.VIDEO_LIVE,
        contentWidth: 440,
        contentHeight: 168,
        defaultWindowSizeType: 1,
        cornerAdsorptionEnabled: true,
        controlGroups: [],
        customUIController: this.nodeController
      };
      const controller = await PiPWindow.create(config, this.xComponentNode);
      this.pipController = controller;
      this.setPipAutoStart(this.turnActive || this.automationActive || this.activeToolDepth > 0);
      controller.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
        hilog.info(DOMAIN, TAG, 'PiP stateChange=%{public}d reason=%{public}s', state, reason);
        if (state === PiPWindow.PiPState.ABOUT_TO_START) {
          this.pipStarting = true;
        } else if (state === PiPWindow.PiPState.STARTED) {
          this.pipStarting = false;
          this.pipActive = true;
        } else if (
          state === PiPWindow.PiPState.STOPPED ||
          state === PiPWindow.PiPState.ABOUT_TO_STOP ||
          state === PiPWindow.PiPState.ERROR
        ) {
          this.pipStarting = false;
          this.pipActive = false;
          if (state === PiPWindow.PiPState.STOPPED && !this.temporarilyHidden) {
            this.observedOverlayRects = [];
            this.clearDismissTimer();
            this.stopTicker();
          }
        }
        this.syncAppStorage();
      });
      hilog.info(DOMAIN, TAG, 'PiP thinking capsule controller ready');
    } catch (err) {
      const bErr = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'Failed to create PiP capsule controller: code=%{public}d msg=%{public}s',
        bErr.code ?? -1, bErr.message ?? JSON.stringify(err));
    } finally {
      this.pipCreating = false;
      this.syncAppStorage();
    }
  }

  private setPipAutoStart(flag: boolean): void {
    if (!this.pipController) {
      return;
    }
    try {
      this.pipController.setAutoStartEnabled(flag);
    } catch (_err) {
      // ignore
    }
  }

  private ensurePiPStarted(): void {
    if (!this.enabled || !this.pipController || this.pipActive || this.pipStarting) {
      return;
    }
    this.pipStarting = true;
    this.pipController.startPiP().then(() => {
      this.pipStarting = false;
      this.pipActive = true;
      hilog.info(DOMAIN, TAG, 'PiP thinking capsule started');
      this.syncAppStorage();
    }).catch((err: BusinessError) => {
      this.pipStarting = false;
      if (err.code === 1300013) {
        this.pipActive = true;
        this.syncAppStorage();
        return;
      }
      hilog.warn(DOMAIN, TAG, 'startPiP deferred/failed: code=%{public}d msg=%{public}s',
        err.code ?? -1, err.message ?? '');
    });
  }

  private stopPiP(): void {
    this.pipStarting = false;
    if (!this.pipController) {
      this.pipActive = false;
      return;
    }
    this.pipController.stopPiP().then(() => {
      this.pipActive = false;
      this.syncAppStorage();
    }).catch((_err: BusinessError) => {
      this.pipActive = false;
      this.syncAppStorage();
    });
  }

  private async syncSurfaces(forceImmediate: boolean): Promise<void> {
    if (!this.enabled || !this.context) {
      return;
    }
    if ((this.inBackground || this.automationActive) && this.params.status === 'running') {
      await this.ensurePipController();
      this.ensurePiPStarted();
    }

    const liveOk = await this.updateLiveViewSurface();
    if (!liveOk || !this.pipActive) {
      await this.publishNotificationFallback(forceImmediate);
    }
    this.syncAppStorage();
  }

  private async stopAllSurfaces(): Promise<void> {
    this.setPipAutoStart(false);
    this.stopPiP();
    await this.stopLiveViewSurface();
    await this.cancelNotificationFallback();
    this.syncAppStorage();
  }

  private async updateLiveViewSurface(): Promise<boolean> {
    if (!this.context || this.liveViewSupported === false) {
      return false;
    }
    try {
      if (this.liveViewSupported === null) {
        this.liveViewSupported = await liveViewManager.isLiveViewEnabled();
        hilog.info(DOMAIN, TAG, 'LiveViewKit isLiveViewEnabled=%{public}s', String(this.liveViewSupported));
        if (!this.liveViewSupported) {
          return false;
        }
      }
      const view = await this.buildLiveViewPayload();
      if (!this.liveViewActive) {
        await liveViewManager.startLiveView(view);
        this.liveViewActive = true;
      } else {
        await liveViewManager.updateLiveView(view);
      }
      return true;
    } catch (err) {
      const bErr = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'LiveView surface unavailable, falling back: code=%{public}d msg=%{public}s',
        bErr.code ?? -1, bErr.message ?? '');
      this.liveViewSupported = false;
      this.liveViewActive = false;
      return false;
    }
  }

  private async stopLiveViewSurface(): Promise<void> {
    this.clearLiveViewStopTimer();
    if (!this.liveViewActive || !this.context) {
      this.liveViewActive = false;
      return;
    }
    try {
      const view = await this.buildLiveViewPayload();
      view.liveViewData.primary.keepTime = 1;
      await liveViewManager.stopLiveView(view);
    } catch (_err) {
      // ignore
    } finally {
      this.liveViewActive = false;
    }
  }

  private async buildLiveViewPayload(): Promise<liveViewManager.LiveView> {
    this.liveViewSequence += 1;
    const isDone = this.params.status === 'done';
    const isError = this.params.status === 'error';
    const titlePrefix = isDone ? 'Swai 任务已完成' : (isError ? 'Swai 任务已中断' : 'Swai 思考胶囊');
    const title = this.params.appLabel.length > 0 ? `${titlePrefix} · ${this.params.appLabel}` : titlePrefix;
    const shortCapsule = isDone
      ? '已完成'
      : (this.params.stepCount > 0 ? `步骤${this.params.stepCount}` : this.params.badgeLabel);
    const clickAction = await this.buildReturnWantAgent();
    const layoutData: liveViewManager.ProgressLayout = {
      layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PROGRESS,
      progress: isDone ? 100 : Math.min(95, Math.max(12, this.params.stepCount * 15)),
      color: isDone ? '#FF10B981' : (isError ? '#FFEF4444' : '#FF38BDF8'),
      backgroundColor: '#33FFFFFF',
      indicatorType: liveViewManager.IndicatorType.INDICATOR_TYPE_UNDISPLAYED,
      lineType: liveViewManager.LineType.LINE_TYPE_NORMAL_SOLID_LINE
    };
    const view: liveViewManager.LiveView = {
      id: LIVE_VIEW_ID,
      event: 'QUEUE',
      sequence: this.liveViewSequence,
      isMute: true,
      liveViewData: {
        primary: {
          title: title,
          content: [{ text: this.params.headline }],
          keepTime: isDone ? 4 : 10,
          clickAction: clickAction,
          layoutData: layoutData
        },
        capsule: {
          type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
          status: 1,
          backgroundColor: isDone ? '#FF065F46' : (isError ? '#FF7F1D1D' : '#FF0F172A'),
          title: shortCapsule,
          content: this.params.headline
        }
      }
    };
    return view;
  }

  private async publishNotificationFallback(forceImmediate: boolean): Promise<void> {
    if (!this.context) {
      return;
    }
    const now = Date.now();
    if (!forceImmediate && this.notificationActive && now - this.lastNotifyMs < 700) {
      return;
    }
    this.lastNotifyMs = now;
    try {
      const returnAgent = await this.buildReturnWantAgent();
      const titlePrefix = this.params.stepCount > 0
        ? `Swai ${this.params.badgeLabel} (#${this.params.stepCount})`
        : `Swai ${this.params.badgeLabel}`;
      const title = this.params.appLabel.length > 0 ? `${titlePrefix} · ${this.params.appLabel}` : titlePrefix;

      const request: notificationManager.NotificationRequest = {
        id: NOTIFICATION_ID,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        isOngoing: true,
        isAlertOnce: true,
        tapDismissed: false,
        wantAgent: returnAgent,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: this.params.headline,
            additionalText: '点击返回 Swai'
          }
        }
      };
      await notificationManager.publish(request);
      this.notificationActive = true;
    } catch (err) {
      const bErr = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'publishNotificationFallback failed: code=%{public}d', bErr.code ?? -1);
    }
  }

  private async publishCompletionNotification(isError: boolean, errDetail: string): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const returnAgent = await this.buildReturnWantAgent();
      const title = isError
        ? 'Swai 任务已中断'
        : (this.params.appLabel.length > 0 ? `Swai 已完成 · ${this.params.appLabel}` : 'Swai 任务已完成');
      const body = isError
        ? (errDetail.length > 0 ? errDetail : this.params.headline)
        : this.params.headline;
      const request: notificationManager.NotificationRequest = {
        id: NOTIFICATION_ID,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        isOngoing: false,
        isAlertOnce: false,
        tapDismissed: true,
        wantAgent: returnAgent,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: body,
            additionalText: '点击返回 Swai 查看结果'
          }
        }
      };
      await notificationManager.publish(request);
      this.notificationActive = true;
    } catch (_err) {
      // ignore
    }
  }

  private async cancelNotificationFallback(): Promise<void> {
    if (!this.notificationActive) {
      return;
    }
    this.notificationActive = false;
    try {
      await notificationManager.cancel(NOTIFICATION_ID);
    } catch (_err) {
      // ignore
    }
  }

  private async buildReturnWantAgent(): Promise<WantAgent> {
    const bundleName = this.context ? this.context.applicationInfo.name : 'com.shuwei.shellbridge';
    const wantInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: bundleName,
          abilityName: 'EntryAbility'
        } as Want
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: NOTIFICATION_ID,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(wantInfo);
  }

  private startTicker(): void {
    if (this.tickerTimer !== -1) {
      return;
    }
    this.tickerTimer = setInterval(() => {
      if (!this.turnActive || !this.enabled) {
        this.stopTicker();
        return;
      }
      this.params.animTick = (this.params.animTick + 1) % 3;
      if (this.turnStartMs > 0) {
        this.params.elapsedSec = Math.max(0, Math.floor((Date.now() - this.turnStartMs) / 1000));
      }
      this.nodeController.updateParams(this.params);
    }, 1000);
  }

  private stopTicker(): void {
    if (this.tickerTimer !== -1) {
      clearInterval(this.tickerTimer);
      this.tickerTimer = -1;
    }
  }

  private startAutoDismissCountdown(seconds: number): void {
    this.clearDismissTimer();
    this.dismissCountdownSec = Math.max(1, seconds);
    const updateCaption = (): void => {
      this.params.subtext = this.params.status === 'done'
        ? `点击返回 Swai · ${this.dismissCountdownSec}s 后自动收起`
        : `点击返回处理 · ${this.dismissCountdownSec}s 后自动收起`;
      this.nodeController.updateParams(this.params);
    };
    updateCaption();

    this.dismissTimer = setInterval(() => {
      this.dismissCountdownSec -= 1;
      if (this.dismissCountdownSec <= 0) {
        this.clearDismissTimer();
        this.stopPiP();
        this.stopLiveViewSurface();
        this.syncAppStorage();
        return;
      }
      updateCaption();
    }, 1000);
  }

  private clearDismissTimer(): void {
    if (this.dismissTimer !== -1) {
      clearInterval(this.dismissTimer);
      this.dismissTimer = -1;
    }
  }

  private scheduleSafetyIdleDone(): void {
    this.clearSafetyIdleTimer();
    this.safetyIdleTimer = setTimeout(() => {
      this.safetyIdleTimer = -1;
      if (this.turnActive && this.activeToolDepth === 0) {
        this.onTurnComplete('');
      }
    }, SAFETY_IDLE_TIMEOUT_MS);
  }

  private clearSafetyIdleTimer(): void {
    if (this.safetyIdleTimer !== -1) {
      clearTimeout(this.safetyIdleTimer);
      this.safetyIdleTimer = -1;
    }
  }

  private scheduleLiveViewStop(delayMs: number): void {
    this.clearLiveViewStopTimer();
    this.liveViewStopTimer = setTimeout(() => {
      this.liveViewStopTimer = -1;
      this.stopLiveViewSurface();
    }, delayMs);
  }

  private clearLiveViewStopTimer(): void {
    if (this.liveViewStopTimer !== -1) {
      clearTimeout(this.liveViewStopTimer);
      this.liveViewStopTimer = -1;
    }
  }

  private clearAllTimers(): void {
    this.stopTicker();
    this.clearDismissTimer();
    this.clearSafetyIdleTimer();
    this.clearLiveViewStopTimer();
  }

  private resolveAppLabel(bundleOrApp: string): string {
    const trimmed = bundleOrApp.trim();
    if (trimmed.length === 0) {
      return '';
    }
    const profile = AppKnowledgeBase.findProfile(trimmed);
    if (profile) {
      return profile.displayName;
    }
    if (trimmed.startsWith('com.')) {
      const parts = trimmed.split('.');
      return parts[parts.length - 1] || trimmed;
    }
    return trimmed;
  }

  private formatToolStep(toolName: string, argsJson: string): string {
    let args: Record<string, Object> = {};
    try {
      if (argsJson && argsJson.trim().length > 0) {
        args = JSON.parse(argsJson) as Record<string, Object>;
      }
    } catch (_err) {
      args = {};
    }

    if (toolName === 'ui') {
      const action = typeof args['action'] === 'string' ? (args['action'] as string) : '';
      if (action === 'launch_app') {
        const rawTarget = (typeof args['app_name'] === 'string' && (args['app_name'] as string).length > 0)
          ? (args['app_name'] as string)
          : (typeof args['bundle_name'] === 'string' ? (args['bundle_name'] as string) : '');
        const appLabel = this.resolveAppLabel(rawTarget);
        if (appLabel.length > 0) {
          this.params.appLabel = appLabel;
          return `正在打开 ${appLabel}`;
        }
        return '正在打开目标应用';
      }
      if (action === 'dump_tree') {
        return '正在识别当前界面元素';
      }
      if (action === 'click' || action === 'click_node' || action === 'double_click' || action === 'long_click') {
        const label = this.pickNodeLabel(args);
        if (label.length > 0) {
          return `正在点击「${label}」`;
        }
        return '正在点击屏幕目标';
      }
      if (action === 'input_text') {
        // Strict privacy rule: never expose raw text argument in capsule or notification
        return '正在向输入框写入内容';
      }
      if (action === 'swipe' || action === 'scroll') {
        return '正在滑动浏览页面';
      }
      if (action === 'back' || action === 'press_back') {
        return '正在返回上一页';
      }
      if (action === 'home') {
        return '正在回到桌面';
      }
      if (action === 'wait') {
        return '等待页面加载响应...';
      }
      if (action === 'list_apps') {
        return '正在检索已安装应用';
      }
      if (action === 'run_sequence') {
        return '正在执行连贯界面操作';
      }
      return action.length > 0 ? `正在执行界面操作: ${action}` : '正在执行界面操作';
    }

    if (toolName === 'capture_screen') {
      return '正在截取并识别屏幕画面';
    }
    if (toolName === 'skill_read' || toolName === 'skill_save' || toolName === 'ui_skill_save') {
      return '正在查阅/保存应用操作经验';
    }
    if (toolName === 'run_command' || toolName === 'shell' || toolName === 'exec') {
      return '正在执行辅助终端指令';
    }
    return `正在执行 ${toolName}`;
  }

  private pickNodeLabel(args: Record<string, Object>): string {
    const keys = ['text', 'hint', 'description', 'key'];
    for (let i = 0; i < keys.length; i++) {
      const val = args[keys[i]];
      if (typeof val === 'string' && val.trim().length > 0) {
        const s = val.trim();
        return s.length > 16 ? s.slice(0, 16) + '…' : s;
      }
    }
    return '';
  }

  private computeSurfaceLabel(): string {
    if (!this.enabled) {
      return '已关闭';
    }
    if (this.liveViewActive) {
      return '实况胶囊';
    }
    if (this.pipActive) {
      return '画中画胶囊';
    }
    if (this.notificationActive) {
      return '进度通知';
    }
    if (this.pipController !== null) {
      return '待命就绪';
    }
    return '通知兜底';
  }

  private syncAppStorage(): void {
    AppStorage.setOrCreate('thinkingCapsuleEnabled', this.enabled);
    AppStorage.setOrCreate('thinkingCapsuleSurface', this.computeSurfaceLabel());
    AppStorage.setOrCreate('thinkingCapsuleStep', this.params.headline);
  }
}
