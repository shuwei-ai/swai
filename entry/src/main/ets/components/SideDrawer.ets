/*
 * SideDrawer: HarmonyOS NEXT Native Navigation Drawer (ClashBox Inspired).
 * Uses grey-surface + white-card grouping, native SymbolGlyph icons,
 * system semantic colors, and native bindMenu/Toggle controls.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

import hilog from '@ohos.hilog';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { BackgroundKeepAliveManager, KeepAliveMode } from '../service/BackgroundKeepAliveManager';
import { ThinkingCapsuleManager } from '../window/ThinkingCapsuleManager';
import {
  DebugPhaseUiCopy,
  getDebugPhaseSummary,
  HdcDebugPhase
} from '../common/HdcDebugState';

@Component
struct SideDrawerNavRow {
  @Prop symbolIcon: Resource = $r('sys.symbol.house_fill');
  @Prop label: string = '';
  @Prop isSelected: boolean = false;
  onClickItem?: () => void = undefined;

  build() {
    Row({ space: 12 }) {
      SymbolGlyph(this.symbolIcon)
        .fontSize(20)
        .fontColor([this.isSelected ? $r('sys.color.icon_emphasize') : $r('sys.color.icon_secondary')])
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)

      Text(this.label)
        .fontSize(15)
        .fontWeight(this.isSelected ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.isSelected ? $r('sys.color.icon_emphasize') : $r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12 })
    .borderRadius(14)
    .backgroundColor(this.isSelected ? 'rgba(10, 89, 247, 0.08)' : Color.Transparent)
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      if (this.onClickItem) {
        this.onClickItem();
      }
    })
  }
}

@Component
export struct SideDrawer {
  @Prop @Watch('onDrawerOpenChange') isOpen: boolean = false;
  @Prop shellConnected: boolean = false;
  @Prop dshReady: boolean = false;
  @Prop debugPhase: HdcDebugPhase = 'checking';
  @Prop debugPort: number = 0;
  @Prop @Watch('onCurrentActivePageChange') currentActivePage: string = 'dsh'; // 'console' | 'dsh' | 'browser'
  @State private activePage: string = 'dsh';
  @State private isAboutOpen: boolean = false;
  @State private showKeepAliveMenu: boolean = false;
  @StorageProp('bgKeepAliveMode') bgKeepAliveMode: KeepAliveMode = 'location';
  @StorageProp('bgKeepAliveActive') bgKeepAliveActive: boolean = false;
  @StorageProp('bgKeepAliveStatusText') bgKeepAliveStatusText: string = '准备启动';
  @StorageProp('thinkingCapsuleEnabled') thinkingCapsuleEnabled: boolean = true;
  @StorageProp('thinkingCapsuleSurface') thinkingCapsuleSurface: string = '待命就绪';

  onClose?: () => void = undefined;
  onSelectPage?: (page: 'console' | 'dsh' | 'browser') => void = undefined;
  onOpenUrl?: (url: string) => void = undefined;
  onOpenDebugGuide?: () => void = undefined;

  private getEffectivePhase(): HdcDebugPhase {
    return this.shellConnected ? 'connected' : this.debugPhase;
  }

  private getDebugSummary(): DebugPhaseUiCopy {
    return getDebugPhaseSummary(this.getEffectivePhase(), this.debugPort);
  }

  private getStatusDotColor(): ResourceColor {
    const phase = this.getEffectivePhase();
    if (phase === 'connected') {
      return $r('sys.color.confirm');
    }
    if (phase === 'auth_rejected') {
      return $r('sys.color.warning');
    }
    if (phase === 'checking' || phase === 'awaiting_auth') {
      return $r('sys.color.icon_emphasize');
    }
    return $r('sys.color.alert');
  }

  private getStatusTextColor(): ResourceColor {
    const phase = this.getEffectivePhase();
    if (phase === 'connected') {
      return $r('sys.color.font_secondary');
    }
    if (phase === 'auth_rejected') {
      return $r('sys.color.warning');
    }
    if (phase === 'checking' || phase === 'awaiting_auth') {
      return $r('sys.color.icon_emphasize');
    }
    return $r('sys.color.alert');
  }

  private getKeepAliveModeLabel(mode: KeepAliveMode): string {
    switch (mode) {
      case 'location':
        return '模拟定位';
      case 'dataTransfer':
        return '模拟下载';
      case 'taskKeeping':
        return '任务保持';
      case 'off':
      default:
        return '关闭';
    }
  }

  private isTabletOr2in1(): boolean {
    return deviceInfo.deviceType === 'tablet' || deviceInfo.deviceType === '2in1';
  }

  aboutToAppear() {
    this.activePage = this.currentActivePage;
  }

  onCurrentActivePageChange() {
    hilog.info(0x3F00, 'SideDrawer', 'currentActivePage changed to: %{public}s', this.currentActivePage);
    this.activePage = this.currentActivePage;
  }

  onDrawerOpenChange() {
    if (this.isOpen) {
      hilog.info(0x3F00, 'SideDrawer', 'drawer opened, syncing activePage=%{public}s from currentActivePage=%{public}s', this.activePage, this.currentActivePage);
      this.activePage = this.currentActivePage;
    } else {
      this.showKeepAliveMenu = false;
    }
  }

  @Builder
  KeepAliveModeMenu() {
    Menu() {
      MenuItem({ content: '后台保活模式' })
        .contentFont({ size: 13, weight: FontWeight.Medium })
        .contentFontColor($r('sys.color.font_secondary'))
        .enabled(false)

      MenuItem({
        content: '模拟定位',
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.compass_circle'))
          .fontColor([$r('sys.color.icon_primary')]),
        symbolEndIcon: this.bgKeepAliveMode === 'location'
          ? new SymbolGlyphModifier($r('sys.symbol.checkmark')).fontColor([$r('sys.color.icon_emphasize')])
          : undefined
      })
        .contentFont({ size: 15 })
        .contentFontColor(this.bgKeepAliveMode === 'location' ? $r('sys.color.icon_emphasize') : $r('sys.color.font_primary'))
        .onClick(() => {
          BackgroundKeepAliveManager.getInstance().setMode('location');
          this.showKeepAliveMenu = false;
        })

      MenuItem({
        content: '模拟下载',
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.circle_and_arrow_down'))
          .fontColor([$r('sys.color.icon_primary')]),
        symbolEndIcon: this.bgKeepAliveMode === 'dataTransfer'
          ? new SymbolGlyphModifier($r('sys.symbol.checkmark')).fontColor([$r('sys.color.icon_emphasize')])
          : undefined
      })
        .contentFont({ size: 15 })
        .contentFontColor(this.bgKeepAliveMode === 'dataTransfer' ? $r('sys.color.icon_emphasize') : $r('sys.color.font_primary'))
        .onClick(() => {
          BackgroundKeepAliveManager.getInstance().setMode('dataTransfer');
          this.showKeepAliveMenu = false;
        })

      if (this.isTabletOr2in1()) {
        MenuItem({
          content: '任务保持',
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.lock_filled_arrow_counterclockwise'))
            .fontColor([$r('sys.color.icon_primary')]),
          symbolEndIcon: this.bgKeepAliveMode === 'taskKeeping'
            ? new SymbolGlyphModifier($r('sys.symbol.checkmark')).fontColor([$r('sys.color.icon_emphasize')])
            : undefined
        })
          .contentFont({ size: 15 })
          .contentFontColor(this.bgKeepAliveMode === 'taskKeeping' ? $r('sys.color.icon_emphasize') : $r('sys.color.font_primary'))
          .onClick(() => {
            BackgroundKeepAliveManager.getInstance().setMode('taskKeeping');
            this.showKeepAliveMenu = false;
          })
      }

      MenuItem({
        content: '关闭',
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.nosign'))
          .fontColor([$r('sys.color.icon_secondary')]),
        symbolEndIcon: this.bgKeepAliveMode === 'off'
          ? new SymbolGlyphModifier($r('sys.symbol.checkmark')).fontColor([$r('sys.color.icon_emphasize')])
          : undefined
      })
        .contentFont({ size: 15 })
        .contentFontColor(this.bgKeepAliveMode === 'off' ? $r('sys.color.icon_emphasize') : $r('sys.color.font_secondary'))
        .onClick(() => {
          BackgroundKeepAliveManager.getInstance().setMode('off');
          this.showKeepAliveMenu = false;
        })
    }
    .menuItemDivider({
      color: $r('sys.color.comp_divider'),
      strokeWidth: LengthMetrics.vp(0.5),
      startMargin: LengthMetrics.vp(12),
      endMargin: LengthMetrics.vp(12)
    })
    .borderRadius(20)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 1. Semi-transparent Backdrop
      if (this.isOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.35)')
          .onClick(() => {
            if (this.isAboutOpen) {
              this.isAboutOpen = false;
              return;
            }
            if (this.onClose) {
              this.onClose();
            }
          })
          .animation({ duration: 240, curve: Curve.EaseInOut })
      }

      // 2. Sliding Drawer Panel (HarmonyOS grey-surface + white-card architecture)
      Column() {
        // Header: App Identity + Native Circular Close Button
        Row({ space: 12 }) {
          Row({ space: 10 }) {
            Image($r('app.media.startIcon'))
              .width(38)
              .height(38)
              .borderRadius(10)

            Column({ space: 3 }) {
              Text('Swai')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_primary'))

              Row({ space: 5 }) {
                Circle({ width: 6, height: 6 })
                  .fill(this.getStatusDotColor())
                Text(this.getDebugSummary().headerText)
                  .fontSize(11)
                  .fontColor($r('sys.color.font_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            if (this.onOpenDebugGuide) {
              this.onOpenDebugGuide();
            }
          })

          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(17)
              .fontColor([$r('sys.color.icon_primary')])
          }
          .width(34)
          .height(34)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => {
            if (this.onClose) {
              this.onClose();
            }
          })
        }
        .width('100%')
        .padding({ left: 18, right: 16, top: 52, bottom: 16 })
        .alignItems(VerticalAlign.Center)

        // Scrollable Grouped Content (Spring edge effect, ClashBox List pattern)
        List({ space: 12 }) {
          // Group 1: Core Navigation Card
          ListItem() {
            Column({ space: 2 }) {
              SideDrawerNavRow({
                symbolIcon: $r('sys.symbol.message_on_message_fill'),
                label: 'Swai 智能体',
                isSelected: this.activePage === 'dsh',
                onClickItem: () => {
                  this.activePage = 'dsh';
                  if (this.onSelectPage) {
                    this.onSelectPage('dsh');
                  }
                }
              })

              SideDrawerNavRow({
                symbolIcon: $r('sys.symbol.doc_plaintext'),
                label: 'Shell 终端',
                isSelected: this.activePage === 'console',
                onClickItem: () => {
                  this.activePage = 'console';
                  if (this.onSelectPage) {
                    this.onSelectPage('console');
                  }
                }
              })

              SideDrawerNavRow({
                symbolIcon: $r('sys.symbol.compass_circle'),
                label: '浏览器',
                isSelected: this.activePage === 'browser',
                onClickItem: () => {
                  this.activePage = 'browser';
                  if (this.onSelectPage) {
                    this.onSelectPage('browser');
                  }
                }
              })
            }
            .width('100%')
            .padding(6)
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(20)
          }

          // Section Title: System & Runtime
          ListItem() {
            Text('运行与调试')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_secondary'))
              .padding({ left: 12, top: 4 })
          }

          // Group 2: Unified System Settings Card (Debug + Keep-Alive + Thinking Capsule)
          ListItem() {
            Column() {
              // Row 1: Developer Debugging
              Row({ space: 12 }) {
                SymbolGlyph($r('sys.symbol.wrench_and_screwdriver'))
                  .fontSize(20)
                  .fontColor([$r('sys.color.icon_emphasize')])
                  .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)

                Column({ space: 2 }) {
                  Text('开发者调试')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  Text(this.getDebugSummary().subtitle)
                    .fontSize(12)
                    .fontColor($r('sys.color.font_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Row({ space: 5 }) {
                  Circle({ width: 6, height: 6 })
                    .fill(this.getStatusDotColor())
                  Text(this.getDebugSummary().badgeText)
                    .fontSize(12)
                    .fontColor(this.getStatusTextColor())
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(18)
                    .fontColor([$r('sys.color.icon_tertiary')])
                }
                .alignItems(VerticalAlign.Center)
              }
              .width('100%')
              .constraintSize({ minHeight: 56 })
              .padding({ left: 14, right: 12, top: 10, bottom: 10 })
              .alignItems(VerticalAlign.Center)
              .clickEffect({ level: ClickEffectLevel.LIGHT })
              .onClick(() => {
                if (this.onOpenDebugGuide) {
                  this.onOpenDebugGuide();
                }
              })

              Divider()
                .color($r('sys.color.comp_divider'))
                .strokeWidth(0.5)
                .margin({ left: 46, right: 14 })

              // Row 2: Background Keep-Alive (ClashBox MENU pattern)
              Row({ space: 12 }) {
                SymbolGlyph($r('sys.symbol.bolt_filled_on_circle'))
                  .fontSize(20)
                  .fontColor([$r('sys.color.icon_emphasize')])
                  .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)

                Column({ space: 2 }) {
                  Text('后台保活')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_primary'))
                    .maxLines(1)

                  Text(this.bgKeepAliveStatusText)
                    .fontSize(12)
                    .fontColor($r('sys.color.font_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Row({ space: 5 }) {
                  Text(this.getKeepAliveModeLabel(this.bgKeepAliveMode))
                    .fontSize(13)
                    .fontColor($r('sys.color.font_secondary'))
                  SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
                    .fontSize(11)
                    .fontColor([$r('sys.color.icon_tertiary')])
                }
                .alignItems(VerticalAlign.Center)
              }
              .width('100%')
              .constraintSize({ minHeight: 56 })
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .alignItems(VerticalAlign.Center)
              .clickEffect({ level: ClickEffectLevel.LIGHT })
              .bindMenu(this.showKeepAliveMenu, this.KeepAliveModeMenu(), {
                placement: Placement.BottomRight,
                onDisappear: () => {
                  this.showKeepAliveMenu = false;
                }
              })
              .onClick(() => {
                this.showKeepAliveMenu = true;
              })

              Divider()
                .color($r('sys.color.comp_divider'))
                .strokeWidth(0.5)
                .margin({ left: 46, right: 14 })

              // Row 3: Thinking Capsule (ClashBox toggleRowList pattern)
              Row({ space: 12 }) {
                SymbolGlyph($r('sys.symbol.circle_filled_and_circle'))
                  .fontSize(20)
                  .fontColor([$r('sys.color.icon_emphasize')])
                  .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)

                Column({ space: 2 }) {
                  Text('思考胶囊')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_primary'))
                    .maxLines(1)

                  Text(this.thinkingCapsuleSurface)
                    .fontSize(12)
                    .fontColor($r('sys.color.font_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Toggle({ type: ToggleType.Switch, isOn: this.thinkingCapsuleEnabled })
                  .selectedColor($r('sys.color.icon_emphasize'))
                  .hitTestBehavior(HitTestMode.None)
              }
              .width('100%')
              .constraintSize({ minHeight: 56 })
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .alignItems(VerticalAlign.Center)
              .clickEffect({ level: ClickEffectLevel.LIGHT })
              .onClick(() => {
                ThinkingCapsuleManager.getInstance().setEnabled(!this.thinkingCapsuleEnabled);
              })
            }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(20)
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 14, right: 14 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)

        // Lightweight Native Footer (No heavy borders or Tailwind pills)
        Row() {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.info_circle'))
              .fontSize(16)
              .fontColor([$r('sys.color.icon_secondary')])
            Text('关于')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_secondary'))
          }
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .borderRadius(12)
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => {
            this.isAboutOpen = true;
          })

          Blank()

          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.paperplane'))
              .fontSize(15)
              .fontColor([$r('sys.color.icon_secondary')])
            Text('GitHub')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_secondary'))
          }
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .borderRadius(12)
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => {
            this.activePage = 'browser';
            if (this.onOpenUrl) {
              this.onOpenUrl('https://github.com/shuwei-ai/swai');
            }
          })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 8, bottom: 28 })
        .alignItems(VerticalAlign.Center)
      }
      .width('78%')
      .constraintSize({ maxWidth: 320 })
      .height('100%')
      .backgroundColor($r('sys.color.background_secondary'))
      .borderRadius({ topRight: 24, bottomRight: 24 })
      .shadow({ radius: 28, color: 'rgba(0, 0, 0, 0.14)', offsetX: 4, offsetY: 0 })
      .offset({ x: this.isOpen ? 0 : -360 })
      .animation({ duration: 260, curve: Curve.FastOutSlowIn })

      // 3. About Modal Overlay (Clean HarmonyOS Native Dialog)
      if (this.isAboutOpen) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0, 0, 0, 0.45)')
            .onClick(() => {
              this.isAboutOpen = false;
            })

          Column({ space: 16 }) {
            Column({ space: 6 }) {
              Image($r('app.media.startIcon'))
                .width(58)
                .height(58)
                .borderRadius(14)

              Text('Swai')
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_primary'))
                .margin({ top: 4 })

              Text('v1.0.0 · 枢维智能')
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
            }
            .alignItems(HorizontalAlign.Center)
            .width('100%')

            Text('面向 HarmonyOS NEXT 的端侧个人智能体与系统自动化平台，端侧数据不离机，全流程开源。')
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .lineHeight(20)
              .textAlign(TextAlign.Center)

            // Native inset info group
            Column() {
              Row() {
                Text('开源仓库')
                  .fontSize(14)
                  .fontColor($r('sys.color.font_primary'))
                Blank()
                Text('shuwei-ai/swai')
                  .fontSize(13)
                  .fontColor($r('sys.color.icon_emphasize'))
                  .margin({ right: 4 })
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(16)
                  .fontColor([$r('sys.color.icon_tertiary')])
              }
              .width('100%')
              .height(44)
              .padding({ left: 14, right: 12 })
              .alignItems(VerticalAlign.Center)
              .clickEffect({ level: ClickEffectLevel.LIGHT })
              .onClick(() => {
                this.isAboutOpen = false;
                this.activePage = 'browser';
                if (this.onOpenUrl) {
                  this.onOpenUrl('https://github.com/shuwei-ai/swai');
                }
              })

              Divider()
                .color($r('sys.color.comp_divider'))
                .strokeWidth(0.5)
                .margin({ left: 14, right: 14 })

              Row() {
                Text('开源协议')
                  .fontSize(14)
                  .fontColor($r('sys.color.font_primary'))
                Blank()
                Text('Apache-2.0')
                  .fontSize(13)
                  .fontColor($r('sys.color.font_secondary'))
              }
              .width('100%')
              .height(44)
              .padding({ left: 14, right: 14 })
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .backgroundColor($r('sys.color.background_secondary'))
            .borderRadius(16)

            Row({ space: 10 }) {
              Button('访问仓库')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .height(40)
                .layoutWeight(1)
                .borderRadius(20)
                .backgroundColor($r('sys.color.comp_background_tertiary'))
                .fontColor($r('sys.color.font_primary'))
                .onClick(() => {
                  this.isAboutOpen = false;
                  this.activePage = 'browser';
                  if (this.onOpenUrl) {
                    this.onOpenUrl('https://github.com/shuwei-ai/swai');
                  }
                })

              Button('知道了')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .height(40)
                .layoutWeight(1)
                .borderRadius(20)
                .backgroundColor($r('sys.color.icon_emphasize'))
                .fontColor($r('sys.color.font_on_primary'))
                .onClick(() => {
                  this.isAboutOpen = false;
                })
            }
            .width('100%')
          }
          .width('84%')
          .constraintSize({ maxWidth: 340 })
          .padding(22)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius(24)
          .shadow({ radius: 28, color: 'rgba(0, 0, 0, 0.18)', offsetY: 8 })
        }
        .width('100%')
        .height('100%')
        .animation({ duration: 200, curve: Curve.EaseInOut })
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(this.isOpen ? HitTestMode.Default : HitTestMode.None)
  }
}
