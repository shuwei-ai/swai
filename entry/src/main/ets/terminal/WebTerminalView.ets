/*
 * WebTerminalView: High-performance xterm.js Web Terminal View for Swai
 * Integrates harmoninux/HiSH modern web terminal with virtual keys,
 * ANSI coloring, gesture-scrolling, and real-time uid 2000 shell streaming.
 */
import webview from '@ohos.web.webview';
import hilog from '@ohos.hilog';
import promptAction from '@ohos.promptAction';
import pasteboard from '@ohos.pasteboard';
import {
  applyVirtualKeyModifiers,
  FunctionKeySequences,
  getVirtualKeyMetrics,
  NormalKeySequences,
  VirtualKeyMetrics
} from './TerminalVirtualKeys';
import { TerminalController } from './TerminalController';

const DOMAIN = 0x3300;
const TAG = 'WebTerminalView';

class TerminalNativeProxy {
  private view: WebTerminalView;

  constructor(view: WebTerminalView) {
    this.view = view;
  }

  sendInput(data: string): void {
    this.view.onTerminalInput(data);
  }

  resize(cols: number, rows: number): void {
    this.view.onTerminalResize(cols, rows);
  }

  load(): void {
    this.view.onTerminalLoaded();
  }

  getFontSize(): number {
    return 13;
  }

  getFontFamily(): string {
    return 'Default';
  }

  getCursorShape(): string {
    return 'block';
  }

  getCursorBlink(): boolean {
    return true;
  }

  getLigatures(): boolean {
    return false;
  }

  getItalic(): boolean {
    return false;
  }

  getBackgroundColor(): string {
    return '#0b0f19';
  }

  getBackgroundImage(): string {
    return '';
  }

  getBackgroundBlur(): number {
    return 0;
  }

  getUserFonts(): string {
    return '[]';
  }

  setApplicationMode(mode: boolean): void {
    this.view.applicationMode = mode;
  }

  onAvailableFontsDetected(fontsJson: string): void {
    hilog.debug(DOMAIN, TAG, 'Fonts detected: %{public}s', fontsJson);
  }
}

@Component
export struct WebTerminalView {
  @Prop isConnected: boolean = false;
  @State ctrlPressed: boolean = false;
  @State shiftPressed: boolean = false;
  @State fnPressed: boolean = false;
  @State showVirtualKeys: boolean = true;
  @State cols: number = 80;
  @State rows: number = 24;

  public applicationMode: boolean = false;
  private webviewController: webview.WebviewController = new webview.WebviewController();
  private nativeProxy: TerminalNativeProxy = new TerminalNativeProxy(this);
  private terminalController: TerminalController = TerminalController.getInstance();
  private vKeyMetrics: VirtualKeyMetrics = getVirtualKeyMetrics();

  aboutToAppear(): void {
    this.terminalController.registerCallbacks(
      (b64: string, appMode?: boolean) => {
        this.writeBase64ToWeb(b64, appMode ?? this.applicationMode);
      },
      () => {
        this.clearWebScreen();
      }
    );
  }

  aboutToDisappear(): void {
    this.terminalController.unregisterCallbacks();
  }

  public onTerminalInput(data: string): void {
    const mod = applyVirtualKeyModifiers(data, this.ctrlPressed, this.shiftPressed);
    if (mod.shouldResetCtrl) {
      this.ctrlPressed = false;
    }
    this.terminalController.handleInput(mod.data);
  }

  public onTerminalResize(cols: number, rows: number): void {
    this.cols = cols;
    this.rows = rows;
  }

  public onTerminalLoaded(): void {
    hilog.info(DOMAIN, TAG, 'xterm.js Web Terminal initialized successfully');
    this.terminalController.printBannerAndPrompt();
  }

  private writeBase64ToWeb(base64: string, appMode: boolean): void {
    try {
      this.webviewController.runJavaScript(`exports.writeBase64("${base64}", ${appMode})`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'writeBase64ToWeb error: %{public}s', JSON.stringify(e));
    }
  }

  private clearWebScreen(): void {
    try {
      this.webviewController.runJavaScript('exports.clearScreen()');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clearWebScreen error: %{public}s', JSON.stringify(e));
    }
  }

  private sendVirtualKey(value: string, appCode?: string): void {
    let keyData = value;
    if (this.applicationMode && appCode) {
      keyData = appCode;
    }
    this.onTerminalInput(keyData);
  }

  @Builder
  buildVKey(name: string, value: string, appCode?: string, widthScale: number = 1) {
    Button(name)
      .height(this.vKeyMetrics.height)
      .width(this.vKeyMetrics.width * widthScale)
      .borderRadius(this.vKeyMetrics.radius)
      .fontSize(this.vKeyMetrics.fontSize)
      .fontColor('#e2e8f0')
      .backgroundColor('#1e293b')
      .margin(this.vKeyMetrics.margin)
      .padding({ left: this.vKeyMetrics.padding, right: this.vKeyMetrics.padding })
      .onClick(() => {
        this.sendVirtualKey(value, appCode);
      })
  }

  @Builder
  buildToggleKey(name: string, isActive: boolean, onClick: () => void) {
    Button(name)
      .height(this.vKeyMetrics.height)
      .width(this.vKeyMetrics.width)
      .borderRadius(this.vKeyMetrics.radius)
      .fontSize(this.vKeyMetrics.fontSize)
      .fontWeight(FontWeight.Bold)
      .fontColor(isActive ? '#ffffff' : '#94a3b8')
      .backgroundColor(isActive ? '#0284c7' : '#1e293b')
      .margin(this.vKeyMetrics.margin)
      .padding({ left: this.vKeyMetrics.padding, right: this.vKeyMetrics.padding })
      .onClick(() => onClick())
  }

  @Builder
  buildVirtualKeysPanel() {
    Column({ space: 2 }) {
      if (this.fnPressed) {
        // Row 1: Function keys F1-F6
        Row() {
          this.buildToggleKey('FN', this.fnPressed, () => { this.fnPressed = !this.fnPressed; });
          this.buildVKey('F1', FunctionKeySequences.F1);
          this.buildVKey('F2', FunctionKeySequences.F2);
          this.buildVKey('F3', FunctionKeySequences.F3);
          Blank();
          this.buildVKey('F4', FunctionKeySequences.F4);
          this.buildVKey('F5', FunctionKeySequences.F5);
          this.buildVKey('F6', FunctionKeySequences.F6);
        }
        .width('100%')

        // Row 2: Function keys F7-F12 + toggle
        Row() {
          this.buildVKey('F7', FunctionKeySequences.F7);
          this.buildVKey('F8', FunctionKeySequences.F8);
          this.buildVKey('F9', FunctionKeySequences.F9);
          Blank();
          this.buildVKey('F10', FunctionKeySequences.F10);
          this.buildVKey('F11', FunctionKeySequences.F11);
          this.buildVKey('F12', FunctionKeySequences.F12);
          Button('▼')
            .height(this.vKeyMetrics.height)
            .width(this.vKeyMetrics.width)
            .borderRadius(this.vKeyMetrics.radius)
            .fontSize(this.vKeyMetrics.fontSize)
            .fontColor('#94a3b8')
            .backgroundColor('#1e293b')
            .margin(this.vKeyMetrics.margin)
            .onClick(() => { this.showVirtualKeys = false; });
        }
        .width('100%')
      } else {
        // Row 1: ESC, FN, '/', '-', '|', '~', UP, Ctrl+C
        Row() {
          this.buildVKey('ESC', NormalKeySequences.ESC);
          this.buildToggleKey('FN', this.fnPressed, () => { this.fnPressed = !this.fnPressed; });
          this.buildVKey('/', '/');
          this.buildVKey('-', '-');
          this.buildVKey('|', '|');
          this.buildVKey('~', '~');
          Blank();
          this.buildVKey('↑', NormalKeySequences.UP, NormalKeySequences.UP_APP);
          Button('^C')
            .height(this.vKeyMetrics.height)
            .width(this.vKeyMetrics.width)
            .borderRadius(this.vKeyMetrics.radius)
            .fontSize(this.vKeyMetrics.fontSize)
            .fontColor('#fca5a5')
            .backgroundColor('#7f1d1d')
            .margin(this.vKeyMetrics.margin)
            .onClick(() => {
              this.terminalController.abortCurrentCommand();
            });
        }
        .width('100%')

        // Row 2: TAB, CTRL, HOME, END, LEFT, DOWN, RIGHT, Enter, Hide
        Row() {
          this.buildVKey('TAB', NormalKeySequences.TAB);
          this.buildToggleKey('CTRL', this.ctrlPressed, () => { this.ctrlPressed = !this.ctrlPressed; });
          this.buildVKey('HOME', NormalKeySequences.HOME);
          this.buildVKey('END', NormalKeySequences.END);
          Blank();
          this.buildVKey('←', NormalKeySequences.LEFT, NormalKeySequences.LEFT_APP);
          this.buildVKey('↓', NormalKeySequences.DOWN, NormalKeySequences.DOWN_APP);
          this.buildVKey('→', NormalKeySequences.RIGHT, NormalKeySequences.RIGHT_APP);
          Button('↵')
            .height(this.vKeyMetrics.height)
            .width(this.vKeyMetrics.width)
            .borderRadius(this.vKeyMetrics.radius)
            .fontSize(this.vKeyMetrics.fontSize)
            .fontColor('#ffffff')
            .backgroundColor('#0284c7')
            .margin(this.vKeyMetrics.margin)
            .onClick(() => {
              this.sendVirtualKey('\r');
            });
          Button('▼')
            .height(this.vKeyMetrics.height)
            .width(28)
            .borderRadius(this.vKeyMetrics.radius)
            .fontSize(10)
            .fontColor('#64748b')
            .backgroundColor('#1e293b')
            .margin(this.vKeyMetrics.margin)
            .onClick(() => { this.showVirtualKeys = false; });
        }
        .width('100%')
      }
    }
    .padding({ left: 4, right: 4, top: 2, bottom: 4 })
    .backgroundColor('#0f172a')
    .borderRadius({ bottomLeft: 8, bottomRight: 8 })
  }

  build() {
    Column() {
      // 1. Terminal Web Viewport (xterm.js)
      Web({
        src: $rawfile('term/term.html'),
        controller: this.webviewController
      })
        .javaScriptProxy({
          object: this.nativeProxy,
          name: 'native',
          methodList: [
            'sendInput', 'resize', 'load',
            'getFontSize', 'getFontFamily',
            'getCursorShape', 'getCursorBlink',
            'getLigatures', 'getItalic',
            'getBackgroundColor', 'getBackgroundImage', 'getBackgroundBlur',
            'getUserFonts',
            'setApplicationMode',
            'onAvailableFontsDetected'
          ],
          controller: this.webviewController
        })
        .backgroundColor('#0b0f19')
        .layoutWeight(1)
        .width('100%')

      // 2. Virtual Keys Bar or Expand Button
      if (this.showVirtualKeys) {
        this.buildVirtualKeysPanel();
      } else {
        Row() {
          Blank();
          Button('▲ 展开虚拟按键')
            .height(22)
            .fontSize(11)
            .fontColor('#94a3b8')
            .backgroundColor('#1e293b')
            .borderRadius(4)
            .margin({ top: 2, bottom: 2, right: 8 })
            .onClick(() => { this.showVirtualKeys = true; });
        }
        .width('100%')
        .backgroundColor('#0f172a')
      }
    }
    .width('100%')
    .height('100%')
    .borderRadius(8)
    .clip(true)
    .border({ width: 1, color: '#1e293b' })
  }
}
