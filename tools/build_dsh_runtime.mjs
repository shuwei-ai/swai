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
import { execFileSync, spawnSync } from 'node:child_process';
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

  const stripExts = ['.map', '.d.ts', '.d.mts', '.d.cts', '.tsbuildinfo', '.gyp', '.gypi', '.cc', '.cpp', '.c', '.h', '.hpp'];
  const stripDirNames = new Set(['docs', 'doc', 'test', 'tests', '__tests__', 'examples', 'example', '.github']);

  function hasCompiledSibling(pkgDir) {
    return ['lib', 'dist', 'build', 'v4', 'cjs', 'esm'].some((d) => fs.existsSync(path.join(pkgDir, d)));
  }

  function walkAndPrune(dir) {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    const isPkgRoot = fs.existsSync(path.join(dir, 'package.json'));
    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (isPkgRoot && stripDirNames.has(entry.name)) {
          rmRf(fullPath);
          removedFiles++;
          continue;
        }
        if (isPkgRoot && entry.name === 'src' && hasCompiledSibling(dir)) {
          rmRf(fullPath);
          removedFiles++;
          continue;
        }
        walkAndPrune(fullPath);
      } else if (entry.isFile()) {
        const lower = entry.name.toLowerCase();
        const isMarkdown = lower.endsWith('.md') && !lower.startsWith('license') && !lower.startsWith('notice');
        if (isMarkdown || stripExts.some((ext) => lower.endsWith(ext))) {
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
    try {
      if (dir !== nodeModulesDir && fs.readdirSync(dir).length === 0) {
        fs.rmdirSync(dir);
      }
    } catch {
      // ignore
    }
  }

  // Remove heavy/unsupported native & wasm packages (already disabled or bridged on HarmonyOS)
  const removePackages = [
    '@deepseek-ai/libreoffice-kit',
    '@deepseek-ai/libreoffice-kit-wasm',
    '@vscode/ripgrep',
    '@vscode/ripgrep-arm64',
    '@vscode/ripgrep-x64',
    'sharp',
    'koffi',
    'sherpa-onnx-node',
    'sherpa-onnx-linux-arm64',
    'sherpa-onnx-linux-x64',
    'sherpa-onnx-darwin-arm64',
    'sherpa-onnx-darwin-x64',
    'sherpa-onnx-win-x64',
    '@img',
    '@koromix',
    'node-pty/third_party/conpty',
  ];
  for (const pkg of removePackages) {
    rmRf(path.join(nodeModulesDir, pkg));
  }
  for (const dirName of ['win32-arm64', 'win32-x64', 'darwin-arm64', 'darwin-x64', 'linux-x64']) {
    rmRf(path.join(nodeModulesDir, 'node-pty/prebuilds', dirName));
  }

  walkAndPrune(nodeModulesDir);
  return { removedFiles, removedBytes };
}

function patchFrontendStaticCache(nodeModulesDir) {
  const staticPath = path.join(nodeModulesDir, '@deepseek-ai/dsh-host-frontend-static/lib/index.js');
  if (!fs.existsSync(staticPath)) {
    return;
  }
  let src = fs.readFileSync(staticPath, 'utf8');
  if (src.includes('SWAI_IMMUTABLE_ASSETS')) {
    return;
  }
  const target = `const target = resolve(normalize(join(distRoot, decodeURIComponent(new URL(request.url).pathname))));`;
  const replacement = `const reqPathname = decodeURIComponent(new URL(request.url).pathname);
	const target = resolve(normalize(join(distRoot, reqPathname)));`;
  const oldCacheBlock = `\t\t\tbody = await readFile(target);
\t\t\tconst cache = {
\t\t\t\t"cache-control": "no-cache",
\t\t\t\tetag: \`W/"\${createHash("sha1").update(body).digest("base64url")}"\`
\t\t\t};`;
  const newCacheBlock = `\t\t\tbody = await readFile(target);
\t\t\t/* SWAI_IMMUTABLE_ASSETS */
\t\t\tconst cache = reqPathname.startsWith("/assets/") ? {
\t\t\t\t"cache-control": "public, max-age=31536000, immutable"
\t\t\t} : {
\t\t\t\t"cache-control": "no-cache",
\t\t\t\tetag: \`W/"\${createHash("sha1").update(body).digest("base64url")}"\`
\t\t\t};`;
  if (src.includes(target) && src.includes(oldCacheBlock)) {
    src = src.replace(target, replacement).replace(oldCacheBlock, newCacheBlock);
    fs.writeFileSync(staticPath, src);
    console.log('[build_dsh_runtime] Patched dsh-host-frontend-static for immutable /assets/* caching');
  } else {
    console.warn('[build_dsh_runtime] WARNING: Could not patch dsh-host-frontend-static cache block');
  }
}

const MOBILE_TRIM_DISABLED_IDS = [
  'otel',
  'session-telemetry-otel',
  'desktop-product-telemetry',
  'product-analytics',
  'hmr',
  'client-hmr',
  'office-kit',
  'skill-office',
  'action-cards',
  'client-ui-action-cards',
  'creation-recommendations',
  'client-ui-creation-recommendations',
  'plugin-recommendations',
  'client-ui-plugin-recommendations',
  'open-in-app',
  'ui-open-in-app',
  'pwsh-sandbox',
  'tool-pwsh',
  'plugin-inventory',
  'plugin-package-inventory-deepseek',
  'message-feedback',
  'ui-message-feedback',
  'directory-picker',
  'ui-shortcuts',
  'ui-sidebar-terminal',
  'terminal-controller',
  'ui-plugin-manager',
  'harness-dev-context',
  'ui-cordis',
  'session-log-download',
  'ui-trajectory',
  'cli-account',
  'remote-connection',
  'ui-settings-shell',
  'ui-settings-session-log',
  'entry-customization',
  'ui-workflow-run',
  'agent-team',
  'tool-agent-team',
  'ui-agent-team',
  'ui-account-notifications',
  'session-turn-outline',
  'ui-session-panel',
];

function findEsbuildBin() {
  const npmCacheNpx = path.join(os.homedir(), '.npm/_npx');
  if (fs.existsSync(npmCacheNpx)) {
    for (const dir of fs.readdirSync(npmCacheNpx)) {
      const candidate = path.join(npmCacheNpx, dir, 'node_modules/.bin/esbuild');
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    }
  }
  return null;
}

function prebundleActiveCordisPlugins(stagingDir, nodeModulesDir) {
  const loaderPath = path.join(nodeModulesDir, '@deepseek-ai/cordis-plugin-loader/lib/index.js');
  if (!fs.existsSync(loaderPath)) {
    throw new Error(`cordis-plugin-loader not found at ${loaderPath}`);
  }
  const origLoader = fs.readFileSync(loaderPath, 'utf8');

  // Step 1: Discover active Cordis plugin imports using the trimmed mobile profile config
  const probeDir = fs.mkdtempSync(path.join(os.tmpdir(), 'swai-dsh-probe-'));
  let importedPlugins = [];
  try {
    const dshHome = path.join(probeDir, '.dsh');
    fs.mkdirSync(dshHome, { recursive: true });
    fs.writeFileSync(
      path.join(dshHome, 'cordis.patch.yml'),
      MOBILE_TRIM_DISABLED_IDS.map((id) => `- id: ${id}\n  disabled: true`).join('\n') + '\n'
    );
    const preloadPath = path.join(probeDir, 'probe-preload.cjs');
    fs.writeFileSync(
      preloadPath,
      `const Mod = require('module');
const origReq = Mod.prototype.require;
Mod.prototype.require = function(id) {
  if (id === 'node-addon-require-builtin') {
    return {
      requireBuiltin(mid) {
        try { return origReq.call(this, mid); } catch (e) {
          return origReq.call(this, mid.startsWith('internal/') ? mid : 'internal/' + mid);
        }
      },
      isAllowedInternalId() { return true; },
      getBindingInfo() { return { backend: 'native-internal', abi: 'v24' }; }
    };
  }
  return origReq.apply(this, arguments);
};
const origOut = process.stdout.write.bind(process.stdout);
let done = false;
process.stdout.write = function(chunk, ...rest) {
  const s = typeof chunk === 'string' ? chunk : chunk.toString();
  if (!done && s.includes('http://127.0.0.1:')) {
    done = true;
    setTimeout(() => process.exit(0), 20);
  }
  return origOut(chunk, ...rest);
};
`
    );
    fs.writeFileSync(
      loaderPath,
      origLoader.replace(
        'import(name, getOuterStack) {',
        'import(name, getOuterStack) { process.stderr.write("SWAI_IMPORT:" + name + "\\n");'
      )
    );
    const probeRes = spawnSync(
      process.execPath,
      [
        '--jitless',
        '--expose-internals',
        '-r',
        preloadPath,
        path.join(nodeModulesDir, '@deepseek-ai/dsh/lib/bin.js'),
        'web',
        '--host',
        '127.0.0.1',
        '--port',
        '0',
        '--no-open',
      ],
      {
        cwd: probeDir,
        env: { ...process.env, HOME: probeDir, DSH_HOME: dshHome, NODE_PATH: nodeModulesDir },
        encoding: 'utf8',
        timeout: 30000,
      }
    );
    if (!probeRes.stdout || !probeRes.stdout.includes('http://127.0.0.1:')) {
      throw new Error(`Cordis plugin discovery probe failed (status=${probeRes.status}):\n${probeRes.stderr}`);
    }
    importedPlugins = [...new Set(
      (probeRes.stderr || '')
        .split('\n')
        .filter((l) => l.startsWith('SWAI_IMPORT:'))
        .map((l) => l.slice('SWAI_IMPORT:'.length).trim())
        .filter(Boolean)
    )];
  } finally {
    fs.writeFileSync(loaderPath, origLoader);
    rmRf(probeDir);
  }

  // Step 2: Select pure-ESM single-entry @deepseek-ai/* plugins (preserving shared singletons & runtime-patched pkgs)
  const exclude = new Set([
    '@deepseek-ai/dsh',
    '@deepseek-ai/dsh-app-boot',
    '@deepseek-ai/dsh-official-bundles',
    '@deepseek-ai/dsh-base',
    '@deepseek-ai/dsh-web-app',
    '@deepseek-ai/dsh-working-directory',
    '@deepseek-ai/dsh-tool-fs-search',
    '@deepseek-ai/dsh-fs-local',
    '@deepseek-ai/dsh-attachment-local',
    '@deepseek-ai/dsh-host-authentication-token',
    '@deepseek-ai/dsh-client-connection',
    '@deepseek-ai/dsh-host-frontend-static',
    '@deepseek-ai/dsh-client-modules',
    '@deepseek-ai/dsh-web-frontend',
    '@deepseek-ai/dsh-tools',
    '@deepseek-ai/cordis',
    '@deepseek-ai/cordis-plugin-loader',
    '@deepseek-ai/cordis-plugin-group',
    '@deepseek-ai/cordis-plugin-include',
    '@deepseek-ai/schemastery',
    '@deepseek-ai/cosmokit',
  ]);

  const bundleSpecs = [];
  for (const spec of importedPlugins) {
    if (!spec.startsWith('@deepseek-ai/')) continue;
    const parts = spec.split('/');
    if (parts.length !== 2) continue;
    const pkgName = `${parts[0]}/${parts[1]}`;
    if (exclude.has(pkgName)) continue;
    const entry = path.join(nodeModulesDir, pkgName, 'lib/index.js');
    if (!fs.existsSync(entry)) continue;
    const src = fs.readFileSync(entry, 'utf8');
    if (src.includes('import.meta.url') || src.includes('import.meta.dirname') || src.includes('createRequire')) {
      continue;
    }
    const pj = JSON.parse(fs.readFileSync(path.join(nodeModulesDir, pkgName, 'package.json'), 'utf8'));
    const exp = pj.exports?.['.'];
    const target = typeof exp === 'string' ? exp : (exp?.import || exp?.default || pj.main);
    if (target !== './lib/index.js' && target !== 'lib/index.js') continue;
    bundleSpecs.push(spec);
  }

  const bundleEntryPath = path.join(stagingDir, '_swai_plugins_bundle_entry.mjs');
  const outBundlePath = path.join(stagingDir, 'bridge/dsh-plugins-bundle.mjs');
  fs.mkdirSync(path.dirname(outBundlePath), { recursive: true });
  const entryCode = bundleSpecs.map((s, i) => `import * as m_${i} from ${JSON.stringify(s)};`).join('\n')
    + '\nexport const PREBUNDLED_PLUGINS = {\n'
    + bundleSpecs.map((s, i) => `  ${JSON.stringify(s)}: m_${i},`).join('\n')
    + '\n};\n';
  fs.writeFileSync(bundleEntryPath, entryCode);

  const bundleSet = new Set(bundleSpecs);
  const externals = ['node:*'];
  for (const top of fs.readdirSync(nodeModulesDir)) {
    if (top.startsWith('.')) continue;
    if (top === '@deepseek-ai') {
      for (const sub of fs.readdirSync(path.join(nodeModulesDir, top))) {
        const full = `@deepseek-ai/${sub}`;
        if (!bundleSet.has(full)) externals.push(full, `${full}/*`);
      }
    } else if (top.startsWith('@')) {
      for (const sub of fs.readdirSync(path.join(nodeModulesDir, top))) {
        externals.push(`${top}/${sub}`, `${top}/${sub}/*`);
      }
    } else {
      externals.push(top, `${top}/*`);
    }
  }

  const esbuildArgs = [
    bundleEntryPath,
    '--bundle',
    '--format=esm',
    '--platform=node',
    '--target=node24',
    '--minify-whitespace',
    '--minify-syntax',
    `--outfile=${outBundlePath}`,
    ...externals.map((e) => `--external:${e}`),
  ];
  const cachedEsbuild = findEsbuildBin();
  try {
    if (cachedEsbuild) {
      execFileSync(cachedEsbuild, esbuildArgs, { cwd: stagingDir, stdio: 'inherit' });
    } else {
      execFileSync('npx', ['--yes', 'esbuild', ...esbuildArgs], { cwd: stagingDir, stdio: 'inherit' });
    }
  } finally {
    rmRf(bundleEntryPath);
  }

  // Step 3: Hook cordis-plugin-loader with lazy import (prevents circular ESM initialization)
  const hookHeader = `/* SWAI_PREBUNDLED_PLUGINS */
const __SWAI_BUNDLED_SET = new Set(${JSON.stringify(bundleSpecs)});
let __swaiBundleP = null;
function __swaiLoadBundled(name) {
\tif (!__swaiBundleP) __swaiBundleP = import("../../../../bridge/dsh-plugins-bundle.mjs").then((m) => m.PREBUNDLED_PLUGINS);
\treturn __swaiBundleP.then((map) => map[name]);
}
`;
  const targetImportMethod = 'import(name, getOuterStack) {';
  if (!origLoader.includes(targetImportMethod)) {
    throw new Error('Could not find import(name, getOuterStack) in cordis-plugin-loader');
  }
  const hookedLoader = hookHeader + origLoader.replace(
    targetImportMethod,
    `${targetImportMethod}\n\t\tif (__SWAI_BUNDLED_SET.has(name)) return __swaiLoadBundled(name);`
  );
  fs.writeFileSync(loaderPath, hookedLoader);

  const bundleKb = (fs.statSync(outBundlePath).size / 1024).toFixed(1);
  console.log(`[build_dsh_runtime] Pre-bundled ${bundleSpecs.length}/${importedPlugins.length} active plugins -> bridge/dsh-plugins-bundle.mjs (${bundleKb} KB)`);
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
        zod: '4.6.6',
      },
    };
    fs.writeFileSync(path.join(staging, 'package.json'), JSON.stringify(pkgJson, null, 2) + '\n');

    console.log('[build_dsh_runtime] Running npm install --ignore-scripts --omit=optional --install-strategy=hoisted ...');
    execFileSync(
      'npm',
      ['install', '--no-audit', '--no-fund', '--ignore-scripts', '--omit=optional', '--install-strategy=hoisted'],
      { cwd: staging, stdio: 'inherit' }
    );
    rmRf(path.join(staging, 'package-lock.json'));

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

    // Patch frontend-static for immutable /assets/* caching & pre-bundle active Cordis plugins
    patchFrontendStaticCache(path.join(staging, 'node_modules'));
    prebundleActiveCordisPlugins(staging, path.join(staging, 'node_modules'));

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
