/*
 * DeveloperDebugGuide: 4-step wireless debugging setup wizard & live status dialog.
 *
 * Guides users through enabling HarmonyOS Developer Mode -> Wireless Debugging,
 * triggers zero-config loopback discovery / authorization prompt handling,
 * provides a collapsible manual port fallback, and manages an active uid 2000 session.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

import {
  formatPublicKeyFingerprint,
  HdcDebugPhase,
  isValidPortInput,
  parsePortInput
} from '../common/HdcDebugState';

@Component
export struct DeveloperDebugGuide {
  @Prop @Watch('onGuidePropChange') isOpen: boolean = false;
  @Prop @Watch('onGuidePropChange') phase: HdcDebugPhase = 'checking';
  @Prop connected: boolean = false;
  @Prop host: string = '127.0.0.1';
  @Prop port: number = 0;
  @Prop lastPort: number = 0;
  @Prop lastError: string = '';
  @Prop uidVerified: boolean = false;
  @Prop uidInfo: string = '';
  @Prop publicKey: string = '';
  @Prop isBusy: boolean = false;

  @State private step1Expanded: boolean = false;
  @State private manualExpanded: boolean = false;
  @State private hostInput: string = '127.0.0.1';
  @State private portInput: string = '';
  @State private portErrorText: string = '';
  @State private showDiagnosticDetail: boolean = false;

  onClose?: () => void = undefined;
  onAutoDetect?: () => void = undefined;
  onManualConnect?: (host: string, port: number) => void = undefined;
  onOpenSettings?: () => void = undefined;
  onVerifyUid?: () => void = undefined;
  onDisconnect?: () => void = undefined;

  aboutToAppear(): void {
    this.syncLocalInputs();
  }

  onGuidePropChange(): void {
    this.syncLocalInputs();
  }

  private syncLocalInputs(): void {
    if (this.phase === 'need_port') {
      this.manualExpanded = true;
    }
    if (this.isOpen) {
      if (this.host.trim().length > 0) {
        this.hostInput = this.host;
      }
      if (this.portInput.trim().length === 0) {
        const candidatePort = this.port > 0 ? this.port : this.lastPort;
        if (candidatePort > 0) {
          this.portInput = String(candidatePort);
        }
      }
      this.portErrorText = '';
    }
  }

  private getBannerBgColor(): string {
    if (this.connected || this.phase === 'connected') {
      return '#f0fdf4';
    }
    if (this.phase === 'checking' || this.phase === 'awaiting_auth') {
      return '#f0f9ff';
    }
    if (this.phase === 'auth_rejected') {
      return '#fef2f2';
    }
    return '#fffbeb';
  }

  private getBannerBorderColor(): string {
    if (this.connected || this.phase === 'connected') {
      return '#bbf7d0';
    }
    if (this.phase === 'checking' || this.phase === 'awaiting_auth') {
      return '#bae6fd';
    }
    if (this.phase === 'auth_rejected') {
      return '#fecaca';
    }
    return '#fde68a';
  }

  private getBannerDotColor(): string {
    if (this.connected || this.phase === 'connected') {
      return '#16a34a';
    }
    if (this.phase === 'checking' || this.phase === 'awaiting_auth') {
      return '#0284c7';
    }
    if (this.phase === 'auth_rejected') {
      return '#dc2626';
    }
    return '#d97706';
  }

  private getBannerTitle(): string {
    if (this.connected || this.phase === 'connected') {
      return '开发者调试已就绪';
    }
    switch (this.phase) {
      case 'checking':
        return '正在检测本机无线调试服务...';
      case 'awaiting_auth':
        return '请在系统弹窗中点击「始终允许」';
      case 'auth_rejected':
        return '调试授权未通过或已超时';
      case 'need_port':
        return '未自动识别到调试端口';
      case 'not_enabled':
      default:
        return '尚未检测到本地无线调试服务';
    }
  }

  private getBannerDesc(): string {
    if (this.connected || this.phase === 'connected') {
      return this.uidVerified && this.uidInfo.length > 0
        ? `已获取本机权限上下文：${this.uidInfo}`
        : '已建立本机回环调试会话，可执行自动化与 Shell 指令。';
    }
    switch (this.phase) {
      case 'checking':
        return '正在尝试连接上次记忆端口及本机回环调试通道，请稍候。';
      case 'awaiting_auth':
        return '系统即将或已经弹出「允许无线调试」提示框，建议勾选「始终允许」以免每次弹窗。';
      case 'auth_rejected':
        return '您可能点击了拒绝或弹窗等待超时。点击下方「立即检测并连接」可重新发起授权。';
      case 'need_port':
        return '如果确认已打开「无线调试」，请将设置页面显示的 5 位端口号填入下方手动连接。';
      case 'not_enabled':
      default:
        return '仅通过本机回环 (127.0.0.1) 解锁跨应用自动化与 Shell；不开启仍可正常使用智能体对话与浏览器。';
    }
  }

  private handleManualSubmit(): void {
    const trimmedPort = this.portInput.trim();
    if (!isValidPortInput(trimmedPort)) {
      this.portErrorText = '请输入 1 - 65535 之间的有效端口号';
      return;
    }
    this.portErrorText = '';
    const parsedPort = parsePortInput(trimmedPort);
    const targetHost = this.hostInput.trim().length > 0 ? this.hostInput.trim() : '127.0.0.1';
    if (this.onManualConnect) {
      this.onManualConnect(targetHost, parsedPort);
    }
  }

  build() {
    if (!this.isOpen) {
      Column()
        .width(0)
        .height(0)
        .hitTestBehavior(HitTestMode.None)
    } else {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(15, 23, 42, 0.65)')
          .onClick(() => {
            if (this.onClose) {
              this.onClose();
            }
          })

        Scroll() {
          Column({ space: 14 }) {
            // Modal Title Header
            Row() {
              Row({ space: 8 }) {
                Text(this.connected ? '⚡' : '🛠️')
                  .fontSize(18)
                Text(this.connected ? '开发者调试状态' : '开发者调试配置向导')
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#0f172a')
              }
              .layoutWeight(1)

              Button({ type: ButtonType.Circle }) {
                Text('✕')
                  .fontSize(13)
                  .fontColor('#64748b')
              }
              .width(30)
              .height(30)
              .backgroundColor('#f1f5f9')
              .onClick(() => {
                if (this.onClose) {
                  this.onClose();
                }
              })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            // Live Status Banner
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                if (!this.connected && (this.phase === 'checking' || this.phase === 'awaiting_auth')) {
                  LoadingProgress()
                    .width(14)
                    .height(14)
                    .color('#0284c7')
                } else {
                  Circle({ width: 8, height: 8 })
                    .fill(this.getBannerDotColor())
                }
                Text(this.getBannerTitle())
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#0f172a')
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Text(this.getBannerDesc())
                .fontSize(12)
                .fontColor('#475569')
                .lineHeight(18)
                .width('100%')
            }
            .width('100%')
            .padding(12)
            .backgroundColor(this.getBannerBgColor())
            .borderRadius(12)
            .border({ width: 1, color: this.getBannerBorderColor() })

            if (this.connected) {
              this.buildConnectedBody();
            } else {
              this.buildSetupWizardBody();
            }
          }
          .width('100%')
          .padding(18)
        }
        .width('90%')
        .constraintSize({ maxHeight: '84%' })
        .backgroundColor('#ffffff')
        .borderRadius(20)
        .shadow({ radius: 32, color: 'rgba(0,0,0,0.28)', offsetY: 8 })
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .animation({ duration: 200, curve: Curve.EaseInOut })
    }
  }

  @Builder
  buildConnectedBody() {
    Column({ space: 12 }) {
      Column({ space: 10 }) {
        this.buildInfoRow('调试通道地址', `${this.host.length > 0 ? this.host : '127.0.0.1'}:${this.port > 0 ? this.port : this.lastPort}`)
        Divider().color('#f1f5f9')
        this.buildInfoRow(
          '权限上下文校验',
          this.uidVerified && this.uidInfo.length > 0
            ? this.uidInfo
            : (this.uidInfo.length > 0 ? this.uidInfo : '尚未校验，可点击下方验证')
        )
        Divider().color('#f1f5f9')
        this.buildInfoRow('本机信任公钥', formatPublicKeyFingerprint(this.publicKey))
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#f8fafc')
      .borderRadius(12)
      .border({ width: 1, color: '#e2e8f0' })

      Text('提示：关闭系统「无线调试」开关后，Swai 会在切回前台或执行命令时自动识别断连并重新引导。')
        .fontSize(11)
        .fontColor('#64748b')
        .lineHeight(17)
        .width('100%')

      Row({ space: 10 }) {
        Button('验证 uid 2000', { type: ButtonType.Normal })
          .fontSize(13)
          .height(38)
          .layoutWeight(1)
          .borderRadius(10)
          .backgroundColor('#f0f9ff')
          .fontColor('#0284c7')
          .border({ width: 1, color: '#bae6fd' })
          .enabled(!this.isBusy)
          .onClick(() => {
            if (this.onVerifyUid) {
              this.onVerifyUid();
            }
          })

        Button('断开连接', { type: ButtonType.Normal })
          .fontSize(13)
          .height(38)
          .layoutWeight(1)
          .borderRadius(10)
          .backgroundColor('#fef2f2')
          .fontColor('#dc2626')
          .border({ width: 1, color: '#fecaca' })
          .enabled(!this.isBusy)
          .onClick(() => {
            if (this.onDisconnect) {
              this.onDisconnect();
            }
          })
      }
      .width('100%')

      Button('完成', { type: ButtonType.Normal })
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .height(40)
        .width('100%')
        .borderRadius(10)
        .backgroundColor('#0284c7')
        .fontColor('#ffffff')
        .onClick(() => {
          if (this.onClose) {
            this.onClose();
          }
        })
    }
    .width('100%')
  }

  @Builder
  buildSetupWizardBody() {
    Column({ space: 10 }) {
      // Step 1: Collapsible Developer Mode activation
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          this.buildStepBadge('1', false)
          Text('激活开发者模式（已开启可跳过）')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1e293b')
            .layoutWeight(1)
          Text(this.step1Expanded ? '收起 ▲' : '查看步骤 ▼')
            .fontSize(11)
            .fontColor('#0284c7')
        }
        .width('100%')
        .onClick(() => {
          this.step1Expanded = !this.step1Expanded;
        })

        if (this.step1Expanded) {
          Text('打开系统「设置 → 关于本机」，连续点击「版本号 / HarmonyOS 版本」7 次，按提示输入锁屏密码即可激活「开发者选项」。')
            .fontSize(12)
            .fontColor('#475569')
            .lineHeight(18)
            .width('100%')
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#f8fafc')
      .borderRadius(12)
      .border({ width: 1, color: '#e2e8f0' })

      // Step 2: Enable Wireless Debugging & jump to Settings
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          this.buildStepBadge('2', this.phase === 'not_enabled')
          Text('打开系统「无线调试」')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1e293b')
            .layoutWeight(1)
        }
        .width('100%')

        Text('进入「设置 → 系统 → 开发者选项」，找到并打开「无线调试」。开启通常需先连接 Wi-Fi；开启后切回 Swai 将自动复检。')
          .fontSize(12)
          .fontColor('#475569')
          .lineHeight(18)
          .width('100%')

        Button('前往系统设置 ↗', { type: ButtonType.Normal })
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .height(38)
          .width('100%')
          .borderRadius(10)
          .backgroundColor('#f0f9ff')
          .fontColor('#0284c7')
          .border({ width: 1, color: '#bae6fd' })
          .onClick(() => {
            if (this.onOpenSettings) {
              this.onOpenSettings();
            }
          })
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#f8fafc')
      .borderRadius(12)
      .border({ width: 1, color: '#e2e8f0' })

      // Step 3: Auto-detect + Always Allow + Collapsible manual fallback
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          this.buildStepBadge(
            '3',
            this.phase === 'awaiting_auth' || this.phase === 'auth_rejected' || this.phase === 'need_port'
          )
          Text('自动检测并允许调试授权')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1e293b')
            .layoutWeight(1)
        }
        .width('100%')

        Text('点击下方按钮自动查找本机调试端口。系统弹出「允许无线调试吗」时请勾选「始终允许」。')
          .fontSize(12)
          .fontColor('#475569')
          .lineHeight(18)
          .width('100%')

        Button(
          this.phase === 'awaiting_auth'
            ? '等待系统授权中...'
            : ((this.isBusy || this.phase === 'checking') ? '正在检测并连接...' : '立即检测并连接'),
          { type: ButtonType.Normal }
        )
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .height(40)
          .width('100%')
          .borderRadius(10)
          .backgroundColor('#0284c7')
          .fontColor('#ffffff')
          .enabled(!this.isBusy && this.phase !== 'checking')
          .onClick(() => {
            if (this.onAutoDetect) {
              this.onAutoDetect();
            }
          })

        // Collapsible manual port fallback
        Row() {
          Text(this.manualExpanded ? '▾ 收起手动输入端口' : '▸ 没检测到？手动输入端口号')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#0284c7')
        }
        .width('100%')
        .padding({ top: 4, bottom: 2 })
        .onClick(() => {
          this.manualExpanded = !this.manualExpanded;
        })

        if (this.manualExpanded) {
          Column({ space: 8 }) {
            Text('请在「开发者选项 → 无线调试」页面查看「IP 地址和端口」，把冒号后的 5 位端口号填到下方：')
              .fontSize(11)
              .fontColor('#64748b')
              .lineHeight(16)
              .width('100%')

            Row({ space: 8 }) {
              TextInput({ text: this.hostInput, placeholder: '127.0.0.1' })
                .height(36)
                .fontSize(13)
                .layoutWeight(1)
                .backgroundColor('#ffffff')
                .borderRadius(8)
                .border({ width: 1, color: '#cbd5e1' })
                .onChange((value: string) => {
                  this.hostInput = value;
                })

              TextInput({ text: this.portInput, placeholder: '5 位端口号' })
                .type(InputType.Number)
                .height(36)
                .fontSize(13)
                .layoutWeight(1)
                .backgroundColor('#ffffff')
                .borderRadius(8)
                .border({ width: 1, color: '#cbd5e1' })
                .onChange((value: string) => {
                  this.portInput = value;
                  this.portErrorText = '';
                })
            }
            .width('100%')

            if (this.portErrorText.length > 0) {
              Text(this.portErrorText)
                .fontSize(11)
                .fontColor('#dc2626')
                .width('100%')
            }

            Button('使用该端口连接', { type: ButtonType.Normal })
              .fontSize(13)
              .height(36)
              .width('100%')
              .borderRadius(8)
              .backgroundColor('#0f766e')
              .fontColor('#ffffff')
              .enabled(!this.isBusy)
              .onClick(() => {
                this.handleManualSubmit();
              })
          }
          .width('100%')
          .padding(10)
          .backgroundColor('#ffffff')
          .borderRadius(10)
          .border({ width: 1, color: '#e2e8f0' })
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#f8fafc')
      .borderRadius(12)
      .border({ width: 1, color: '#e2e8f0' })

      // Step 4: Connectivity verification preview
      Row({ space: 8 }) {
        this.buildStepBadge('4', false)
        Column({ space: 2 }) {
          Text('自动校验连通性 (uid 2000)')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1e293b')
          Text('连接成功后自动执行 id 验证，确认即可开始跨应用自动化与 Shell 终端。')
            .fontSize(11)
            .fontColor('#64748b')
            .lineHeight(16)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#f8fafc')
      .borderRadius(12)
      .border({ width: 1, color: '#e2e8f0' })
      .alignItems(VerticalAlign.Top)

      // Optional diagnostic error details
      if (this.lastError.length > 0) {
        Column({ space: 4 }) {
          Text(this.showDiagnosticDetail ? '▾ 隐藏诊断信息' : '▸ 查看最近探测诊断信息')
            .fontSize(11)
            .fontColor('#64748b')
            .onClick(() => {
              this.showDiagnosticDetail = !this.showDiagnosticDetail;
            })
          if (this.showDiagnosticDetail) {
            Text(this.lastError)
              .fontSize(11)
              .fontFamily('monospace')
              .fontColor('#475569')
              .width('100%')
              .padding(8)
              .backgroundColor('#f1f5f9')
              .borderRadius(8)
              .copyOption(CopyOptions.LocalDevice)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      Button('暂不配置，先体验对话与浏览器', { type: ButtonType.Normal })
        .fontSize(12)
        .height(36)
        .width('100%')
        .borderRadius(10)
        .backgroundColor('#f1f5f9')
        .fontColor('#475569')
        .onClick(() => {
          if (this.onClose) {
            this.onClose();
          }
        })
    }
    .width('100%')
  }

  @Builder
  buildStepBadge(numText: string, active: boolean) {
    Text(numText)
      .fontSize(11)
      .fontWeight(FontWeight.Bold)
      .fontColor('#ffffff')
      .textAlign(TextAlign.Center)
      .width(20)
      .height(20)
      .borderRadius(10)
      .backgroundColor(active ? '#0284c7' : '#64748b')
  }

  @Builder
  buildInfoRow(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(12)
        .fontColor('#64748b')
      Text(value)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor('#0f172a')
        .textAlign(TextAlign.End)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}
