/*
 * BrowserFloatingPip: Autonomous Picture-in-Picture Floating Window.
 * Inspired by Mika's AgentPip & PipPhysics architecture.
 *
 * Features:
 * 1. 1:1 real-time finger-following drag via PanGesture.
 * 2. Inertial snap-to-edge animation (left/right margin avoidance).
 * 3. Seamless transition between Mini monitoring mode and Expanded interactive mode.
 * 4. Glowing border states: Running (#22c55e) and Attention breathing (#f59e0b).
 * 5. Persistent ArkWeb viewport with CDP 9222 connectivity.
 * 6. Quick Close (×) button and smooth fade dismissal.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

import display from '@ohos.display';
import promptAction from '@ohos.promptAction';
import { BrowserManager } from './BrowserManager';
import { BrowserPipState, PipMode, PipGlowStatus } from './BrowserPipState';
import { BrowserView } from './BrowserView';

@Component
export struct BrowserFloatingPip {
  @State private pipMode: PipMode = PipMode.HIDDEN;
  @State private glowStatus: PipGlowStatus = PipGlowStatus.NORMAL;

  // Window coordinates (in vp)
  @State private posX: number = 210;
  @State private posY: number = 440;
  @State private isDragging: boolean = false;
  @State private attentionAlpha: number = 0.4;

  // Screen metrics
  private screenWidthVp: number = 380;
  private screenHeightVp: number = 800;

  private pipState: BrowserPipState = BrowserPipState.getInstance();
  private browserManager: BrowserManager = BrowserManager.getInstance();
  private unsubscribe?: () => void = undefined;
  private attentionTimer: number = -1;

  aboutToAppear(): void {
    this.updateScreenDimensions();
    this.syncState();

    this.unsubscribe = this.pipState.subscribe(() => {
      this.syncState();
    });

    // Default position: Bottom-Right above input bar
    this.snapToEdge(this.screenWidthVp - 146, this.screenHeightVp - 330);
  }

  aboutToDisappear(): void {
    if (this.unsubscribe) {
      this.unsubscribe();
    }
    if (this.attentionTimer !== -1) {
      clearInterval(this.attentionTimer);
      this.attentionTimer = -1;
    }
  }

  private updateScreenDimensions(): void {
    try {
      const disp = display.getDefaultDisplaySync();
      const density = disp.densityPixels || 3.0;
      this.screenWidthVp = Math.floor(disp.width / density);
      this.screenHeightVp = Math.floor(disp.height / density);
    } catch (_e) {
      this.screenWidthVp = 380;
      this.screenHeightVp = 800;
    }
  }

  private syncState(): void {
    this.pipMode = this.pipState.mode;
    this.glowStatus = this.pipState.glowStatus;

    if (this.glowStatus === PipGlowStatus.ATTENTION) {
      this.startBreathingGlow();
    } else {
      if (this.attentionTimer !== -1) {
        clearInterval(this.attentionTimer);
        this.attentionTimer = -1;
      }
      this.attentionAlpha = 1.0;
    }
  }

  private startBreathingGlow(): void {
    if (this.attentionTimer !== -1) return;
    let fading = true;
    this.attentionTimer = setInterval(() => {
      animateTo({ duration: 600, curve: Curve.EaseInOut }, () => {
        this.attentionAlpha = fading ? 0.35 : 1.0;
      });
      fading = !fading;
    }, 650);
  }

  private getWindowWidth(): number {
    return this.pipMode === PipMode.EXPANDED ? Math.min(350, this.screenWidthVp - 24) : 136;
  }

  private getWindowHeight(): number {
    return this.pipMode === PipMode.EXPANDED ? Math.min(540, this.screenHeightVp - 140) : 230;
  }

  private snapToEdge(targetX: number, targetY: number): void {
    const width = this.getWindowWidth();
    const height = this.getWindowHeight();

    const minX = 12;
    const maxX = Math.max(minX, this.screenWidthVp - width - 12);
    const minY = 64; // Below status/top bar
    const maxY = Math.max(minY, this.screenHeightVp - height - 76); // Above navigation/input bar

    // Horizontal edge snapping: nearest left or right edge
    let finalX: number;
    if (this.pipMode === PipMode.EXPANDED) {
      // Expanded mode centers horizontally if close to center
      finalX = Math.max(minX, Math.min(maxX, Math.floor((this.screenWidthVp - width) / 2)));
    } else {
      const centerX = targetX + width / 2;
      finalX = centerX < this.screenWidthVp / 2 ? minX : maxX;
    }

    const finalY = Math.max(minY, Math.min(maxY, targetY));

    animateTo({ duration: 320, curve: Curve.FastOutSlowIn }, () => {
      this.posX = finalX;
      this.posY = finalY;
    });
  }

  private getBorderColor(): string {
    switch (this.glowStatus) {
      case PipGlowStatus.RUNNING:
        return '#22c55e'; // Green running glow
      case PipGlowStatus.ATTENTION:
        return '#f59e0b'; // Amber attention glow
      default:
        return this.pipMode === PipMode.EXPANDED ? '#0284c7' : '#94a3b8';
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // 1. Pip Header (Drag Handle & Controls)
        Row() {
          // Drag indicator and page icon
          Row({ space: 5 }) {
            Text('⋮⋮')
              .fontSize(11)
              .fontColor('#94a3b8')
              .fontWeight(FontWeight.Bold)

            Text('🌐')
              .fontSize(12)

            Text(this.browserManager.currentTitle || '网页视口')
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor('#0f172a')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            // Running / Attention indicator dot
            Circle({ width: 7, height: 7 })
              .fill(this.glowStatus === PipGlowStatus.RUNNING ? '#22c55e' :
                    this.glowStatus === PipGlowStatus.ATTENTION ? '#f59e0b' : '#38bdf8')
              .opacity(this.attentionAlpha)
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)

          // Mode Toggle (Mini <-> Expanded)
          Button({ type: ButtonType.Circle }) {
            Text(this.pipMode === PipMode.EXPANDED ? '—' : '⤢')
              .fontSize(12)
              .fontColor('#475569')
              .fontWeight(FontWeight.Bold)
          }
          .width(22)
          .height(22)
          .backgroundColor('#f1f5f9')
          .margin({ right: 6 })
          .onClick(() => {
            if (this.pipMode === PipMode.EXPANDED) {
              this.pipState.showMini();
              this.snapToEdge(this.posX, this.posY);
            } else {
              this.pipState.showExpanded();
              this.snapToEdge(this.posX, this.posY);
            }
          })

          // Close Button (×)
          Button({ type: ButtonType.Circle }) {
            Text('×')
              .fontSize(14)
              .fontColor('#64748b')
              .fontWeight(FontWeight.Bold)
          }
          .width(22)
          .height(22)
          .backgroundColor('#f1f5f9')
          .onClick(() => {
            this.pipState.hide();
            promptAction.showToast({ message: '浮窗已收起，可在侧栏「浏览器」再次查看', duration: 1500 });
          })
        }
        .width('100%')
        .height(34)
        .padding({ left: 8, right: 8 })
        .backgroundColor('#ffffff')
        .border({ width: { bottom: 1 }, color: '#f1f5f9' })
        .alignItems(VerticalAlign.Center)
        .gesture(
          PanGesture({ fingers: 1, direction: PanDirection.All })
            .onActionStart(() => {
              this.isDragging = true;
            })
            .onActionUpdate((event?: GestureEvent) => {
              if (event) {
                this.posX += event.offsetX;
                this.posY += event.offsetY;
              }
            })
            .onActionEnd(() => {
              this.isDragging = false;
              this.snapToEdge(this.posX, this.posY);
            })
        )

        // 2. Viewport Content (Always mounted to preserve Webview & CDP 9222)
        Stack({ alignContent: Alignment.Bottom }) {
          BrowserView({
            onHide: () => {
              this.pipState.hide();
            }
          })
          .layoutWeight(1)
          .width('100%')

          if (this.pipMode === PipMode.MINI) {
            Row() {
              Text('轻触放大 ⤢')
                .fontSize(10)
                .fontColor('#ffffff')
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')
            .height(24)
            .backgroundColor('rgba(15, 23, 42, 0.65)')
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.pipState.showExpanded();
              this.snapToEdge(this.posX, this.posY);
            })
          }
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width(this.getWindowWidth())
      .height(this.getWindowHeight())
      .backgroundColor('#ffffff')
      .borderRadius(14)
      .border({
        width: this.glowStatus !== PipGlowStatus.NORMAL ? 2.5 : 1.5,
        color: this.getBorderColor()
      })
      .shadow({
        radius: this.glowStatus === PipGlowStatus.ATTENTION ? 20 : 12,
        color: this.glowStatus === PipGlowStatus.ATTENTION ? 'rgba(245, 158, 11, 0.35)' :
               this.glowStatus === PipGlowStatus.RUNNING ? 'rgba(34, 197, 94, 0.3)' : 'rgba(0, 0, 0, 0.16)',
        offsetX: 0,
        offsetY: 4
      })
      .clip(true)
      .position({
        x: this.pipMode !== PipMode.HIDDEN ? this.posX : -4000,
        y: this.pipMode !== PipMode.HIDDEN ? this.posY : -4000
      })
      .opacity(this.pipMode !== PipMode.HIDDEN ? 1 : 0.001)
      .hitTestBehavior(this.pipMode !== PipMode.HIDDEN ? HitTestMode.Default : HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(this.pipMode !== PipMode.HIDDEN ? HitTestMode.Transparent : HitTestMode.None)
  }
}
