/*
 * FloatPanel: The interactive UI loaded inside the native TYPE_FLOAT window.
 * Floats above any HarmonyOS application (WeChat, Browser, Settings, Launcher)
 * showing live DeepSeek Harness (DSH) thought stream, tool execution, and controls.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import promptAction from '@ohos.promptAction';
import hilog from '@ohos.hilog';
import { FloatWindowManager } from '../window/FloatWindowManager';
import { AgentSession } from '../agent/AgentSession';
import { DshAgentManager } from '../agent/dsh/DshAgentManager';

@Entry
@Component
struct FloatPanel {
  @StorageProp('agentIsRunning') isRunning: boolean = false;
  @StorageProp('agentStatusText') statusText: string = '待命';
  @StorageProp('agentThinkingText') thinkingText: string = '';
  @StorageProp('agentCurrentTool') currentTool: string = '';
  @StorageProp('agentLatestPrompt') latestPrompt: string = '';
  @StorageProp('floatWindowCompact') isCompact: boolean = false;

  private lastTouchScreenX: number = 0;
  private lastTouchScreenY: number = 0;
  private thoughtScroller: Scroller = new Scroller();

  build() {
    Column() {
      if (this.isCompact) {
        this.buildPillBar()
      } else {
        this.buildExpandedPanel()
      }
    }
    .width('100%')
    .height('100%')
  }

  // Ultra-compact Pill Capsule Mode
  @Builder
  buildPillBar() {
    Row() {
      // Drag Grip & Status Icon
      Row({ space: 4 }) {
        Text('⋮')
          .fontSize(12)
          .fontColor('#94a3b8')
          .fontWeight(FontWeight.Bold)

        Circle({ width: 8, height: 8 })
          .fill(this.isRunning ? '#22c55e' : '#38bdf8')
      }
      .alignItems(VerticalAlign.Center)

      // Live Status Summary
      Text(this.getPillSummaryText())
        .fontSize(11)
        .fontColor('#f8fafc')
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 6, right: 6 })

      // Expand to Full Window
      Button({ type: ButtonType.Circle }) {
        Text('⤢')
          .fontSize(11)
          .fontColor('#94a3b8')
      }
      .width(26)
      .height(26)
      .backgroundColor('#33415580')
      .onClick(() => {
        FloatWindowManager.getInstance().setCompactMode(false);
      })

      // Jump back to Main App
      Button({ type: ButtonType.Normal }) {
        Text('回应用')
          .fontSize(10)
          .fontColor('#38bdf8')
      }
      .height(24)
      .backgroundColor('#0284c733')
      .borderRadius(12)
      .margin({ left: 4 })
      .padding({ left: 6, right: 6 })
      .onClick(() => {
        FloatWindowManager.getInstance().bringAppToForeground();
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 10, right: 10 })
    .backgroundColor('#0f172ae6')
    .borderRadius(27)
    .border({
      width: 1.5,
      color: this.isRunning ? '#22c55e' : '#38bdf8'
    })
    .shadow({ radius: 12, color: '#66000000', offsetX: 0, offsetY: 4 })
    .onTouch((event: TouchEvent) => {
      this.handleWindowDrag(event);
    })
  }

  // Expanded Console View
  @Builder
  buildExpandedPanel() {
    Column() {
      // Header & Drag Area
      Row() {
        Row({ space: 6 }) {
          Text('⋮⋮')
            .fontSize(14)
            .fontColor('#94a3b8')
            .fontWeight(FontWeight.Bold)

          Text('🤖 DeepSeek Harness')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#ffffff')

          // Status Badge
          Row({ space: 4 }) {
            Circle({ width: 6, height: 6 })
              .fill(this.isRunning ? '#22c55e' : '#94a3b8')
            Text(this.isRunning ? '执行中' : '就绪')
              .fontSize(9)
              .fontColor(this.isRunning ? '#86efac' : '#cbd5e1')
          }
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .backgroundColor(this.isRunning ? '#14532d80' : '#33415580')
          .borderRadius(8)
        }
        .alignItems(VerticalAlign.Center)
        .layoutWeight(1)

        // Window Controls
        Row({ space: 6 }) {
          Button({ type: ButtonType.Circle }) {
            Text('—')
              .fontSize(12)
              .fontColor('#cbd5e1')
              .fontWeight(FontWeight.Bold)
          }
          .width(26)
          .height(26)
          .backgroundColor('#334155')
          .onClick(() => {
            FloatWindowManager.getInstance().setCompactMode(true);
          })

          Button({ type: ButtonType.Circle }) {
            Text('⇱')
              .fontSize(11)
              .fontColor('#cbd5e1')
          }
          .width(26)
          .height(26)
          .backgroundColor('#334155')
          .onClick(() => {
            FloatWindowManager.getInstance().bringAppToForeground();
          })

          Button({ type: ButtonType.Circle }) {
            Text('✕')
              .fontSize(12)
              .fontColor('#f87171')
          }
          .width(26)
          .height(26)
          .backgroundColor('#450a0a80')
          .onClick(() => {
            FloatWindowManager.getInstance().hideFloatWindow();
          })
        }
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor('#1e293b')
      .onTouch((event: TouchEvent) => {
        this.handleWindowDrag(event);
      })

      // Main Content Scroll Area
      Scroll(this.thoughtScroller) {
        Column({ space: 8 }) {
          // Current Active Prompt Card
          if (this.latestPrompt) {
            Column({ space: 4 }) {
              Row({ space: 4 }) {
                Text('🎯')
                  .fontSize(11)
                Text('目标指令')
                  .fontSize(10)
                  .fontColor('#94a3b8')
                  .fontWeight(FontWeight.Medium)
              }
              Text(this.latestPrompt)
                .fontSize(11)
                .fontColor('#e2e8f0')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding(8)
            .backgroundColor('#1e293b80')
            .borderRadius(8)
            .border({ width: 1, color: '#334155' })
          }

          // Active Tool Status Banner
          if (this.currentTool) {
            Row({ space: 6 }) {
              LoadingProgress()
                .width(14)
                .height(14)
                .color('#38bdf8')

              Text(this.currentTool)
                .fontSize(11)
                .fontColor('#38bdf8')
                .fontWeight(FontWeight.Medium)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .backgroundColor('#0369a133')
            .borderRadius(6)
            .border({ width: 1, color: '#0284c766' })
          }

          // Reasoning Stream (Thinking)
          if (this.thinkingText) {
            Column({ space: 4 }) {
              Row({ space: 4 }) {
                Text('💭')
                  .fontSize(11)
                Text('深度思考 (DSH Reasoning)')
                  .fontSize(10)
                  .fontColor('#38bdf8')
                  .fontWeight(FontWeight.Medium)
                Blank()
                Text(`${this.thinkingText.length} 字`)
                  .fontSize(9)
                  .fontColor('#64748b')
              }
              .width('100%')

              Text(this.thinkingText)
                .fontSize(11)
                .fontColor('#cbd5e1')
                .lineHeight(16)
            }
            .width('100%')
            .padding(8)
            .backgroundColor('#0f172a99')
            .borderRadius(8)
            .border({ width: 1, color: '#1e293b' })
          } else if (!this.currentTool && !this.isRunning) {
            Column({ space: 4 }) {
              Text('待命中')
                .fontSize(12)
                .fontColor('#64748b')
              Text('切回主界面发送指令，或在后台执行自动化任务。')
                .fontSize(10)
                .fontColor('#475569')
            }
            .width('100%')
            .padding(16)
            .alignItems(HorizontalAlign.Center)
          }
        }
        .width('100%')
        .padding(8)
      }
      .layoutWeight(1)
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)

      // Bottom Action Bar
      Row({ space: 6 }) {
        if (this.isRunning) {
          Button('⏹ 停止任务')
            .fontSize(11)
            .height(28)
            .backgroundColor('#dc2626')
            .fontColor('#ffffff')
            .layoutWeight(1)
            .onClick(() => {
              this.stopAgentTask();
            })
        }

        Button('打开主控制台')
          .fontSize(11)
          .height(28)
          .backgroundColor('#2563eb')
          .fontColor('#ffffff')
          .layoutWeight(1)
          .onClick(() => {
            FloatWindowManager.getInstance().bringAppToForeground();
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .backgroundColor('#1e293b')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0f172af0')
    .borderRadius(14)
    .border({ width: 1, color: '#334155' })
    .clip(true)
    .shadow({ radius: 16, color: '#88000000', offsetX: 0, offsetY: 6 })
  }

  private getPillSummaryText(): string {
    if (this.isRunning) {
      if (this.currentTool) {
        return this.currentTool;
      }
      return 'DSH 思考中...';
    }
    return this.statusText || '待命';
  }

  private handleWindowDrag(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      if (event.touches.length > 0) {
        this.lastTouchScreenX = event.touches[0].screenX;
        this.lastTouchScreenY = event.touches[0].screenY;
      }
    } else if (event.type === TouchType.Move) {
      if (event.touches.length > 0) {
        const curX = event.touches[0].screenX;
        const curY = event.touches[0].screenY;
        const dx = curX - this.lastTouchScreenX;
        const dy = curY - this.lastTouchScreenY;
        this.lastTouchScreenX = curX;
        this.lastTouchScreenY = curY;
        FloatWindowManager.getInstance().moveWindowBy(dx, dy);
      }
    }
  }

  private stopAgentTask(): void {
    try {
      DshAgentManager.getInstance().interrupt();
      const session = AppStorage.get<AgentSession>('agentSession');
      if (session) {
        session.abort();
      }
      promptAction.showToast({ message: '已请求停止 DeepSeek Harness 任务', duration: 1500 });
    } catch (err) {
      hilog.warn(0x3201, 'FloatPanel', 'Failed to stop session: %{public}s', JSON.stringify(err));
    }
  }
}
