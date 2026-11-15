/*
 * TerminalController: Manages terminal state, line-buffer editing, history,
 * ANSI stream dispatching, and command execution via BridgeController (uid 2000).
 * Adapted from harmoninux/HiSH terminal patterns for Swai Shell.
 */
import util from '@ohos.util';
import hilog from '@ohos.hilog';
import { BridgeController } from '../common/BridgeController';

const DOMAIN = 0x3300;
const TAG = 'TerminalController';

export type TerminalOutputCallback = (base64Data: string, applicationMode?: boolean) => void;
export type TerminalClearCallback = () => void;

export class TerminalController {
  private static instance: TerminalController | null = null;

  private outputCallback: TerminalOutputCallback | null = null;
  private clearCallback: TerminalClearCallback | null = null;

  private inputBuffer: string = '';
  private history: string[] = [];
  private historyIndex: number = -1;
  private isBusy: boolean = false;
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private base64Helper: util.Base64Helper = new util.Base64Helper();

  public readonly PROMPT: string = '\x1b[1;32mswai:/ $\x1b[0m ';

  public static getInstance(): TerminalController {
    if (!TerminalController.instance) {
      TerminalController.instance = new TerminalController();
    }
    return TerminalController.instance;
  }

  public registerCallbacks(onOutput: TerminalOutputCallback, onClear: TerminalClearCallback): void {
    this.outputCallback = onOutput;
    this.clearCallback = onClear;
  }

  public unregisterCallbacks(): void {
    this.outputCallback = null;
    this.clearCallback = null;
  }

  public writeRaw(text: string): void {
    if (!this.outputCallback) {
      return;
    }
    try {
      const bytes = this.encoder.encodeInto(text);
      const b64 = this.base64Helper.encodeToStringSync(bytes);
      this.outputCallback(b64, false);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'writeRaw failed: %{public}s', JSON.stringify(e));
    }
  }

  public printBannerAndPrompt(): void {
    this.writeRaw(
      '\x1b[1;36m=== Swai Native Terminal (uid 2000 / shell) ===\x1b[0m\r\n' +
      '\x1b[90mHiSH xterm.js engine with ANSI rendering & virtual keys active.\x1b[0m\r\n' +
      '\x1b[90mType shell commands or tap quick buttons below.\x1b[0m\r\n\r\n' +
      this.PROMPT
    );
  }

  public getBusy(): boolean {
    return this.isBusy;
  }

  public abortCurrentCommand(): void {
    if (this.isBusy) {
      BridgeController.getInstance().abort();
      this.writeRaw('^C\r\n');
      this.isBusy = false;
      this.inputBuffer = '';
      this.writeRaw(this.PROMPT);
    } else if (this.inputBuffer.length > 0) {
      this.writeRaw('^C\r\n' + this.PROMPT);
      this.inputBuffer = '';
    }
  }

  public clearScreen(): void {
    if (this.clearCallback) {
      this.clearCallback();
    } else {
      this.writeRaw('\x1b[2J\x1b[H');
    }
    this.writeRaw(this.PROMPT + this.inputBuffer);
  }

  /**
   * Directly executes a command as if entered in the terminal.
   */
  public async runCommand(cmd: string): Promise<void> {
    const trimmed = cmd.trim();
    if (this.isBusy) {
      hilog.warn(DOMAIN, TAG, 'Terminal is currently busy executing another command');
      return;
    }

    // Print command to terminal
    this.writeRaw(trimmed + '\r\n');
    this.inputBuffer = '';
    await this.dispatchExecution(trimmed);
  }

  /**
   * Handles interactive raw keystroke/data coming from xterm.js onData or Virtual Keys.
   */
  public handleInput(data: string): void {
    // 1. Ctrl+C (\x03)
    if (data === '\x03') {
      this.abortCurrentCommand();
      return;
    }

    // If currently running a command, we don't accept normal typing
    if (this.isBusy) {
      return;
    }

    // 2. Enter (\r or \n)
    if (data === '\r' || data === '\n') {
      this.writeRaw('\r\n');
      const cmd = this.inputBuffer.trim();
      this.inputBuffer = '';
      this.historyIndex = -1;

      if (cmd.length === 0) {
        this.writeRaw(this.PROMPT);
        return;
      }

      // Builtin: clear
      if (cmd === 'clear') {
        this.clearScreen();
        return;
      }

      this.recordHistory(cmd);
      void this.dispatchExecution(cmd);
      return;
    }

    // 3. Backspace (\x7f or \b)
    if (data === '\x7f' || data === '\b') {
      if (this.inputBuffer.length > 0) {
        this.inputBuffer = this.inputBuffer.slice(0, -1);
        this.writeRaw('\b \b');
      }
      return;
    }

    // 4. Ctrl+L (\x0c) -> Clear
    if (data === '\x0c') {
      this.clearScreen();
      return;
    }

    // 5. Arrow Up (\x1b[A or \x1bOA) -> Previous History
    if (data === '\x1b[A' || data === '\x1bOA') {
      this.navigateHistory(-1);
      return;
    }

    // 6. Arrow Down (\x1b[B or \x1bOB) -> Next History
    if (data === '\x1b[B' || data === '\x1bOB') {
      this.navigateHistory(1);
      return;
    }

    // 7. Tab (\t)
    if (data === '\t') {
      // Simple 4-space tab
      this.inputBuffer += '    ';
      this.writeRaw('    ');
      return;
    }

    // 8. Normal characters
    for (let i = 0; i < data.length; i++) {
      const code = data.charCodeAt(i);
      // Printable characters
      if (code >= 32) {
        const ch = data.charAt(i);
        this.inputBuffer += ch;
        this.writeRaw(ch);
      }
    }
  }

  private recordHistory(cmd: string): void {
    if (this.history.length === 0 || this.history[this.history.length - 1] !== cmd) {
      this.history.push(cmd);
      if (this.history.length > 50) {
        this.history.shift();
      }
    }
  }

  private navigateHistory(direction: number): void {
    if (this.history.length === 0) {
      return;
    }

    if (direction < 0) {
      // Going back in history
      if (this.historyIndex === -1) {
        this.historyIndex = this.history.length - 1;
      } else if (this.historyIndex > 0) {
        this.historyIndex--;
      }
    } else {
      // Going forward in history
      if (this.historyIndex !== -1) {
        if (this.historyIndex < this.history.length - 1) {
          this.historyIndex++;
        } else {
          this.historyIndex = -1;
        }
      }
    }

    const targetCmd = this.historyIndex !== -1 ? this.history[this.historyIndex] : '';

    // Clear current line on screen
    let eraseSeq = '';
    for (let i = 0; i < this.inputBuffer.length; i++) {
      eraseSeq += '\b \b';
    }
    this.writeRaw(eraseSeq);

    // Apply target
    this.inputBuffer = targetCmd;
    this.writeRaw(targetCmd);
  }

  private async dispatchExecution(cmd: string): Promise<void> {
    this.isBusy = true;
    try {
      let lastEndedWithNewline = true;
      const res = await BridgeController.getInstance().execStream(
        cmd,
        (chunk: string) => {
          if (chunk.length > 0) {
            // Standardize \n to \r\n for xterm.js raw terminal compatibility
            const normalized = chunk.replace(/\r?\n/g, '\r\n');
            this.writeRaw(normalized);
            lastEndedWithNewline = chunk.endsWith('\n') || chunk.endsWith('\r');
          }
        },
        '',
        0 // No timeout; allow long running commands like top/ping
      );

      if (!lastEndedWithNewline) {
        this.writeRaw('\r\n');
      }

      if (res.exitCode !== 0 && res.error) {
        this.writeRaw(`\x1b[31m[exit ${res.exitCode}: ${res.error}]\x1b[0m\r\n`);
      }
    } catch (err) {
      this.writeRaw(`\x1b[31mError: ${err}\x1b[0m\r\n`);
    } finally {
      this.isBusy = false;
      this.writeRaw(this.PROMPT);
    }
  }
}
