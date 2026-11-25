/*
 * DeveloperDebugGuide.test.ets
 * Unit tests for HdcDebugState state transitions, port validation, key formatting, and UI copy mapping.
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  cloneDebugSnapshot,
  createInitialDebugSnapshot,
  formatPublicKeyFingerprint,
  getDebugPhaseSummary,
  isValidPortInput,
  mapConnectFailureToPhase,
  parsePortInput
} from '../main/ets/common/HdcDebugState';

export default function developerDebugGuideTest() {
  describe('DeveloperDebugGuideTest', () => {

    it('test_map_connect_failure_to_phase', 0, () => {
      expect(mapConnectFailureToPhase('auth_rejected', false)).assertEqual('auth_rejected');
      expect(mapConnectFailureToPhase('auth_rejected', true)).assertEqual('auth_rejected');
      expect(mapConnectFailureToPhase('auth_timeout', false)).assertEqual('auth_rejected');
      expect(mapConnectFailureToPhase('connect_timeout', false)).assertEqual('need_port');
      expect(mapConnectFailureToPhase('need_port', false)).assertEqual('need_port');
      expect(mapConnectFailureToPhase('not_running', false)).assertEqual('not_enabled');
      expect(mapConnectFailureToPhase('not_running', true)).assertEqual('need_port');
    });

    it('test_port_input_validation', 0, () => {
      expect(isValidPortInput('45661')).assertTrue();
      expect(isValidPortInput(' 8710 ')).assertTrue();
      expect(isValidPortInput('1')).assertTrue();
      expect(isValidPortInput('65535')).assertTrue();
      expect(parsePortInput(' 38421 ')).assertEqual(38421);

      expect(isValidPortInput('')).assertFalse();
      expect(isValidPortInput('0')).assertFalse();
      expect(isValidPortInput('65536')).assertFalse();
      expect(isValidPortInput('-1')).assertFalse();
      expect(isValidPortInput('123abc')).assertFalse();
      expect(isValidPortInput('12.34')).assertFalse();
      expect(parsePortInput('bad')).assertEqual(0);
    });

    it('test_format_public_key_fingerprint', 0, () => {
      expect(formatPublicKeyFingerprint('')).assertEqual('未生成');
      expect(formatPublicKeyFingerprint('   \n  ')).assertEqual('未生成');
      expect(formatPublicKeyFingerprint('SHORTKEY123456')).assertEqual('SHORTKEY123456');

      const samplePem =
        '-----BEGIN PUBLIC KEY-----\n' +
        'MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEA1234567890\n' +
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzEND9876543\n' +
        '-----END PUBLIC KEY-----\n';
      const fp = formatPublicKeyFingerprint(samplePem);
      expect(fp).assertEqual('MIIBojANBg...END9876543');
    });

    it('test_debug_phase_summary', 0, () => {
      const ready = getDebugPhaseSummary('connected', 51234);
      expect(ready.isReady).assertTrue();
      expect(ready.badgeText).assertEqual(':51234');
      expect(ready.headerText).assertEqual('开发者调试已就绪');

      const readyNoPort = getDebugPhaseSummary('connected', 0);
      expect(readyNoPort.isReady).assertTrue();
      expect(readyNoPort.badgeText).assertEqual('已就绪');

      const notEnabled = getDebugPhaseSummary('not_enabled', 0);
      expect(notEnabled.isReady).assertFalse();
      expect(notEnabled.badgeText).assertEqual('未开启');
      expect(notEnabled.actionText).assertEqual('去开启 ›');

      const checking = getDebugPhaseSummary('checking', 0);
      expect(checking.isReady).assertFalse();
      expect(checking.badgeText).assertEqual('检测中');

      const awaiting = getDebugPhaseSummary('awaiting_auth', 0);
      expect(awaiting.isReady).assertFalse();
      expect(awaiting.badgeText).assertEqual('待授权');

      const rejected = getDebugPhaseSummary('auth_rejected', 0);
      expect(rejected.isReady).assertFalse();
      expect(rejected.badgeText).assertEqual('待重试');

      const needPort = getDebugPhaseSummary('need_port', 0);
      expect(needPort.isReady).assertFalse();
      expect(needPort.badgeText).assertEqual('需配置');
    });

    it('test_snapshot_clone_isolation', 0, () => {
      const orig = createInitialDebugSnapshot();
      orig.phase = 'connected';
      orig.connected = true;
      orig.port = 51234;
      const copy = cloneDebugSnapshot(orig);
      copy.phase = 'not_enabled';
      copy.connected = false;
      copy.port = 0;

      expect(orig.phase).assertEqual('connected');
      expect(orig.connected).assertTrue();
      expect(orig.port).assertEqual(51234);
    });
  });
}
