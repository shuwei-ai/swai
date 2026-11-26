#!/usr/bin/env node
/**
 * Builds entry/src/main/resources/rawfile/dsh-runtime.zip from @deepseek-ai/dsh.
 *
 * Usage:
 *   node tools/build_dsh_runtime.mjs [version]
 *
 * Defaults to version 0.2.3-alpha.2.
 * Strips dev-only artifacts (*.map, *.d.ts, src/, docs/) and non-ARM64-Linux
 * native prebuilds so the embedded OpenHarmony rawfile stays compact.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');
const BRIDGE_SRC_DIR = path.join(REPO_ROOT, 'entry/src/main/resources/rawfile/dsh_bridge');
const OUT_ZIP = path.join(REPO_ROOT, 'entry/src/main/resources/rawfile/dsh-runtime.zip');

const dshVersion = process.argv[2] || '0.2.3-alpha.2';

function rmRf(target) {
  fs.rmSync(target, { recursive: true, force: true });
}

function pruneNodeModules(nodeModulesDir) {
  let removedFiles = 0;
  let removedBytes = 0;

  const stripExts = ['.map', '.d.ts', '.d.mts', '.d.cts'];

  function walkAndPrune(dir) {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walkAndPrune(fullPath);
      } else if (entry.isFile() && stripExts.some((ext) => entry.name.endsWith(ext))) {
        try {
          const st = fs.statSync(fullPath);
          removedBytes += st.size;
          removedFiles++;
          fs.unlinkSync(fullPath);
        } catch {
          // ignore
        }
      }
    }
  }

  // Remove dev-only src/ and docs/ directories in @deepseek-ai/*
  const dshScopeDir = path.join(nodeModulesDir, '@deepseek-ai');
  if (fs.existsSync(dshScopeDir)) {
    for (const pkg of fs.readdirSync(dshScopeDir)) {
      const pkgDir = path.join(dshScopeDir, pkg);
      for (const sub of ['src', 'docs']) {
        const subDir = path.join(pkgDir, sub);
        if (fs.existsSync(subDir)) {
          rmRf(subDir);
        }
      }
    }
  }

  // Remove non-ARM64-Linux native prebuilds
  rmRf(path.join(nodeModulesDir, 'node-pty/third_party/conpty'));
  for (const dirName of ['win32-arm64', 'win32-x64', 'darwin-arm64', 'darwin-x64', 'linux-x64']) {
    rmRf(path.join(nodeModulesDir, 'node-pty/prebuilds', dirName));
  }
  for (const dirName of ['win32-arm64', 'win32-x64', 'darwin-arm64', 'darwin-x64']) {
    rmRf(path.join(nodeModulesDir, '@deepseek-ai/libreoffice-kit/frame-forwarding/prebuilds', dirName));
  }

  walkAndPrune(nodeModulesDir);
  return { removedFiles, removedBytes };
}

function measureTree(dir) {
  let files = 0;
  let bytes = 0;
  function walk(cur) {
    for (const entry of fs.readdirSync(cur, { withFileTypes: true })) {
      const full = path.join(cur, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (entry.isFile()) {
        files++;
        bytes += fs.statSync(full).size;
      }
    }
  }
  walk(dir);
  return { files, bytes };
}

function main() {
  const staging = fs.mkdtempSync(path.join(os.tmpdir(), 'swai-dsh-runtime-'));
  console.log(`[build_dsh_runtime] Staging @deepseek-ai/dsh@${dshVersion} in ${staging}`);

  try {
    const pkgJson = {
      dependencies: {
        '@deepseek-ai/dsh': dshVersion,
        debug: '4.4.3',
        ms: '2.1.3',
        zod: '4.4.3',
      },
    };
    fs.writeFileSync(path.join(staging, 'package.json'), JSON.stringify(pkgJson, null, 2) + '\n');

    console.log('[build_dsh_runtime] Running npm install --ignore-scripts --omit=optional ...');
    execFileSync(
      'npm',
      ['install', '--no-audit', '--no-fund', '--ignore-scripts', '--omit=optional'],
      { cwd: staging, stdio: 'inherit' }
    );

    // Copy bridge scripts
    const bridgeDest = path.join(staging, 'bridge');
    fs.mkdirSync(bridgeDest, { recursive: true });
    if (fs.existsSync(BRIDGE_SRC_DIR)) {
      for (const name of fs.readdirSync(BRIDGE_SRC_DIR)) {
        const src = path.join(BRIDGE_SRC_DIR, name);
        if (fs.statSync(src).isFile()) {
          fs.copyFileSync(src, path.join(bridgeDest, name));
        }
      }
    }
    const pihaAliases = [
      ['swai-tools.mjs', 'piha-tools.mjs'],
      ['swai-host.patch.json', 'piha-host.patch.json'],
      ['swai-mcp-server.mjs', 'piha-mcp-server.mjs'],
    ];
    for (const [srcName, aliasName] of pihaAliases) {
      const srcPath = path.join(bridgeDest, srcName);
      if (fs.existsSync(srcPath)) {
        fs.copyFileSync(srcPath, path.join(bridgeDest, aliasName));
      }
    }
    for (const topFile of ['cdp-driver.mjs', 'wechat-formatter.mjs', 'wechat-poster.mjs']) {
      const srcPath = path.join(bridgeDest, topFile);
      if (fs.existsSync(srcPath)) {
        fs.copyFileSync(srcPath, path.join(staging, topFile));
      }
    }

    // Pre-stub flock.js for OpenHarmony compatibility
    const flockPath = path.join(staging, 'node_modules/@deepseek-ai/node-addon-system/lib/flock.js');
    if (fs.existsSync(flockPath)) {
      fs.writeFileSync(
        flockPath,
        'export function tryLockExclusive(_fd) { return Promise.resolve(); }\n' +
          'export const __esModule = true;\n' +
          'export default { tryLockExclusive };\n'
      );
      console.log('[build_dsh_runtime] Pre-stubbed node-addon-system/lib/flock.js');
    }

    // Prune dev-only artifacts & non-target native binaries
    const { removedFiles, removedBytes } = pruneNodeModules(path.join(staging, 'node_modules'));
    console.log(
      `[build_dsh_runtime] Pruned ${removedFiles} dev/map/dts files (${(removedBytes / 1048576).toFixed(1)} MB) + src/docs/foreign prebuilds`
    );

    const stats = measureTree(staging);
    console.log(
      `[build_dsh_runtime] Final staging tree: ${stats.files} files, ${(stats.bytes / 1048576).toFixed(1)} MB uncompressed`
    );

    fs.mkdirSync(path.dirname(OUT_ZIP), { recursive: true });
    rmRf(OUT_ZIP);
    console.log(`[build_dsh_runtime] Compressing to ${OUT_ZIP} ...`);
    execFileSync('zip', ['-qry', OUT_ZIP, '.'], { cwd: staging, stdio: 'inherit' });

    const zipSize = fs.statSync(OUT_ZIP).size;
    console.log(`[build_dsh_runtime] Done: ${OUT_ZIP} (${(zipSize / 1048576).toFixed(2)} MB)`);
  } finally {
    rmRf(staging);
  }
}

main();
