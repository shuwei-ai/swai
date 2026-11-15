/*
 * SideDrawer: Clean & Minimalist Navigation Drawer (Mika Inspired).
 * Retains core navigation modules + Mika-style Footer (About on left, GitHub repo on right):
 * 1. App Header (✦ Swai with live status)
 * 2. Swai 智能体
 * 3. Shell 终端
 * 4. 浏览器
 * 5. Footer: 关于 (About Swai) on bottom left, GitHub repo on bottom right.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

@Component
export struct SideDrawer {
  @Prop isOpen: boolean = false;
  @Prop shellConnected: boolean = false;
  @Prop dshReady: boolean = false;
  @Prop currentActivePage: string = 'dsh'; // 'console' | 'dsh' | 'browser'
  @State private isAboutOpen: boolean = false;

  onClose?: () => void = undefined;
  onSelectPage?: (page: 'console' | 'dsh' | 'browser') => void = undefined;
  onOpenUrl?: (url: string) => void = undefined;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 1. Semi-transparent Backdrop
      if (this.isOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(15, 23, 42, 0.45)')
          .onClick(() => {
            if (this.isAboutOpen) {
              this.isAboutOpen = false;
              return;
            }
            if (this.onClose) {
              this.onClose();
            }
          })
          .animation({ duration: 250, curve: Curve.EaseInOut })
      }

      // 2. Sliding Drawer Panel
      Column() {
        // App Header Section
        Row() {
          // App Logo
          Row() {
            Text('✦')
              .fontSize(18)
              .fontColor('#38bdf8')
          }
          .width(38)
          .height(38)
          .backgroundColor('#0f172a')
          .borderRadius(10)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .margin({ right: 10 })

          Column({ space: 3 }) {
            Text('Swai')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#0f172a')

            Row({ space: 4 }) {
              Circle({ width: 6, height: 6 })
                .fill(this.shellConnected ? '#22c55e' : '#f59e0b')
              Text(this.shellConnected ? '枢维智能 · 个人助理' : '服务连接中...')
                .fontSize(10)
                .fontColor(this.shellConnected ? '#15803d' : '#b45309')
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 48, bottom: 20 })
        .alignItems(VerticalAlign.Center)

        Divider()
          .color('#f1f5f9')
          .margin({ left: 16, right: 16, bottom: 12 })

        // Core Real Navigation Items
        Column({ space: 8 }) {
          // Swai Agent (Primary active item)
          this.buildNavRow('🤖', 'Swai 智能体', () => {
            if (this.onSelectPage) this.onSelectPage('dsh');
          }, this.currentActivePage === 'dsh')

          // Shell Terminal
          this.buildNavRow('💻', 'Shell 终端', () => {
            if (this.onSelectPage) this.onSelectPage('console');
          }, this.currentActivePage === 'console')

          // Browser
          this.buildNavRow('🌐', '浏览器', () => {
            if (this.onSelectPage) this.onSelectPage('browser');
          }, this.currentActivePage === 'browser')
        }
        .width('100%')
        .padding({ left: 12, right: 12 })

        Blank()

        Divider()
          .color('#f1f5f9')
          .margin({ left: 16, right: 16, bottom: 12 })

        // 5. Mika-Style Footer: About on left, GitHub Repo on right
        Row() {
          // Left: 关于 (About)
          Row({ space: 6 }) {
            Text('ⓘ')
              .fontSize(14)
              .fontColor('#64748b')
            Text('关于')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#475569')
          }
          .padding({ left: 10, right: 12, top: 8, bottom: 8 })
          .borderRadius(8)
          .backgroundColor('#f8fafc')
          .onClick(() => {
            this.isAboutOpen = true;
          })

          Blank()

          // Right: GitHub 开源仓库地址
          Row({ space: 5 }) {
            Text('⌥')
              .fontSize(13)
              .fontColor('#0284c7')
            Text('GitHub ↗')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#0284c7')
          }
          .padding({ left: 10, right: 12, top: 8, bottom: 8 })
          .borderRadius(8)
          .backgroundColor('#f0f9ff')
          .border({ width: 1, color: '#e0f2fe' })
          .onClick(() => {
            if (this.onOpenUrl) {
              this.onOpenUrl('https://github.com/shuwei-ai/swai');
            }
          })
        }
        .width('100%')
        .padding({ left: 14, right: 14, bottom: 28 })
        .alignItems(VerticalAlign.Center)
      }
      .width('72%')
      .height('100%')
      .backgroundColor('#ffffff')
      .borderRadius({ topRight: 20, bottomRight: 20 })
      .shadow({ radius: 24, color: 'rgba(0, 0, 0, 0.25)', offsetX: 4, offsetY: 0 })
      .offset({ x: this.isOpen ? 0 : -350 })
      .animation({ duration: 280, curve: Curve.FastOutSlowIn })

      // 3. About Modal Overlay
      if (this.isAboutOpen) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(15, 23, 42, 0.65)')
            .onClick(() => {
              this.isAboutOpen = false;
            })

          Column({ space: 14 }) {
            // Icon + Title + Version
            Column({ space: 6 }) {
              Image($r('app.media.startIcon'))
                .width(64)
                .height(64)
                .borderRadius(14)
                .shadow({ radius: 12, color: 'rgba(0,0,0,0.08)', offsetY: 4 })

              Text('Swai')
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor('#0f172a')
                .margin({ top: 4 })

              Text('枢维智能 · 个人智能体 (v1.0.0)')
                .fontSize(12)
                .fontColor('#64748b')
            }
            .alignItems(HorizontalAlign.Center)
            .width('100%')

            Divider()
              .color('#f1f5f9')

            // Details
            Column({ space: 10 }) {
              Text('Swai 是面向 HarmonyOS NEXT 的端侧个人专属智能体助手与端侧自动化平台，由枢维智能科技团队研发并全面开源。')
                .fontSize(13)
                .fontColor('#334155')
                .lineHeight(20)

              Column({ space: 6 }) {
                this.buildAboutFeatureItem('🤖', '内置 DeepSeek Harness 原生引擎与长思维链')
                this.buildAboutFeatureItem('🌐', '灵动画中画悬浮窗，跨应用多任务并行')
                this.buildAboutFeatureItem('💻', '系统级特权通道 (uid 2000) 与 UI 自动化')
                this.buildAboutFeatureItem('🔒', '端侧数据不离机，全流程隐私安全')
              }
              .width('100%')
              .padding(10)
              .backgroundColor('#f8fafc')
              .borderRadius(10)

              Row({ space: 6 }) {
                Text('开源仓库:')
                  .fontSize(12)
                  .fontColor('#64748b')
                Text('https://github.com/shuwei-ai/swai')
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#0284c7')
                  .layoutWeight(1)
              }
              .width('100%')
              .padding({ top: 4 })
              .onClick(() => {
                this.isAboutOpen = false;
                if (this.onOpenUrl) {
                  this.onOpenUrl('https://github.com/shuwei-ai/swai');
                }
              })

              Text('开源协议: Apache-2.0 License')
                .fontSize(11)
                .fontColor('#94a3b8')
            }
            .width('100%')

            Divider()
              .color('#f1f5f9')

            // Action Buttons
            Row({ space: 10 }) {
              Button('访问 GitHub 仓库', { type: ButtonType.Normal })
                .fontSize(13)
                .height(38)
                .layoutWeight(1)
                .borderRadius(8)
                .backgroundColor('#f0f9ff')
                .fontColor('#0284c7')
                .border({ width: 1, color: '#bae6fd' })
                .onClick(() => {
                  this.isAboutOpen = false;
                  if (this.onOpenUrl) {
                    this.onOpenUrl('https://github.com/shuwei-ai/swai');
                  }
                })

              Button('关闭', { type: ButtonType.Normal })
                .fontSize(13)
                .height(38)
                .layoutWeight(1)
                .borderRadius(8)
                .backgroundColor('#0284c7')
                .fontColor('#ffffff')
                .onClick(() => {
                  this.isAboutOpen = false;
                })
            }
            .width('100%')
          }
          .width('86%')
          .padding(20)
          .backgroundColor('#ffffff')
          .borderRadius(20)
          .shadow({ radius: 32, color: 'rgba(0,0,0,0.25)', offsetY: 8 })
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

  @Builder
  buildAboutFeatureItem(icon: string, text: string) {
    Row({ space: 8 }) {
      Text(icon)
        .fontSize(13)
      Text(text)
        .fontSize(12)
        .fontColor('#475569')
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildNavRow(icon: string, label: string, onClick: () => void, isSelected: boolean) {
    Row({ space: 12 }) {
      Text(icon)
        .fontSize(16)

      Text(label)
        .fontSize(15)
        .fontWeight(isSelected ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(isSelected ? '#0284c7' : '#1e293b')
        .layoutWeight(1)

      if (isSelected) {
        Circle({ width: 6, height: 6 })
          .fill('#0284c7')
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 14, right: 14 })
    .borderRadius(12)
    .backgroundColor(isSelected ? '#f0f9ff' : 'transparent')
    .onClick(() => {
      onClick();
    })
  }
}
