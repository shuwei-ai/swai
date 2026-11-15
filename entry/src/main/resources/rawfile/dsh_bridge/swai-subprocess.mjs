/**
 * Swai Subprocess Replacement Plugin for DeepSeek Harness (DSH)
 * Routes subprocess requests in DSH to Swai's HDC shell.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import { dispatchSwaiTool } from './bridge-client.mjs';

export const name = 'swai-subprocess';
export const inject = ['process'];

export function apply(ctx) {
  // Override or wrap process.spawn if needed
  if (ctx.process && typeof ctx.process.on === 'function') {
    ctx.process.on('spawn', async (cmd, args) => {
      const fullCmd = [cmd, ...(args || [])].join(' ');
      const res = await dispatchSwaiTool('bash', {
        command: fullCmd,
        timeout: 30
      }, 35000);
      return res;
    });
  }
}
