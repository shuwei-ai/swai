/*
 * TerminalEnhancement.test.ets
 * Unit tests for HiSH terminal integration: TerminalVirtualKeys and TerminalController.
 */
import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import util from '@ohos.util';
import {
  applyVirtualKeyModifiers,
  FunctionKeySequences,
  getVirtualKeyMetrics,
  NormalKeySequences
} from '../main/ets/terminal/TerminalVirtualKeys';
import { TerminalController } from '../main/ets/terminal/TerminalController';

export default function terminalEnhancementTest() {
  describe('TerminalEnhancementTest', () => {

    it('test_virtual_key_metrics', 0, () => {
      const phoneMetrics = getVirtualKeyMetrics('phone');
      expect(phoneMetrics.height).assertEqual(28);
      expect(phoneMetrics.margin).assertEqual(1);
      expect(phoneMetrics.width).assertEqual(40);

      const defaultMetrics = getVirtualKeyMetrics('tablet');
      expect(defaultMetrics.height).assertEqual(28);
      expect(defaultMetrics.margin).assertEqual(2);
      expect(defaultMetrics.width).assertEqual(56);
    });

    it('test_normal_key_sequences', 0, () => {
      expect(NormalKeySequences.ESC).assertEqual('\x1b');
      expect(NormalKeySequences.TAB).assertEqual('\t');
      expect(NormalKeySequences.UP).assertEqual('\x1b[A');
      expect(NormalKeySequences.DOWN).assertEqual('\x1b[B');
      expect(NormalKeySequences.LEFT).assertEqual('\x1b[D');
      expect(NormalKeySequences.RIGHT).assertEqual('\x1b[C');
      expect(NormalKeySequences.HOME).assertEqual('\x1b[H');
      expect(NormalKeySequences.END).assertEqual('\x1b[F');
    });

    it('test_function_key_sequences', 0, () => {
      expect(FunctionKeySequences.F1).assertEqual('\x1bOP');
      expect(FunctionKeySequences.F2).assertEqual('\x1bOQ');
      expect(FunctionKeySequences.F5).assertEqual('\x1b[15~');
      expect(FunctionKeySequences.F12).assertEqual('\x1b[24~');
    });

    it('test_apply_virtual_key_modifiers_ctrl_c', 0, () => {
      const res = applyVirtualKeyModifiers('c', true, false);
      // Ctrl+C in ASCII is 3 (\x03)
      expect(res.data).assertEqual('\x03');
      expect(res.ctrlConverted).assertTrue();
      expect(res.shouldResetCtrl).assertTrue();
    });

    it('test_apply_virtual_key_modifiers_ctrl_z', 0, () => {
      const res = applyVirtualKeyModifiers('z', true, false);
      // Ctrl+Z in ASCII is 26 (\x1a)
      expect(res.data).assertEqual('\x1a');
      expect(res.ctrlConverted).assertTrue();
      expect(res.shouldResetCtrl).assertTrue();
    });

    it('test_apply_virtual_key_modifiers_shift', 0, () => {
      const res = applyVirtualKeyModifiers('k', false, true);
      expect(res.data).assertEqual('K');
      expect(res.shiftConverted).assertTrue();
      expect(res.shouldResetCtrl).assertFalse();
    });

    it('test_apply_virtual_key_modifiers_passthrough', 0, () => {
      const res = applyVirtualKeyModifiers('hello', false, false);
      expect(res.data).assertEqual('hello');
      expect(res.ctrlConverted).assertFalse();
      expect(res.shiftConverted).assertFalse();
    });

    it('test_terminal_controller_state_and_prompt', 0, () => {
      const controller = TerminalController.getInstance();
      expect(controller.getBusy()).assertFalse();
      expect(controller.PROMPT.indexOf('swai:/ $') >= 0).assertTrue();

      let receivedB64 = '';
      controller.registerCallbacks((b64: string) => {
        receivedB64 += b64;
      }, () => {});

      controller.writeRaw('test');
      expect(receivedB64.length > 0).assertTrue();

      const decoded = new util.TextDecoder('utf-8').decodeToString(
        new util.Base64Helper().decodeSync(receivedB64)
      );
      expect(decoded).assertEqual('test');

      controller.unregisterCallbacks();
    });

    it('test_terminal_controller_interactive_typing', 0, () => {
      const controller = TerminalController.getInstance();
      let outputBuffer = '';

      controller.registerCallbacks((b64: string) => {
        const text = new util.TextDecoder('utf-8').decodeToString(
          new util.Base64Helper().decodeSync(b64)
        );
        outputBuffer += text;
      }, () => {
        outputBuffer = '';
      });

      // Type "ls"
      controller.handleInput('l');
      controller.handleInput('s');
      expect(outputBuffer).assertEqual('ls');

      // Backspace
      controller.handleInput('\x7f');
      expect(outputBuffer.endsWith('\b \b')).assertTrue();

      // Ctrl+C
      controller.handleInput('\x03');
      expect(outputBuffer.indexOf('^C') >= 0).assertTrue();

      controller.unregisterCallbacks();
    });

  });
}
