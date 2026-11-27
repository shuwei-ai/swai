/*
 * AgentWorkspace: Manages the native application sandbox workspace and file operations
 * for HarmonyOS Pi Agent via @ohos.file.fs.
 *
 * Provides a reliable, persistent filesystem workspace rooted at context.filesDir + '/workspace'.
 * Relative paths (e.g. 'main.js', 'data/output.json') resolve into this workspace, avoiding
 * shell command-line size limits (E2BIG), escaping issues, and /data/local/tmp volatility.
 * External system paths (/data/local/tmp, /proc, etc.) seamlessly fall back to shell execution.
 */
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import buffer from '@ohos.buffer';
import hilog from '@ohos.hilog';
import environment from '@ohos.file.environment';
import zlib from '@ohos.zlib';
import { BridgeController } from '../../common/BridgeController';

const DOMAIN: number = 0x0001;
const TAG: string = 'AgentWorkspace';
const DSH_RUNTIME_VERSION: string = '0.2.3-alpha.2';
const DSH_PATCH_STAMP: string = '0.2.3-alpha.2-perf1';

export class AgentWorkspace {
  private static instance: AgentWorkspace = new AgentWorkspace();

  private context: common.Context | null = null;
  private workspaceRoot: string = '/data/storage/el2/base/haps/entry/files/workspace';
  private bundleName: string = 'com.shuwei.shellbridge';
  private userId: number = 100;
  private dshRuntimePromise: Promise<string> | null = null;

  static getInstance(): AgentWorkspace {
    return AgentWorkspace.instance;
  }

  /**
   * Initializes the persistent workspace using the application context.
   */
  init(context: common.Context): void {
    this.context = context;
    if (context && context.filesDir) {
      this.workspaceRoot = `${context.filesDir}/workspace`;
    }
    if (context && context.applicationInfo) {
      if (context.applicationInfo.name && context.applicationInfo.name.length > 0) {
        this.bundleName = context.applicationInfo.name;
      }
      const uid = context.applicationInfo.uid;
      if (typeof uid === 'number' && uid >= 200000) {
        this.userId = Math.floor(uid / 200000);
      }
    }
    this.ensureDir(this.workspaceRoot);
    this.ensureDir(`${this.workspaceRoot}/.tmp`);
    hilog.info(DOMAIN, TAG, 'AgentWorkspace initialized at %{public}s', this.workspaceRoot);
    // Defer heavy filesystem maintenance and Python stdlib checks off the cold-start critical path
    setTimeout(() => {
      this.cleanupDuplicateWorkspaceDirs();
      this.cleanupPhantomFileDirs(this.workspaceRoot, 0);
      this.ensurePermissionsSilently();
      this.ensurePythonZip();
    }, 4000);
  }

  /**
   * Unpacks python313.zip from rawfile to filesDir so CPython can load standard modules.
   */
  ensurePythonZip(): void {
    if (!this.context || !this.context.filesDir) {
      return;
    }
    try {
      const libDir = `${this.context.filesDir}/lib/python3.13`;
      // Fast-path: If python stdlib is already decompressed, skip all heavy synchronous I/O
      try {
        if (fs.accessSync(`${libDir}/encodings`)) {
          return;
        }
      } catch (_e) {}

      const zipDest = `${this.context.filesDir}/python313.zip`;
      let needExtract = true;
      try {
        if (fs.accessSync(zipDest)) {
          const stat = fs.statSync(zipDest);
          if (stat.size > 0) {
            needExtract = false;
          }
        }
      } catch (_e) {
        needExtract = true;
      }

      if (needExtract) {
        const rawContent = this.context.resourceManager.getRawFileContentSync('python313.zip');
        const rawSize = rawContent.byteLength;
        hilog.info(DOMAIN, TAG, 'Extracting python313.zip from rawfile (size: %{public}d)...', rawSize);
        const opened = fs.openSync(zipDest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(opened.fd, rawContent.buffer);
        fs.closeSync(opened);
        hilog.info(DOMAIN, TAG, 'python313.zip successfully deployed at %{public}s', zipDest);
      }

      let needDecompress = needExtract;
      if (!needDecompress) {
        try {
          if (!fs.accessSync(`${libDir}/encodings`)) {
            needDecompress = true;
          }
        } catch (_e) {
          needDecompress = true;
        }
      }

      if (needDecompress) {
        hilog.info(DOMAIN, TAG, 'Decompressing python313.zip to %{public}s...', libDir);
        try {
          fs.mkdirSync(`${this.context.filesDir}/lib`);
        } catch (_m) {}
        try {
          fs.mkdirSync(libDir);
        } catch (_m2) {}
        zlib.decompressFile(zipDest, libDir).then(() => {
          hilog.info(DOMAIN, TAG, 'python313 stdlib decompressed successfully to %{public}s', libDir);
        }).catch((err: Object) => {
          hilog.warn(DOMAIN, TAG, 'decompressFile failed: %{public}s', `${err}`);
        });
      }

      // Ensure site-packages exists for custom user or agent libraries
      const sitePackagesDir = `${this.context.filesDir}/site-packages`;
      try {
        if (!fs.accessSync(sitePackagesDir)) {
          fs.mkdirSync(sitePackagesDir);
        }
      } catch (_e) {
        try { fs.mkdirSync(sitePackagesDir); } catch (_e2) {}
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'ensurePythonZip failed: %{public}s', `${err}`);
    }
  }

  /**
   * Unpacks dsh-runtime.zip from rawfile to filesDir so embedded Node can execute DSH web server.
   * Deduplicates concurrent callers so EntryAbility and Index share one extraction/patch pass.
   */
  async ensureDshRuntime(): Promise<string> {
    if (this.dshRuntimePromise) {
      return this.dshRuntimePromise;
    }
    this.dshRuntimePromise = this.ensureDshRuntimeInner().catch((err: Object) => {
      this.dshRuntimePromise = null;
      throw err as Error;
    });
    return this.dshRuntimePromise;
  }

  private async ensureDshRuntimeInner(): Promise<string> {
    if (!this.context || !this.context.filesDir) {
      return '';
    }
    const runtimeDir = `${this.context.filesDir}/dsh-runtime`;
    const binJs = `${runtimeDir}/node_modules/@deepseek-ai/dsh/lib/bin.js`;
    const dshPkgJson = `${runtimeDir}/node_modules/@deepseek-ai/dsh/package.json`;

    let alreadyExtracted = false;
    let installedVersion = '';
    try {
      if (fs.accessSync(binJs) && fs.accessSync(dshPkgJson)) {
        const pkgContent = fs.readTextSync(dshPkgJson);
        const pkgObj = JSON.parse(pkgContent) as Record<string, Object>;
        if (pkgObj && typeof pkgObj.version === 'string') {
          installedVersion = pkgObj.version as string;
        }
        alreadyExtracted = (installedVersion === DSH_RUNTIME_VERSION);
      }
    } catch (_e) {
      alreadyExtracted = false;
    }

    if (!alreadyExtracted) {
      hilog.info(DOMAIN, TAG, 'Updating dsh-runtime from %{public}s to %{public}s',
        installedVersion || 'none', DSH_RUNTIME_VERSION);
      try {
        if (fs.accessSync(runtimeDir)) {
          fs.rmdirSync(runtimeDir);
        }
      } catch (_rmErr) {
        hilog.warn(DOMAIN, TAG, 'Failed to clean old dsh-runtime dir: %{public}s', `${_rmErr}`);
      }
      try {
        const zipDest = `${this.context.filesDir}/dsh-runtime.zip`;
        hilog.info(DOMAIN, TAG, 'Extracting dsh-runtime.zip from rawfile...');

        try {
          fs.mkdirSync(runtimeDir);
        } catch (_m) {}

        let fdObj = this.context.resourceManager.getRawFdSync('dsh-runtime.zip');
        let out = fs.openSync(zipDest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        let copyBuf = new ArrayBuffer(1024 * 1024);
        let totalRead = 0;
        let targetLen = fdObj.length;
        while (totalRead < targetLen) {
          let chunkLen = Math.min(copyBuf.byteLength, targetLen - totalRead);
          let n = fs.readSync(fdObj.fd, copyBuf, { offset: fdObj.offset + totalRead, length: chunkLen });
          if (n <= 0) break;
          fs.writeSync(out.fd, copyBuf, { length: n });
          totalRead += n;
        }
        fs.closeSync(out);
        this.context.resourceManager.closeRawFdSync('dsh-runtime.zip');
        hilog.info(DOMAIN, TAG, 'dsh-runtime.zip copied (%{public}d bytes), decompressing...', totalRead);

        await zlib.decompressFile(zipDest, runtimeDir);
        hilog.info(DOMAIN, TAG, 'dsh-runtime decompressed successfully to %{public}s', runtimeDir);
        try {
          fs.unlinkSync(zipDest);
        } catch (_u) {}
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'ensureDshRuntime failed: %{public}s', `${err}`);
        return '';
      }
    }

    this.syncAndPatchDshRuntime(runtimeDir);
    return runtimeDir;
  }

  /**
   * Syncs latest bridge scripts and applies all OpenHarmony/ArkWeb compatibility patches
   * to the extracted dsh-runtime directory before embedded Node starts.
   */
  private syncAndPatchDshRuntime(runtimeDir: string): void {
    if (!this.context) {
      return;
    }
    const stampPath = `${runtimeDir}/.swai_patch_stamp`;
    try {
      if (fs.accessSync(stampPath) && fs.accessSync(`${runtimeDir}/bridge/swai-tools.mjs`)) {
        const currentStamp = fs.readTextSync(stampPath).trim();
        if (currentStamp === DSH_PATCH_STAMP) {
          return;
        }
      }
    } catch (_stampErr) {
      // fall through to full sync & patch
    }

    // Ensure bridge directory exists before writing bridge scripts
    this.ensureDir(`${runtimeDir}/bridge`);
    // Always keep bridge scripts in sync with latest rawfiles (with dual swai & piha support)
    const bridgeSyncList: [string, string][] = [
      ['dsh_bridge/bridge-client.mjs', `${runtimeDir}/bridge/bridge-client.mjs`],
      ['dsh_bridge/swai-fs-search.mjs', `${runtimeDir}/bridge/swai-fs-search.mjs`],
      ['dsh_bridge/swai-sharp.mjs', `${runtimeDir}/bridge/swai-sharp.mjs`],
      ['dsh_bridge/swai-tools.mjs', `${runtimeDir}/bridge/swai-tools.mjs`],
      ['dsh_bridge/swai-tools.mjs', `${runtimeDir}/bridge/piha-tools.mjs`],
      ['dsh_bridge/swai-host.patch.json', `${runtimeDir}/bridge/swai-host.patch.json`],
      ['dsh_bridge/swai-host.patch.json', `${runtimeDir}/bridge/piha-host.patch.json`],
      ['dsh_bridge/swai-mcp-server.mjs', `${runtimeDir}/bridge/swai-mcp-server.mjs`],
      ['dsh_bridge/swai-mcp-server.mjs', `${runtimeDir}/bridge/piha-mcp-server.mjs`],
      ['dsh_bridge/cdp-driver.mjs', `${runtimeDir}/bridge/cdp-driver.mjs`],
      ['dsh_bridge/wechat-formatter.mjs', `${runtimeDir}/bridge/wechat-formatter.mjs`],
      ['dsh_bridge/wechat-poster.mjs', `${runtimeDir}/bridge/wechat-poster.mjs`]
    ];

    for (let i = 0; i < bridgeSyncList.length; i++) {
      const srcName = bridgeSyncList[i][0];
      const destPath = bridgeSyncList[i][1];
      try {
        const rawData = this.context.resourceManager.getRawFileContentSync(srcName);
        if (rawData && rawData.byteLength > 0) {
          const file = fs.openSync(destPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          fs.writeSync(file.fd, rawData.buffer);
          fs.closeSync(file);
          hilog.info(DOMAIN, TAG, 'Synced %{public}s to %{public}s', srcName, destPath);
        }
      } catch (_syncErr) {
        // ignore
      }
    }

    // Always enforce flock.js stub to permanently prevent ERR_FLOCK_UNSUPPORTED_PLATFORM on OpenHarmony
    try {
      const flockJsPath = `${runtimeDir}/node_modules/@deepseek-ai/node-addon-system/lib/flock.js`;
      const flockStub = 'export function tryLockExclusive(_fd) { return Promise.resolve(); }\nexport const __esModule = true;\nexport default { tryLockExclusive };\n';
      if (fs.accessSync(flockJsPath)) {
        const curContent = fs.readTextSync(flockJsPath);
        if (curContent.includes('ERR_FLOCK_UNSUPPORTED_PLATFORM') || curContent.includes('process.platform')) {
          const file = fs.openSync(flockJsPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          fs.writeSync(file.fd, flockStub);
          fs.closeSync(file);
          hilog.info(DOMAIN, TAG, 'Enforced flock.js stub at %{public}s', flockJsPath);
        }
      }
    } catch (_flockErr) {
      // ignore
    }

    // Always enforce local auth bypass in dsh-host-authentication-token (or legacy dsh-client-connection)
    // to prevent ArkWeb cookie loss on 127.0.0.1. Never short-circuit authorizeIndex so GET /?token=... still responds 303.
    try {
      const authTokenPath = `${runtimeDir}/node_modules/@deepseek-ai/dsh-host-authentication-token/lib/index.js`;
      if (fs.accessSync(authTokenPath)) {
        let curContent = fs.readTextSync(authTokenPath);
        if (!curContent.includes('SWAI_AUTH_BYPASS')) {
          const authTarget = 'isAuthenticated(request, secure = false) {';
          if (curContent.includes(authTarget)) {
            curContent = curContent.replace(
              authTarget,
              'isAuthenticated(request, secure = false) { /* SWAI_AUTH_BYPASS */ return true;'
            );
            const file = fs.openSync(authTokenPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, curContent);
            fs.closeSync(file);
            hilog.info(DOMAIN, TAG, 'Enforced SWAI_AUTH_BYPASS at %{public}s', authTokenPath);
          } else {
            hilog.warn(DOMAIN, TAG, 'SWAI_AUTH_BYPASS target not found in %{public}s', authTokenPath);
          }
        }
      } else {
        const clientConnPath = `${runtimeDir}/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js`;
        if (fs.accessSync(clientConnPath)) {
          let curContent = fs.readTextSync(clientConnPath);
          if (!curContent.includes('SWAI_AUTH_BYPASS') && curContent.includes('isAuthenticated(request, secure = false) {')) {
            curContent = curContent.replace(
              'isAuthenticated(request, secure = false) {',
              'isAuthenticated(request, secure = false) { /* SWAI_AUTH_BYPASS */ return true;'
            );
            const file = fs.openSync(clientConnPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, curContent);
            fs.closeSync(file);
            hilog.info(DOMAIN, TAG, 'Enforced legacy SWAI_AUTH_BYPASS at %{public}s', clientConnPath);
          }
        }
      }
    } catch (_authBypassErr) {
      hilog.warn(DOMAIN, TAG, 'Failed to patch auth bypass: %{public}s', `${_authBypassErr}`);
    }

    // Always enforce window.open shim in dsh-web-frontend/dist/index.html to prevent white screen on login
    this.patchDshIndexHtml(runtimeDir);

    // Always enforce resilience in dsh-working-directory to prevent session crash on missing directory
    this.patchDshWorkingDirectory(runtimeDir);

    // Always enforce in-process native fs search backend for glob/grep (replaces unavailable @vscode/ripgrep binary)
    this.patchDshSearchTools(runtimeDir);

    // Always enforce ArkWeb non-special scheme URL parsing compatibility for dsh-resource:// previews
    this.patchDshResourceUrlParsing(runtimeDir);

    // Always normalize /mnt/debug/.../data/storage shell mount aliases to /data/storage in dsh-fs-local
    this.patchDshLocalFsAlias(runtimeDir);

    // Always enforce HarmonyOS native image processor bridge for dsh-attachment-local (replaces sharp/libvips)
    this.patchDshAttachmentLocal(runtimeDir);

    try {
      const stampFile = fs.openSync(stampPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(stampFile.fd, DSH_PATCH_STAMP);
      fs.closeSync(stampFile);
    } catch (_writeStampErr) {
      // ignore stamp write failure
    }
  }

  /**
   * Patches dsh-web-frontend/dist/index.html to hook window.open and clipboard.
   * This prevents blank screen caused by window.open("about:blank") during login,
   * and routes OAuth login URLs into Swai's built-in browser (BrowserManager).
   */
  private patchDshIndexHtml(runtimeDir: string): void {
    try {
      const indexHtmlPath = `${runtimeDir}/node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html`;
      if (fs.accessSync(indexHtmlPath)) {
        let html = fs.readTextSync(indexHtmlPath);
        if (!html.includes('swai-window-open-shim')) {
          const shim = `<script id="swai-window-open-shim">
(function() {
  function openExternal(url) {
    if (!url || url === 'about:blank') return;
    if (window.swaiBridge && typeof window.swaiBridge.openUrl === 'function') {
      window.swaiBridge.openUrl(url);
    } else {
      var retries = 0;
      var t = setInterval(function() {
        retries++;
        if (window.swaiBridge && typeof window.swaiBridge.openUrl === 'function') {
          clearInterval(t);
          window.swaiBridge.openUrl(url);
        } else if (retries > 30) {
          clearInterval(t);
        }
      }, 100);
    }
  }
  var origOpen = window.open;
  window.open = function(url, target, features) {
    console.log('[SwaiShim] window.open intercepted:', url, target);
    var dummy = {
      closed: false,
      opener: null,
      location: {
        _href: url || '',
        replace: function(newUrl) {
          console.log('[SwaiShim] dummy.location.replace:', newUrl);
          dummy.location._href = newUrl;
          openExternal(newUrl);
        },
        assign: function(newUrl) { dummy.location.replace(newUrl); },
        reload: function() {},
        get href() { return dummy.location._href; },
        set href(newUrl) { dummy.location.replace(newUrl); },
        toString: function() { return dummy.location._href; }
      },
      close: function() { dummy.closed = true; },
      focus: function() {},
      blur: function() {},
      postMessage: function() {}
    };
    if (url && url !== 'about:blank') {
      openExternal(url);
    }
    return dummy;
  };
  try {
    if (!navigator.clipboard) {
      navigator.clipboard = {};
    }
    var origWriteText = navigator.clipboard.writeText ? navigator.clipboard.writeText.bind(navigator.clipboard) : null;
    navigator.clipboard.writeText = function(text) {
      if (origWriteText) {
        return origWriteText(text).catch(function() {
          if (window.swaiBridge && typeof window.swaiBridge.copyToClipboard === 'function') {
            window.swaiBridge.copyToClipboard(text);
            return Promise.resolve();
          }
          return Promise.reject(new Error('copy failed'));
        });
      } else if (window.swaiBridge && typeof window.swaiBridge.copyToClipboard === 'function') {
        window.swaiBridge.copyToClipboard(text);
        return Promise.resolve();
      }
      return Promise.reject(new Error('Clipboard not supported'));
    };
  } catch (clipErr) {
    console.warn('[SwaiShim] clipboard hook error:', clipErr);
  }
  document.addEventListener('click', function(e) {
    var target = e.target;
    while (target && target.tagName !== 'A') {
      target = target.parentElement;
    }
    if (target && target.tagName === 'A') {
      var href = target.getAttribute('href');
      var targetAttr = target.getAttribute('target');
      if (href && (href.startsWith('http://') || href.startsWith('https://')) && (targetAttr === '_blank' || !href.includes(window.location.host))) {
        e.preventDefault();
        openExternal(href);
      }
    }
  }, true);
})();
</script>`;
          if (html.includes('<head>')) {
            html = html.replace('<head>', '<head>\n    ' + shim);
            const file = fs.openSync(indexHtmlPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, html);
            fs.closeSync(file);
            hilog.info(DOMAIN, TAG, 'Successfully injected swai-window-open-shim into %{public}s', indexHtmlPath);
          } else {
            hilog.warn(DOMAIN, TAG, 'swai-window-open-shim <head> target not found in %{public}s', indexHtmlPath);
          }
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Failed to patch index.html: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * Patches @deepseek-ai/dsh-working-directory/lib/index.js to prevent turn failures
   * when historical sessions reference a directory that has been deleted or moved.
   */
  private patchDshWorkingDirectory(runtimeDir: string): void {
    try {
      const workingDirJsPath = `${runtimeDir}/node_modules/@deepseek-ai/dsh-working-directory/lib/index.js`;
      if (fs.accessSync(workingDirJsPath)) {
        let curContent = fs.readTextSync(workingDirJsPath);
        if (!curContent.includes('SWAI_DIR_FALLBACK')) {
          const targetNew = 'if (info?.type !== "directory") throw missing();';
          const targetLegacy = 'if (info?.type !== "directory") throw new Error(`working-directory: directory does not exist: ${JSON.stringify(path)}`);';
          const importPrefix = curContent.includes('__swaiMkdirSync')
            ? ''
            : 'import { mkdirSync as __swaiMkdirSync } from "node:fs";\n';
          const replacement = '/* SWAI_DIR_FALLBACK */ if (info?.type !== "directory") { try { const _p = this.ctx.fs.processPath(target); __swaiMkdirSync(_p, { recursive: true }); return _p; } catch(_e) {} return this.defaultDirectory; }';
          if (curContent.includes(targetNew)) {
            curContent = importPrefix + curContent.replace(targetNew, replacement);
            const file = fs.openSync(workingDirJsPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, curContent);
            fs.closeSync(file);
            hilog.info(DOMAIN, TAG, 'Enforced SWAI_DIR_FALLBACK at %{public}s', workingDirJsPath);
          } else if (curContent.includes(targetLegacy)) {
            curContent = importPrefix + curContent.replace(targetLegacy, replacement);
            const file = fs.openSync(workingDirJsPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, curContent);
            fs.closeSync(file);
            hilog.info(DOMAIN, TAG, 'Enforced legacy SWAI_DIR_FALLBACK at %{public}s', workingDirJsPath);
          } else {
            hilog.warn(DOMAIN, TAG, 'SWAI_DIR_FALLBACK target not found in %{public}s', workingDirJsPath);
          }
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Failed to patch dsh-working-directory: %{public}s', `${e}`);
    }
  }

  /**
   * Patches @deepseek-ai/dsh-tool-fs-search/lib/index.js so `glob` and `grep` execute
   * directly in-process via Node `fs` + `picomatch` (`bridge/swai-fs-search.mjs`) instead
   * of failing with `ripgrep launch failed` on HarmonyOS NEXT.
   */
  private patchDshSearchTools(runtimeDir: string): void {
    try {
      const searchJsPath = `${runtimeDir}/node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js`;
      if (fs.accessSync(searchJsPath)) {
        let curContent = fs.readTextSync(searchJsPath);
        if (!curContent.includes('SWAI_NATIVE_FS_SEARCH')) {
          const targetFn = 'async function runRipgrep(ctx, exec, toolName, argv, rawOutputMaxBytes, graceMs, stderrMaxBytes) {';
          if (curContent.includes(targetFn)) {
            const importStmt = 'import { runSwaiFsSearch as __swaiRunFsSearch } from "../../../../bridge/swai-fs-search.mjs";\n';
            curContent = importStmt + curContent.replace(
              targetFn,
              `${targetFn} /* SWAI_NATIVE_FS_SEARCH */ return await __swaiRunFsSearch(ctx, exec, toolName, argv, rawOutputMaxBytes, SearchError);`
            );
            const file = fs.openSync(searchJsPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, curContent);
            fs.closeSync(file);
            hilog.info(DOMAIN, TAG, 'Enforced SWAI_NATIVE_FS_SEARCH at %{public}s', searchJsPath);
          } else {
            hilog.warn(DOMAIN, TAG, 'SWAI_NATIVE_FS_SEARCH target not found in %{public}s', searchJsPath);
          }
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Failed to patch dsh-tool-fs-search: %{public}s', `${e}`);
    }
  }

  /**
   * Patches DSH client bundles so `dsh-resource://<protocol>/...` URLs parse identically on
   * HarmonyOS NEXT ArkWeb (where pre-WHATWG non-special URL parsing leaves `hostname === ""`
   * and puts `"//<protocol>/..."` into `pathname`), fixing "文件资源服务不可用" in document preview.
   */
  private patchDshResourceUrlParsing(runtimeDir: string): void {
    // 1. @deepseek-ai/dsh-client-resources/lib/client.js (`protocolOf`)
    try {
      const resClientPath = `${runtimeDir}/node_modules/@deepseek-ai/dsh-client-resources/lib/client.js`;
      if (fs.accessSync(resClientPath)) {
        let curContent = fs.readTextSync(resClientPath);
        if (!curContent.includes('SWAI_RESOURCE_URL_FIX')) {
          const targetMin = 'return parsed.hostname===``?void 0:parsed.hostname.toLowerCase()';
          const replacementMin = '/* SWAI_RESOURCE_URL_FIX */ if(parsed.hostname!==``)return parsed.hostname.toLowerCase();const _swaiProto=/^\\/\\/([^/?#]+)(?:[/?#]|$)/.exec(parsed.pathname);return _swaiProto?_swaiProto[1].toLowerCase():void 0';
          const targetLegacy = 'return parsed.hostname === "" ? void 0 : parsed.hostname.toLowerCase();';
          const replacementLegacy = '/* SWAI_RESOURCE_URL_FIX */ if (parsed.hostname !== "") return parsed.hostname.toLowerCase(); const _swaiProto = /^\\/\\/([^/?#]+)(?:[/?#]|$)/.exec(parsed.pathname); return _swaiProto ? _swaiProto[1].toLowerCase() : void 0;';
          if (curContent.includes(targetMin)) {
            curContent = curContent.replace(targetMin, replacementMin);
            const file = fs.openSync(resClientPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, curContent);
            fs.closeSync(file);
            hilog.info(DOMAIN, TAG, 'Enforced SWAI_RESOURCE_URL_FIX at %{public}s', resClientPath);
          } else if (curContent.includes(targetLegacy)) {
            curContent = curContent.replace(targetLegacy, replacementLegacy);
            const file = fs.openSync(resClientPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, curContent);
            fs.closeSync(file);
            hilog.info(DOMAIN, TAG, 'Enforced legacy SWAI_RESOURCE_URL_FIX at %{public}s', resClientPath);
          } else {
            hilog.warn(DOMAIN, TAG, 'SWAI_RESOURCE_URL_FIX target not found in %{public}s', resClientPath);
          }
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Failed to patch dsh-client-resources: %{public}s', `${e}`);
    }

    // 2. @deepseek-ai/dsh-client-ui-sidebar-right/lib/client.js (`pathOf`)
    try {
      const sidebarClientPath = `${runtimeDir}/node_modules/@deepseek-ai/dsh-client-ui-sidebar-right/lib/client.js`;
      if (fs.accessSync(sidebarClientPath)) {
        let curContent = fs.readTextSync(sidebarClientPath);
        if (!curContent.includes('SWAI_SIDEBAR_URL_FIX')) {
          const targetMin = 'function pathOf(address){try{return new URL(address).pathname}';
          const replacementMin = 'function pathOf(address){/* SWAI_SIDEBAR_URL_FIX */try{const _u=new URL(address);if(_u.hostname===""&&_u.pathname.startsWith("//")&&!_u.pathname.startsWith("///"))return _u.pathname.replace(/^\\/\\/[^/]*/,"");return _u.pathname}';
          const targetLegacy = 'function pathOf(address) {\n\t\t\ttry {\n\t\t\t\treturn new URL(address).pathname;';
          const replacementLegacy = 'function pathOf(address) {\n\t\t\t/* SWAI_SIDEBAR_URL_FIX */\n\t\t\ttry {\n\t\t\t\tconst _u = new URL(address);\n\t\t\t\tif (_u.hostname === "" && _u.pathname.startsWith("//") && !_u.pathname.startsWith("///")) return _u.pathname.replace(/^\\/\\/[^/]*/, "");\n\t\t\t\treturn _u.pathname;';
          if (curContent.includes(targetMin)) {
            curContent = curContent.replace(targetMin, replacementMin);
            const file = fs.openSync(sidebarClientPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, curContent);
            fs.closeSync(file);
            hilog.info(DOMAIN, TAG, 'Enforced SWAI_SIDEBAR_URL_FIX at %{public}s', sidebarClientPath);
          } else if (curContent.includes(targetLegacy)) {
            curContent = curContent.replace(targetLegacy, replacementLegacy);
            const file = fs.openSync(sidebarClientPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, curContent);
            fs.closeSync(file);
            hilog.info(DOMAIN, TAG, 'Enforced legacy SWAI_SIDEBAR_URL_FIX at %{public}s', sidebarClientPath);
          } else {
            hilog.warn(DOMAIN, TAG, 'SWAI_SIDEBAR_URL_FIX target not found in %{public}s', sidebarClientPath);
          }
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Failed to patch dsh-client-ui-sidebar-right: %{public}s', `${e}`);
    }

    // 3. @deepseek-ai/dsh-client-ui-subagent/lib/client.js (`parseSubagentChatAddress`)
    try {
      const subagentClientPath = `${runtimeDir}/node_modules/@deepseek-ai/dsh-client-ui-subagent/lib/client.js`;
      if (fs.accessSync(subagentClientPath)) {
        let curContent = fs.readTextSync(subagentClientPath);
        if (!curContent.includes('SWAI_SUBAGENT_URL_FIX')) {
          const targetMin = 'if(url.protocol!==`dsh-resource:`||url.hostname.toLowerCase()!==`subagentchat`)return void 0;const parts=url.pathname.split(`/`).filter(Boolean);';
          const replacementMin = '/* SWAI_SUBAGENT_URL_FIX */const _swaiHost=url.hostname!==""?url.hostname:(/^\\/\\/([^/?#]+)/.exec(url.pathname)?.[1]??"");const _swaiPath=url.hostname!==""?url.pathname:url.pathname.replace(/^\\/\\/[^/]*/,"");if(url.protocol!=="dsh-resource:"||_swaiHost.toLowerCase()!=="subagentchat")return void 0;const parts=_swaiPath.split("/").filter(Boolean);';
          const targetLegacy = 'if (url.protocol !== "dsh-resource:" || url.hostname.toLowerCase() !== "subagentchat") return void 0;\n\t\t\tconst parts = url.pathname.split("/").filter(Boolean);';
          const replacementLegacy = '/* SWAI_SUBAGENT_URL_FIX */ const _swaiHost = url.hostname !== "" ? url.hostname : (/^\\/\\/([^/?#]+)/.exec(url.pathname)?.[1] ?? ""); const _swaiPath = url.hostname !== "" ? url.pathname : url.pathname.replace(/^\\/\\/[^/]*/, "");\n\t\t\tif (url.protocol !== "dsh-resource:" || _swaiHost.toLowerCase() !== "subagentchat") return void 0;\n\t\t\tconst parts = _swaiPath.split("/").filter(Boolean);';
          if (curContent.includes(targetMin)) {
            curContent = curContent.replace(targetMin, replacementMin);
            const file = fs.openSync(subagentClientPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, curContent);
            fs.closeSync(file);
            hilog.info(DOMAIN, TAG, 'Enforced SWAI_SUBAGENT_URL_FIX at %{public}s', subagentClientPath);
          } else if (curContent.includes(targetLegacy)) {
            curContent = curContent.replace(targetLegacy, replacementLegacy);
            const file = fs.openSync(subagentClientPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, curContent);
            fs.closeSync(file);
            hilog.info(DOMAIN, TAG, 'Enforced legacy SWAI_SUBAGENT_URL_FIX at %{public}s', subagentClientPath);
          } else {
            hilog.warn(DOMAIN, TAG, 'SWAI_SUBAGENT_URL_FIX target not found in %{public}s', subagentClientPath);
          }
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Failed to patch dsh-client-ui-subagent: %{public}s', `${e}`);
    }
  }

  /**
   * Patches @deepseek-ai/dsh-fs-local/lib/index.js so:
   * 1) `/mnt/debug/<userId>/debug_hap/<bundle>/data/storage` paths emitted by uid=2000 shell commands
   *    resolve seamlessly to `/data/storage` inside the app sandbox;
   * 2) `/tmp` and `/tmp/...` paths resolve to the writable sandbox temp directory (`TMPDIR` / `workspace/.tmp`)
   *    instead of failing on HarmonyOS NEXT's read-only `/` rootfs.
   */
  private patchDshLocalFsAlias(runtimeDir: string): void {
    try {
      const fsLocalPath = `${runtimeDir}/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js`;
      if (fs.accessSync(fsLocalPath)) {
        let curContent = fs.readTextSync(fsLocalPath);
        if (!curContent.includes('SWAI_SANDBOX_ALIAS_FIX_V2')) {
          const helperDecl = '/* SWAI_SANDBOX_ALIAS_FIX_V2 */ function __swaiNormFsPath(p) { if (typeof p !== "string") return p; p = p.replace(/^\\/mnt\\/debug\\/\\d+\\/debug_hap\\/[^/]+\\/data\\/storage(?=\\/|$)/, "/data/storage"); if (p === "/tmp" || p.startsWith("/tmp/")) { const _td = (process.env.TMPDIR && process.env.TMPDIR !== "/tmp") ? process.env.TMPDIR.replace(/\\/+$/, "") : "/data/storage/el2/base/haps/entry/files/workspace/.tmp"; p = _td + p.slice(4); } return p; }\n';
          const targetExpand = 'function expandHomePrefix(path) {';
          const replacementExpand = helperDecl + 'function expandHomePrefix(path) { path = __swaiNormFsPath(path);';
          const targetDisplay = 'function localDisplayPath(cwd, path) {';
          const replacementDisplay = 'function localDisplayPath(cwd, path) { cwd = __swaiNormFsPath(cwd); path = __swaiNormFsPath(path);';
          const targetHost = 'processPathFromHostPath(hostPath) {';
          const replacementHost = 'processPathFromHostPath(hostPath) { hostPath = __swaiNormFsPath(hostPath);';
          if (curContent.includes(targetExpand) && curContent.includes(targetDisplay)) {
            curContent = curContent.replace(targetExpand, replacementExpand);
            curContent = curContent.replace(targetDisplay, replacementDisplay);
            if (curContent.includes(targetHost)) {
              curContent = curContent.replace(targetHost, replacementHost);
            }
            const file = fs.openSync(fsLocalPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            fs.writeSync(file.fd, curContent);
            fs.closeSync(file);
            hilog.info(DOMAIN, TAG, 'Enforced SWAI_SANDBOX_ALIAS_FIX_V2 at %{public}s', fsLocalPath);
          } else {
            hilog.warn(DOMAIN, TAG, 'SWAI_SANDBOX_ALIAS_FIX_V2 targets not found in %{public}s', fsLocalPath);
          }
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Failed to patch dsh-fs-local: %{public}s', `${e}`);
    }
  }

  /**
   * Patches @deepseek-ai/dsh-attachment-local/lib/index.js so:
   * 1) `requireSharp` resolves to `bridge/swai-sharp.mjs` (backed by HarmonyOS @ohos.multimedia.image)
   *    instead of missing native `sharp` / disabled `--jitless` WebAssembly;
   * 2) `syncDirectory` safely tolerates sandbox EACCES/EPERM/EINVAL/EBADF when `ensureDurableHome`
   *    walks ancestor directories above `/data/storage/el2/base/haps/entry/files`.
   */
  private patchDshAttachmentLocal(runtimeDir: string): void {
    try {
      const attachLocalPath = `${runtimeDir}/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js`;
      if (fs.accessSync(attachLocalPath)) {
        let curContent = fs.readTextSync(attachLocalPath);
        let modified = false;

        if (!curContent.includes('SWAI_SHARP_BRIDGE_V1')) {
          const targetRequire = 'const requireSharp = createLazyRequire("sharp", import.meta.url);';
          if (curContent.includes(targetRequire)) {
            const importStmt = 'import { swaiSharp as __swaiSharp } from "../../../../bridge/swai-sharp.mjs";\n';
            curContent = importStmt + curContent.replace(
              targetRequire,
              '/* SWAI_SHARP_BRIDGE_V1 */ const requireSharp = () => __swaiSharp;'
            );
            modified = true;
          } else {
            hilog.warn(DOMAIN, TAG, 'SWAI_SHARP_BRIDGE_V1 target not found in %{public}s', attachLocalPath);
          }
        }

        if (!curContent.includes('SWAI_SYNC_DIR_SAFE')) {
          const targetSync = 'async function syncDirectory(path) {\n\t/* v8 ignore next -- Windows cannot open directory handles; NTFS metadata journaling owns entry durability there. */\n\tif (process.platform === "win32") return;\n\t/* v8 ignore start -- Windows cannot exercise directory fsync; POSIX behavior tests enforce this peer. */\n\tconst handle = await open(path, constants.O_RDONLY);\n\ttry {\n\t\tawait handle.sync();\n\t} finally {\n\t\tawait handle.close();\n\t}\n\t/* v8 ignore stop */\n}';
          const replacementSync = 'async function syncDirectory(path) {\n\t/* SWAI_SYNC_DIR_SAFE */\n\tif (process.platform === "win32") return;\n\tlet handle;\n\ttry {\n\t\thandle = await open(path, constants.O_RDONLY);\n\t\tawait handle.sync();\n\t} catch (_swaiSyncErr) {\n\t\treturn;\n\t} finally {\n\t\tif (handle !== void 0) await handle.close().catch(() => {});\n\t}\n}';
          if (curContent.includes(targetSync)) {
            curContent = curContent.replace(targetSync, replacementSync);
            modified = true;
          } else {
            hilog.warn(DOMAIN, TAG, 'SWAI_SYNC_DIR_SAFE target not found in %{public}s', attachLocalPath);
          }
        }

        if (modified) {
          const file = fs.openSync(attachLocalPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          fs.writeSync(file.fd, curContent);
          fs.closeSync(file);
          hilog.info(DOMAIN, TAG, 'Enforced SWAI_SHARP_BRIDGE_V1 at %{public}s', attachLocalPath);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Failed to patch dsh-attachment-local: %{public}s', `${e}`);
    }
  }

  /**
   * Removes empty directories whose names carry regular file extensions (e.g. `foo.md`)
   * that were accidentally created by the legacy preload `fsp.stat` `mkdirSync` shim.
   * Only completely empty directories (`listFileSync().length === 0`) are ever removed.
   */
  private cleanupPhantomFileDirs(dirPath: string, depth: number): void {
    if (depth > 2) {
      return;
    }
    const fileExtPattern = /^.+\.(md|txt|json|json5|yaml|yml|js|mjs|cjs|ts|ets|py|sh|html|css|csv|xml|svg|png|jpg|jpeg|webp|pdf|log)$/i;
    try {
      const entries = fs.listFileSync(dirPath);
      for (let i = 0; i < entries.length; i++) {
        const name = entries[i];
        if (!name || name.startsWith('.') || name.endsWith('.tmpdir')) {
          continue;
        }
        const fullPath = `${dirPath}/${name}`;
        try {
          const st = fs.statSync(fullPath);
          if (!st.isDirectory()) {
            continue;
          }
          const children = fs.listFileSync(fullPath);
          if (children.length === 0 && fileExtPattern.test(name)) {
            fs.rmdirSync(fullPath);
            hilog.info(DOMAIN, TAG, 'Removed phantom empty file-named directory: %{public}s', fullPath);
          } else if (children.length > 0 && !fileExtPattern.test(name) && name !== 'workspace' && name !== 'workspace ') {
            this.cleanupPhantomFileDirs(fullPath, depth + 1);
          }
        } catch (_entryErr) {
          // ignore inaccessible or symlink entry
        }
      }
    } catch (_dirErr) {
      // ignore
    }
  }

  /**
   * Auto-grants public directory access permissions via shell bridge if token ID is known.
   * - ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY
   * - ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY
   */
  async ensurePermissionsSilently(): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const tokenId = this.context.applicationInfo.accessTokenId;
      if (tokenId && tokenId > 0) {
        await BridgeController.getInstance().exec(`atm perm -g -i ${tokenId} -p ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY`);
        await BridgeController.getInstance().exec(`atm perm -g -i ${tokenId} -p ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY`);
        hilog.info(DOMAIN, TAG, 'Successfully ensured public directory permissions for token %{public}d', tokenId);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'ensurePermissionsSilently failed: %{public}s', JSON.stringify(err));
    }
  }

  getWorkspaceRoot(): string {
    return this.workspaceRoot;
  }

  getBundleName(): string {
    return this.bundleName;
  }

  getUserId(): number {
    return this.userId;
  }

  getDebugSandboxRoot(bundleName?: string): string {
    const target = (bundleName && bundleName.trim().length > 0) ? bundleName.trim() : this.bundleName;
    return `/mnt/debug/${this.userId}/debug_hap/${target}`;
  }

  /**
   * Converts `/mnt/debug/<userId>/debug_hap/<ownBundle>/data/storage/...` paths back to
   * canonical `/data/storage/...` paths for in-process file APIs.
   */
  normalizeDebugMountPath(rawPath: string): string {
    if (!rawPath || rawPath.length === 0) {
      return rawPath;
    }
    const trimmed = rawPath.trim();
    const ownPrefix = `/mnt/debug/${this.userId}/debug_hap/${this.bundleName}/data/storage`;
    if (trimmed === ownPrefix || trimmed.startsWith(`${ownPrefix}/`)) {
      return `/data/storage${trimmed.substring(ownPrefix.length)}`;
    }
    const genericMatch = /^\/mnt\/debug\/\d+\/debug_hap\/([^/]+)(\/data\/storage(?:\/.*)?)$/.exec(trimmed);
    if (genericMatch && genericMatch[1] === this.bundleName) {
      return genericMatch[2];
    }
    return trimmed;
  }

  setWorkspaceRoot(root: string): void {
    if (root && root.trim().length > 0) {
      this.workspaceRoot = this.normalizePath(root.trim());
      this.ensureDir(this.workspaceRoot);
    }
  }

  /**
   * Determines whether a given path belongs to the application sandbox workspace
   * or requires external shell uid-2000 access.
   */
  isSandboxPath(rawPath: string): boolean {
    if (!rawPath || rawPath.trim().length === 0) {
      return false;
    }
    const trimmed = this.normalizeDebugMountPath(rawPath.trim());

    // Public system storage directories (Download/Docs/Desktop via @ohos.file.environment)
    if (this.isPublicPath(trimmed)) {
      return true;
    }

    // Any relative path belongs to the agent persistent sandbox workspace
    if (!trimmed.startsWith('/')) {
      return true;
    }

    // Explicit path under workspaceRoot
    if (this.workspaceRoot.length > 0 && trimmed.startsWith(this.workspaceRoot)) {
      return true;
    }

    // Application context directories
    if (this.context) {
      if (this.context.filesDir && trimmed.startsWith(this.context.filesDir)) {
        return true;
      }
      if (this.context.cacheDir && trimmed.startsWith(this.context.cacheDir)) {
        return true;
      }
      if (this.context.tempDir && trimmed.startsWith(this.context.tempDir)) {
        return true;
      }
    }

    // Paths referring to workspace directly
    if (trimmed.startsWith('/workspace/') || trimmed === '/workspace') {
      return true;
    }

    // Standard OpenHarmony application sandbox mount points
    if (trimmed.startsWith('/data/storage/el2/') ||
        trimmed.startsWith('/data/storage/el1/') ||
        trimmed.startsWith('/data/app/el2/') ||
        trimmed.startsWith('/data/service/el2/')) {
      return true;
    }

    // External system paths accessible by shell uid 2000 (/data/local/tmp, /proc, /sys, /system, etc.)
    return false;
  }

  /**
   * Determines whether the given path explicitly targets the public user directory
   * (e.g. download://..., public://download/..., Download/..., docs://..., Documents/..., Desktop/...,
   * or common system paths like /storage/Users/currentUser/..., /storage/media/100/local/files/..., /sdcard/...).
   */
  isPublicPath(rawPath: string): boolean {
    if (!rawPath || rawPath.trim().length === 0) {
      return false;
    }
    const lower = rawPath.trim().toLowerCase();
    if (lower.startsWith('download://') ||
        lower.startsWith('public://download/') ||
        lower.startsWith('public://docs/') ||
        lower.startsWith('public://documents/') ||
        lower.startsWith('docs://') ||
        lower.startsWith('documents://') ||
        lower.startsWith('desktop://') ||
        lower.startsWith('public://desktop/') ||
        lower.startsWith('download/') ||
        lower.startsWith('docs/') ||
        lower.startsWith('documents/') ||
        lower.startsWith('desktop/')) {
      return true;
    }

    const stripped = lower.startsWith('/') ? lower.substring(1) : lower;
    if (stripped.startsWith('storage/users/') ||
        stripped.startsWith('storage/media/100/local/files/') ||
        stripped.startsWith('storage/emulated/0/download') ||
        stripped.startsWith('storage/emulated/0/documents') ||
        stripped.startsWith('storage/emulated/0/document') ||
        stripped.startsWith('sdcard/download') ||
        stripped.startsWith('sdcard/documents') ||
        stripped.startsWith('sdcard/document')) {
      return true;
    }

    return false;
  }

  getPublicDownloadDir(): string {
    try {
      const dir = environment.getUserDownloadDir();
      if (dir && dir.length > 0) {
        return dir;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getUserDownloadDir failed: %{public}s', `${e}`);
    }
    return '/storage/media/100/local/files/Docs/Download';
  }

  getPublicDocumentDir(): string {
    try {
      const dir = environment.getUserDocumentDir();
      if (dir && dir.length > 0) {
        return dir;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getUserDocumentDir failed: %{public}s', `${e}`);
    }
    return '/storage/media/100/local/files/Docs';
  }

  getPublicDesktopDir(): string {
    try {
      const dir = environment.getUserDesktopDir();
      if (dir && dir.length > 0) {
        return dir;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getUserDesktopDir failed: %{public}s', `${e}`);
    }
    return '/storage/media/100/local/files/Desktop';
  }

  /**
   * Resolves a public directory protocol URI or path to the absolute system storage path
   * via @ohos.file.environment.
   */
  resolvePublicPath(rawPath: string): string {
    const trimmed = rawPath.trim();
    const lower = trimmed.toLowerCase();

    let subPath = trimmed;
    let baseDir = '';

    if (lower.startsWith('download://')) {
      subPath = trimmed.substring('download://'.length);
      baseDir = this.getPublicDownloadDir();
    } else if (lower.startsWith('public://download/')) {
      subPath = trimmed.substring('public://download/'.length);
      baseDir = this.getPublicDownloadDir();
    } else if (lower.startsWith('download/')) {
      subPath = trimmed.substring('download/'.length);
      baseDir = this.getPublicDownloadDir();
    } else if (lower.startsWith('docs://')) {
      subPath = trimmed.substring('docs://'.length);
      baseDir = this.getPublicDocumentDir();
    } else if (lower.startsWith('documents://')) {
      subPath = trimmed.substring('documents://'.length);
      baseDir = this.getPublicDocumentDir();
    } else if (lower.startsWith('public://docs/')) {
      subPath = trimmed.substring('public://docs/'.length);
      baseDir = this.getPublicDocumentDir();
    } else if (lower.startsWith('public://documents/')) {
      subPath = trimmed.substring('public://documents/'.length);
      baseDir = this.getPublicDocumentDir();
    } else if (lower.startsWith('docs/')) {
      subPath = trimmed.substring('docs/'.length);
      baseDir = this.getPublicDocumentDir();
    } else if (lower.startsWith('documents/')) {
      subPath = trimmed.substring('documents/'.length);
      baseDir = this.getPublicDocumentDir();
    } else if (lower.startsWith('desktop://')) {
      subPath = trimmed.substring('desktop://'.length);
      baseDir = this.getPublicDesktopDir();
    } else if (lower.startsWith('public://desktop/')) {
      subPath = trimmed.substring('public://desktop/'.length);
      baseDir = this.getPublicDesktopDir();
    } else if (lower.startsWith('desktop/')) {
      subPath = trimmed.substring('desktop/'.length);
      baseDir = this.getPublicDesktopDir();
    } else {
      const norm = lower.startsWith('/') ? lower.substring(1) : lower;
      const origNorm = trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;

      if (norm.startsWith('storage/users/currentuser/download/') || norm === 'storage/users/currentuser/download') {
        subPath = origNorm.substring('storage/users/currentuser/download'.length);
        baseDir = this.getPublicDownloadDir();
      } else if (norm.startsWith('storage/users/download/') || norm === 'storage/users/download') {
        subPath = origNorm.substring('storage/users/download'.length);
        baseDir = this.getPublicDownloadDir();
      } else if (norm.startsWith('storage/users/currentuser/documents/') || norm === 'storage/users/currentuser/documents') {
        subPath = origNorm.substring('storage/users/currentuser/documents'.length);
        baseDir = this.getPublicDocumentDir();
      } else if (norm.startsWith('storage/users/currentuser/document/') || norm === 'storage/users/currentuser/document') {
        subPath = origNorm.substring('storage/users/currentuser/document'.length);
        baseDir = this.getPublicDocumentDir();
      } else if (norm.startsWith('storage/users/documents/') || norm === 'storage/users/documents') {
        subPath = origNorm.substring('storage/users/documents'.length);
        baseDir = this.getPublicDocumentDir();
      } else if (norm.startsWith('storage/users/document/') || norm === 'storage/users/document') {
        subPath = origNorm.substring('storage/users/document'.length);
        baseDir = this.getPublicDocumentDir();
      } else if (norm.startsWith('storage/users/currentuser/desktop/') || norm === 'storage/users/currentuser/desktop') {
        subPath = origNorm.substring('storage/users/currentuser/desktop'.length);
        baseDir = this.getPublicDesktopDir();
      } else if (norm.startsWith('storage/users/desktop/') || norm === 'storage/users/desktop') {
        subPath = origNorm.substring('storage/users/desktop'.length);
        baseDir = this.getPublicDesktopDir();
      } else if (norm.startsWith('storage/media/100/local/files/docs/download/') || norm === 'storage/media/100/local/files/docs/download') {
        subPath = origNorm.substring('storage/media/100/local/files/docs/download'.length);
        baseDir = this.getPublicDownloadDir();
      } else if (norm.startsWith('storage/media/100/local/files/desktop/') || norm === 'storage/media/100/local/files/desktop') {
        subPath = origNorm.substring('storage/media/100/local/files/desktop'.length);
        baseDir = this.getPublicDesktopDir();
      } else if (norm.startsWith('storage/media/100/local/files/docs/') || norm === 'storage/media/100/local/files/docs') {
        subPath = origNorm.substring('storage/media/100/local/files/docs'.length);
        baseDir = this.getPublicDocumentDir();
      } else if (norm.startsWith('storage/emulated/0/download/') || norm === 'storage/emulated/0/download' ||
                 norm.startsWith('sdcard/download/') || norm === 'sdcard/download') {
        const pLen = norm.startsWith('sdcard/') ? 'sdcard/download'.length : 'storage/emulated/0/download'.length;
        subPath = origNorm.substring(pLen);
        baseDir = this.getPublicDownloadDir();
      } else if (norm.startsWith('storage/emulated/0/documents/') || norm === 'storage/emulated/0/documents' ||
                 norm.startsWith('storage/emulated/0/document/') || norm === 'storage/emulated/0/document' ||
                 norm.startsWith('sdcard/documents/') || norm === 'sdcard/documents' ||
                 norm.startsWith('sdcard/document/') || norm === 'sdcard/document') {
        const pLen = norm.startsWith('sdcard/documents') ? 'sdcard/documents'.length :
          (norm.startsWith('sdcard/document') ? 'sdcard/document'.length :
            (norm.startsWith('storage/emulated/0/documents') ? 'storage/emulated/0/documents'.length : 'storage/emulated/0/document'.length));
        subPath = origNorm.substring(pLen);
        baseDir = this.getPublicDocumentDir();
      } else {
        baseDir = this.getPublicDownloadDir();
      }
    }

    subPath = subPath.replace(/^[\/\\]+/, '');
    return this.normalizePath(`${baseDir}/${subPath}`);
  }

  /**
   * Resolves relative paths into absolute workspace paths and normalizes directory segments.
   */
  resolvePath(rawPath: string): string {
    let trimmed = this.normalizeDebugMountPath(rawPath.trim());
    if (this.isPublicPath(trimmed)) {
      return this.resolvePublicPath(trimmed);
    }
    if (trimmed.startsWith('/')) {
      const doubleNestedPrefix = `${this.workspaceRoot}/workspace/`;
      if (trimmed.startsWith(doubleNestedPrefix)) {
        trimmed = trimmed.substring(doubleNestedPrefix.length);
        return this.normalizePath(`${this.workspaceRoot}/${trimmed}`);
      } else if (trimmed === `${this.workspaceRoot}/workspace` || trimmed === `${this.workspaceRoot}/workspace `) {
        return this.workspaceRoot;
      }
      if (trimmed.startsWith('/workspace/')) {
        trimmed = trimmed.substring('/workspace/'.length);
        return this.normalizePath(`${this.workspaceRoot}/${trimmed}`);
      } else if (trimmed === '/workspace') {
        return this.workspaceRoot;
      }
      return this.normalizePath(trimmed);
    }
    if (trimmed.startsWith('workspace/')) {
      trimmed = trimmed.substring('workspace/'.length);
    } else if (trimmed.startsWith('./workspace/')) {
      trimmed = trimmed.substring('./workspace/'.length);
    } else if (trimmed === 'workspace' || trimmed === './workspace') {
      return this.workspaceRoot;
    }
    return this.normalizePath(`${this.workspaceRoot}/${trimmed}`);
  }

  /**
   * Rescues any files trapped in duplicate nested workspace directories (e.g. 'workspace/workspace' or 'workspace/workspace ')
   * by moving them up to this.workspaceRoot, and links/ensures the candidate directories so legacy DSH sessions never fail.
   */
  cleanupDuplicateWorkspaceDirs(): void {
    try {
      const candidates: string[] = [`${this.workspaceRoot}/workspace `, `${this.workspaceRoot}/workspace`];
      for (let i = 0; i < candidates.length; i++) {
        const badDir = candidates[i];
        try {
          if (fs.accessSync(badDir)) {
            const stat = fs.statSync(badDir);
            if (stat.isDirectory()) {
              const files = fs.listFileSync(badDir);
              for (let j = 0; j < files.length; j++) {
                const f = files[j];
                const src = `${badDir}/${f}`;
                const dst = `${this.workspaceRoot}/${f}`;
                try {
                  const srcStat = fs.statSync(src);
                  if (srcStat.isDirectory()) {
                    this.ensureDir(dst);
                    const subFiles = fs.listFileSync(src);
                    for (let k = 0; k < subFiles.length; k++) {
                      const sf = subFiles[k];
                      try {
                        fs.copyFileSync(`${src}/${sf}`, `${dst}/${sf}`);
                      } catch (_e) {}
                    }
                  } else {
                    if (!fs.accessSync(dst)) {
                      fs.copyFileSync(src, dst);
                      hilog.info(DOMAIN, TAG, 'Migrated stray file %{public}s to %{public}s', src, dst);
                    }
                  }
                } catch (_cpErr) {
                  hilog.warn(DOMAIN, TAG, 'Failed to migrate %{public}s: %{public}s', src, `${_cpErr}`);
                }
              }
              try {
                fs.rmdirSync(badDir);
                hilog.info(DOMAIN, TAG, 'Removed stray duplicate directory %{public}s', badDir);
              } catch (_rmErr) {
                // If not empty, ignore
              }
            }
          }
        } catch (_accErr) {}

        // Ensure candidate directory is linked or recreated as a directory
        // so historical DSH sessions pointing to badDir never fail with 'directory does not exist'
        try {
          if (!fs.accessSync(badDir)) {
            let symlinkCreated = false;
            try {
              fs.symlinkSync(this.workspaceRoot, badDir);
              symlinkCreated = true;
              hilog.info(DOMAIN, TAG, 'Created symlink %{public}s -> %{public}s', badDir, this.workspaceRoot);
            } catch (_symErr) {
              symlinkCreated = false;
            }
            if (!symlinkCreated && !fs.accessSync(badDir)) {
              fs.mkdirSync(badDir);
              hilog.info(DOMAIN, TAG, 'Ensured fallback directory %{public}s', badDir);
            }
          }
        } catch (_ensErr) {
          hilog.warn(DOMAIN, TAG, 'Failed to ensure candidate %{public}s: %{public}s', badDir, `${_ensErr}`);
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'cleanupDuplicateWorkspaceDirs failed: %{public}s', `${err}`);
    }
  }

  /**
   * Reads the entire UTF-8 content of a sandbox file synchronously.
   */
  readFile(rawPath: string): string {
    const absPath = this.resolvePath(rawPath);
    let stat: fs.Stat;
    try {
      stat = fs.statSync(absPath);
    } catch (err) {
      throw new Error(`File does not exist: ${rawPath} (${absPath})`);
    }

    if (stat.size === 0) {
      return '';
    }

    let opened: fs.File | null = null;
    try {
      opened = fs.openSync(absPath, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      const bytesRead = fs.readSync(opened.fd, buf);
      return buffer.from(buf, 0, bytesRead).toString('utf-8');
    } finally {
      if (opened) {
        try {
          fs.closeSync(opened);
        } catch (_e) {
          // ignore close error
        }
      }
    }
  }

  /**
   * Writes or overwrites a sandbox file with UTF-8 content synchronously.
   * Automatically creates intermediate directories.
   */
  writeFile(rawPath: string, content: string): void {
    const absPath = this.resolvePath(rawPath);
    const lastSlash = absPath.lastIndexOf('/');
    if (lastSlash > 0) {
      const parentDir = absPath.substring(0, lastSlash);
      this.ensureDir(parentDir);
    }

    let opened: fs.File | null = null;
    try {
      opened = fs.openSync(
        absPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
      );
      fs.writeSync(opened.fd, content);
    } finally {
      if (opened) {
        try {
          fs.closeSync(opened);
        } catch (_e) {
          // ignore close error
        }
      }
    }
  }

  /**
   * Checks whether a file exists in the sandbox.
   */
  fileExists(rawPath: string): boolean {
    const absPath = this.resolvePath(rawPath);
    try {
      return fs.accessSync(absPath);
    } catch (_e) {
      return false;
    }
  }

  /**
   * Deletes a file in the sandbox.
   */
  deleteFile(rawPath: string): boolean {
    const absPath = this.resolvePath(rawPath);
    try {
      fs.unlinkSync(absPath);
      return true;
    } catch (_e) {
      return false;
    }
  }

  /**
   * Lists filenames inside a sandbox directory.
   */
  listFiles(rawPath?: string): string[] {
    const target = rawPath ? this.resolvePath(rawPath) : this.workspaceRoot;
    try {
      return fs.listFileSync(target);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'listFileSync failed for %{public}s: %{public}s', target, `${err}`);
      return [];
    }
  }

  /**
   * Ensures a directory path exists recursively.
   */
  ensureDir(dirPath: string): void {
    if (!dirPath || dirPath === '/' || dirPath === '.') {
      return;
    }
    const cleanDir = this.normalizePath(dirPath);
    if (!cleanDir || cleanDir === '/' || cleanDir === '.') {
      return;
    }

    try {
      if (fs.accessSync(cleanDir)) {
        return;
      }
    } catch (_e) {
      // accessSync throws if path does not exist
    }

    const lastSlash = cleanDir.lastIndexOf('/');
    if (lastSlash > 0) {
      const parent = cleanDir.substring(0, lastSlash);
      if (parent && parent.length > 0 && parent !== cleanDir) {
        this.ensureDir(parent);
      }
    }

    try {
      fs.mkdirSync(cleanDir);
    } catch (_e) {
      // Ignore if created concurrently or already exists
    }
  }

  /**
   * Cleans path components and resolves '.' and '..'.
   */
  normalizePath(p: string): string {
    const isAbs = p.startsWith('/');
    const segments = p.split('/');
    const stack: string[] = [];
    for (let i = 0; i < segments.length; i++) {
      const s = segments[i].trim();
      if (s.length === 0 || s === '.') {
        continue;
      }
      if (s === '..') {
        if (stack.length > 0 && stack[stack.length - 1] !== '..') {
          stack.pop();
        } else if (!isAbs) {
          stack.push('..');
        }
      } else {
        stack.push(s);
      }
    }
    const joined = stack.join('/');
    return isAbs ? '/' + joined : (joined.length > 0 ? joined : '.');
  }
}
