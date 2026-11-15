/*
 * BrowserHomeView: Dedicated Browser Landing Page.
 * Styled after Mika's Browser Screen (matching user screenshots):
 * Features:
 * 1. Clean Top Bar with Back action and title.
 * 2. Capsule Search / URL bar with quick search suggestion.
 * 3. Favorite Sites Grid (微信公众平台, 开发者联盟, GitHub, Add).
 * 4. Recent Browsing History list with one-tap launch and clear.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

import promptAction from '@ohos.promptAction';
import { BrowserManager } from './BrowserManager';
import { BrowserPipState, FavoriteSiteItem, RecentPageItem, PipMode } from './BrowserPipState';

@Component
export struct BrowserHomeView {
  onBack?: () => void = undefined;
  onLaunchUrl?: (url: string) => void = undefined;

  @State private searchInput: string = '';
  @State private favoriteSites: FavoriteSiteItem[] = [];
  @State private recentPages: RecentPageItem[] = [];
  @State private isOrganizing: boolean = false;

  private pipState: BrowserPipState = BrowserPipState.getInstance();
  private browserManager: BrowserManager = BrowserManager.getInstance();
  private unsubscribe?: () => void = undefined;

  aboutToAppear(): void {
    this.refreshData();
    this.unsubscribe = this.pipState.subscribe(() => {
      this.refreshData();
    });
  }

  aboutToDisappear(): void {
    if (this.unsubscribe) {
      this.unsubscribe();
    }
  }

  private refreshData(): void {
    this.favoriteSites = [...this.pipState.favoriteSites];
    this.recentPages = [...this.pipState.recentPages];
  }

  private async handleGoUrl(targetUrl: string): Promise<void> {
    let url = targetUrl.trim();
    if (!url) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      if (url.includes('.') && !url.includes(' ')) {
        url = 'https://' + url;
      } else {
        url = `https://cn.bing.com/search?q=${encodeURIComponent(url)}`;
      }
    }
    this.pipState.addRecentPage(url, url);
    if (this.onLaunchUrl) {
      this.onLaunchUrl(url);
    } else {
      try {
        await this.browserManager.ensureControllerAttached(3000);
        this.browserManager.controller.loadUrl(url);
      } catch (_e) {}
    }
  }

  build() {
    Column() {
      // 1. Top Bar
      Row() {
        Button({ type: ButtonType.Circle }) {
          Text('‹')
            .fontSize(24)
            .fontWeight(FontWeight.Regular)
            .fontColor('#0f172a')
        }
        .width(36)
        .height(36)
        .backgroundColor('#f8fafc')
        .onClick(() => {
          if (this.onBack) {
            this.onBack();
          }
        })

        Text('浏览器')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#0f172a')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .margin({ right: 36 }) // Balance back button
      }
      .width('100%')
      .padding({ top: 38, left: 12, right: 12, bottom: 6 })
      .alignItems(VerticalAlign.Center)

      // Scrollable Content
      Scroll() {
        Column({ space: 22 }) {
          // 2. Search & URL Bar
          Column({ space: 6 }) {
            Row() {
              Text('🔍')
                .fontSize(14)
                .margin({ left: 14, right: 8 })

              TextInput({ text: this.searchInput, placeholder: '搜索或输入网址' })
                .placeholderColor('#94a3b8')
                .placeholderFont({ size: 14 })
                .fontSize(14)
                .fontColor('#0f172a')
                .backgroundColor('transparent')
                .layoutWeight(1)
                .height(44)
                .onChange((value: string) => {
                  this.searchInput = value;
                })
                .onSubmit(() => {
                  this.handleGoUrl(this.searchInput);
                })

              if (this.searchInput.length > 0) {
                Button({ type: ButtonType.Circle }) {
                  Text('×')
                    .fontSize(14)
                    .fontColor('#94a3b8')
                }
                .width(24)
                .height(24)
                .backgroundColor('#f1f5f9')
                .margin({ right: 10 })
                .onClick(() => {
                  this.searchInput = '';
                })
              }
            }
            .width('100%')
            .height(46)
            .backgroundColor('#f1f5f9')
            .borderRadius(23)
            .border({ width: 1, color: '#e2e8f0' })

            Text('用必应搜索')
              .fontSize(11)
              .fontColor('#94a3b8')
              .textAlign(TextAlign.Center)
              .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4 })

          // 3. Favorite Sites Section (常用网站)
          Column({ space: 14 }) {
            Row() {
              Text('常用网站')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor('#64748b')

              Blank()

              Text(this.isOrganizing ? '完成' : '整理')
                .fontSize(13)
                .fontColor('#0284c7')
                .onClick(() => {
                  this.isOrganizing = !this.isOrganizing;
                })
            }
            .width('100%')

            // Sites Grid (4 items per row)
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(this.favoriteSites, (site: FavoriteSiteItem) => {
                Column({ space: 8 }) {
                  Stack({ alignContent: Alignment.TopEnd }) {
                    Column() {
                      Text(site.iconText)
                        .fontSize(18)
                        .fontWeight(FontWeight.Bold)
                        .fontColor('#ffffff')
                    }
                    .width(54)
                    .height(54)
                    .backgroundColor(site.iconBgColor)
                    .borderRadius(16)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .shadow({ radius: 6, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 2 })

                    if (this.isOrganizing) {
                      Button({ type: ButtonType.Circle }) {
                        Text('×')
                          .fontSize(11)
                          .fontColor('#ffffff')
                      }
                      .width(18)
                      .height(18)
                      .backgroundColor('#ef4444')
                      .offset({ x: 4, y: -4 })
                      .onClick(() => {
                        this.pipState.favoriteSites = this.pipState.favoriteSites.filter(s => s.id !== site.id);
                        this.refreshData();
                      })
                    }
                  }

                  Text(site.title)
                    .fontSize(11)
                    .fontColor('#334155')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .textAlign(TextAlign.Center)
                    .width(68)
                }
                .width('25%')
                .alignItems(HorizontalAlign.Center)
                .margin({ bottom: 12 })
                .onClick(() => {
                  if (!this.isOrganizing) {
                    this.handleGoUrl(site.url);
                  }
                })
              }, (site: FavoriteSiteItem) => site.id)

              // Add Site Button
              Column({ space: 8 }) {
                Column() {
                  Text('+')
                    .fontSize(22)
                    .fontWeight(FontWeight.Regular)
                    .fontColor('#94a3b8')
                }
                .width(54)
                .height(54)
                .backgroundColor('#f8fafc')
                .borderRadius(16)
                .border({ width: 1, color: '#e2e8f0', style: BorderStyle.Dashed })
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)

                Text('添加')
                  .fontSize(11)
                  .fontColor('#94a3b8')
                  .textAlign(TextAlign.Center)
                  .width(68)
              }
              .width('25%')
              .alignItems(HorizontalAlign.Center)
              .margin({ bottom: 12 })
              .onClick(() => {
                promptAction.showToast({ message: '快捷添加网站功能即将上线', duration: 1500 });
              })
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          // 4. Recent Pages Section (最近打开)
          Column({ space: 10 }) {
            Row() {
              Text('最近打开')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor('#64748b')

              Blank()

              if (this.recentPages.length > 0) {
                Text('清除')
                  .fontSize(13)
                  .fontColor('#0284c7')
                  .onClick(() => {
                    this.pipState.clearRecentPages();
                  })
              }
            }
            .width('100%')

            if (this.recentPages.length === 0) {
              Column({ space: 6 }) {
                Text('暂无最近打开的网页')
                  .fontSize(12)
                  .fontColor('#94a3b8')
              }
              .width('100%')
              .padding({ top: 20, bottom: 20 })
              .alignItems(HorizontalAlign.Center)
            } else {
              Column({ space: 8 }) {
                ForEach(this.recentPages, (item: RecentPageItem) => {
                  Row({ space: 12 }) {
                    // Small site badge
                    Column() {
                      Text('🌐')
                        .fontSize(14)
                    }
                    .width(36)
                    .height(36)
                    .backgroundColor('#f1f5f9')
                    .borderRadius(10)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)

                    Column({ space: 2 }) {
                      Text(item.title)
                        .fontSize(13)
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#0f172a')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })

                      Text(item.url)
                        .fontSize(11)
                        .fontColor('#94a3b8')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)

                    Text(item.timeLabel)
                      .fontSize(11)
                      .fontColor('#94a3b8')
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                  .backgroundColor('#ffffff')
                  .borderRadius(12)
                  .border({ width: 1, color: '#f1f5f9' })
                  .shadow({ radius: 4, color: 'rgba(0, 0, 0, 0.03)', offsetX: 0, offsetY: 1 })
                  .onClick(() => {
                    this.handleGoUrl(item.url);
                  })
                }, (item: RecentPageItem) => item.id)
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 24 })
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#ffffff')
  }
}
