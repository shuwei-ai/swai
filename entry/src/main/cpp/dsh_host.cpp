/*
 * Swai <-> DeepSeek Harness (DSH) Host Process Manager
 *
 * Implements C ABI export and Host manager for running and bridging DSH.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "dsh_host.h"
#include "dsh_state.h"

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <dlfcn.h>
#if __has_include(<hilog/log.h>)
#include <hilog/log.h>
#else
#define OH_LOG_Print(type, level, domain, tag, fmt, ...) ((void)0)
#define LOG_APP 0
#define LOG_INFO 0
#define LOG_WARN 0
#define LOG_ERROR 0
#define LOG_DEBUG 0
#endif
#include <signal.h>
#include <cerrno>
#if (defined(__linux__) || defined(__OHOS__)) && defined(__aarch64__)
#include <ucontext.h>
#endif
#include <sys/stat.h>
#include <sys/socket.h>
#if __has_include(<sys/epoll.h>)
#include <sys/epoll.h>
#endif
#include <netinet/in.h>
#include <arpa/inet.h>

#if (defined(__linux__) || defined(__OHOS__)) && defined(__aarch64__)
static struct sigaction g_prev_sigsys;
static void HandleSigsys(int sig, siginfo_t* info, void* ucontext_raw) {
    if (sig == SIGSYS && ucontext_raw && info) {
        auto* uc = reinterpret_cast<ucontext_t*>(ucontext_raw);
        // Emulate return value -ENOSYS in register x0.
        // Note: On ARM64 Linux/OpenHarmony, SECCOMP_RET_TRAP delivers SIGSYS with
        // uc->uc_mcontext.pc already pointing past the 4-byte `svc #0` instruction.
        uc->uc_mcontext.regs[0] = static_cast<unsigned long>(-ENOSYS);
        OH_LOG_Print(LOG_APP, LOG_WARN, 0x3201, "DSHHost",
                     "Emulated ENOSYS for blocked seccomp syscall: %{public}d",
                     info->si_syscall);
        return;
    }
    // Chain to previous handler (e.g. ArkWeb seccomp sandbox)
    if (g_prev_sigsys.sa_flags & SA_SIGINFO) {
        if (g_prev_sigsys.sa_sigaction) {
            g_prev_sigsys.sa_sigaction(sig, info, ucontext_raw);
        }
    } else if (g_prev_sigsys.sa_handler && g_prev_sigsys.sa_handler != SIG_DFL && g_prev_sigsys.sa_handler != SIG_IGN) {
        g_prev_sigsys.sa_handler(sig);
    }
}
#endif

#if !defined(__OHOS__) && !defined(__ANDROID__)
enum fdsan_error_level {
    FDSAN_ERROR_LEVEL_DISABLED = 0,
    FDSAN_ERROR_LEVEL_WARN_ONCE,
    FDSAN_ERROR_LEVEL_WARN_ALWAYS,
    FDSAN_ERROR_LEVEL_FATAL,
};
#endif
typedef enum fdsan_error_level (*FdsanSetErrorLevelFunc)(enum fdsan_error_level);
typedef uint64_t (*FdsanGetOwnerTagFunc)(int);
typedef void (*FdsanExchangeOwnerTagFunc)(int, uint64_t, uint64_t);

static void DisableFdsan() {
    void* libc = dlopen("libc.so", RTLD_NOW);
    if (libc) {
        auto set_level = (FdsanSetErrorLevelFunc)dlsym(libc, "fdsan_set_error_level");
        if (set_level) {
            set_level(FDSAN_ERROR_LEVEL_DISABLED);
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x3201, "DSHHost", "FDSAN disabled successfully.");
        }
        auto get_tag = (FdsanGetOwnerTagFunc)dlsym(libc, "fdsan_get_owner_tag");
        auto exchange_tag = (FdsanExchangeOwnerTagFunc)dlsym(libc, "fdsan_exchange_owner_tag");
        if (get_tag && exchange_tag) {
            exchange_tag(STDIN_FILENO, get_tag(STDIN_FILENO), 0);
            exchange_tag(STDOUT_FILENO, get_tag(STDOUT_FILENO), 0);
            exchange_tag(STDERR_FILENO, get_tag(STDERR_FILENO), 0);
        }
    }
}

__attribute__((constructor))
static void InitDshSecurityAndSignalHandlers() {
    DisableFdsan();
    signal(SIGPIPE, SIG_IGN);
    setenv("UV_USE_IO_URING", "0", 1);
}

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>

extern "C" {

__attribute__((visibility("default")))
int dsh_host_piha_v1(const struct DshBridgeInputV1* in, struct DshBridgeOutputV1* out) noexcept {
    if (!in || in->size != sizeof(*in) || in->version != 1) {
        return -1;
    }

    auto& state = swshell::DshState::GetInstance();

    if (in->operation == DSH_OP_DISPATCH) {
        swshell::DshToolRequest req;
        req.request_id = in->request_id;
        req.tool = in->tool;
        req.deadline_ms = in->deadline_ms;
        if (in->data && in->data_size > 0) {
            req.args_json.assign(in->data, in->data_size);
        }
        bool ok = state.DispatchToolFromNode(req);
        if (out) {
            out->size = sizeof(*out);
            out->version = 1;
            out->status = ok ? 1 : 2;
        }
        return ok ? 1 : 0;
    }

    if (in->operation == DSH_OP_POLL_RESULT) {
        if (!out) {
            return -1;
        }
        out->size = sizeof(*out);
        out->version = 1;
        swshell::DshToolResponse resp;
        int res = state.PollToolResultForNode(in->request_id, resp, 100);
        if (res == 1) { // ready
            out->status = resp.success ? 1 : 2;
            out->exit_code = resp.exit_code;
            const std::string& payload = resp.success ? resp.output : resp.error;
            size_t copy_len = std::min(payload.size(), sizeof(out->data) - 1);
            memcpy(out->data, payload.data(), copy_len);
            out->data[copy_len] = '\0';
            out->data_size = static_cast<uint32_t>(copy_len);
            return 1;
        } else if (res == 2) {
            out->status = 3; // cancelled/stopped
            return 2;
        }
        out->status = 0; // pending
        return 0;
    }

    if (in->operation == DSH_OP_CANCEL) {
        bool ok = state.CancelToolFromNode(in->request_id);
        if (out) {
            out->size = sizeof(*out);
            out->version = 1;
            out->status = ok ? 3 : 2;
        }
        return ok ? 1 : 0;
    }

    if (in->operation == DSH_OP_SNAPSHOT) {
        if (!out) {
            return -1;
        }
        auto snap = state.GetSnapshot();
        out->size = sizeof(*out);
        out->version = 1;
        out->status = (snap.phase == "running") ? 1 : 0;
        out->exit_code = snap.exit_code;
        std::string json = "{\"phase\":\"" + snap.phase + "\",\"port\":" + std::to_string(snap.port) +
                           ",\"baseUrl\":\"" + snap.base_url + "\",\"token\":\"" + snap.token + "\"}";
        size_t copy_len = std::min(json.size(), sizeof(out->data) - 1);
        memcpy(out->data, json.data(), copy_len);
        out->data[copy_len] = '\0';
        out->data_size = static_cast<uint32_t>(copy_len);
        return 1;
    }

    return -2;
}

} // extern "C"

namespace swshell {

bool DshHost::Start(const DshHostOptions& options, std::string& errOut) {
    if (is_running_.load()) {
        errOut = "DSH host is already running.";
        return false;
    }

    current_options_ = options;
    stop_requested_.store(false);

    // Clear any stale ready.json from a previous process before starting StatusWatcherThread
    if (!options.workspace_root.empty()) {
        std::string stale_ready = options.workspace_root + "/ready.json";
        unlink(stale_ready.c_str());
    }

    DshState::GetInstance().SetStarting();
    is_running_.store(true);

    status_watcher_thread_ = std::thread([this]() {
        StatusWatcherThread();
    });

    StartToolBridgeServer();

    runner_thread_ = std::thread([this, options]() {
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xD051, "DSHHost", "DSH host runner thread starting...");

        // 1. Locate and dlopen libnode.so (RTLD_LAZY avoids upfront binding of unused symbols in 126MB libnode.so)
        auto dlopen_start = std::chrono::steady_clock::now();
        void* node_handle = dlopen("libnode.so", RTLD_LAZY | RTLD_GLOBAL);
        if (!node_handle && !options.custom_node_path.empty()) {
            node_handle = dlopen(options.custom_node_path.c_str(), RTLD_LAZY | RTLD_GLOBAL);
        }
        if (!node_handle) {
            node_handle = dlopen("/data/storage/el1/bundle/libs/arm64/libnode.so", RTLD_LAZY | RTLD_GLOBAL);
        }
        auto dlopen_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - dlopen_start).count();
        (void)dlopen_ms;
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xD051, "DSHHost", "dlopen libnode.so took %{public}lld ms",
                     static_cast<long long>(dlopen_ms));
        if (!node_handle) {
            const char* dl_err = dlerror();
            std::string msg = dl_err ? dl_err : "Failed to load libnode.so";
            OH_LOG_Print(LOG_APP, LOG_ERROR, 0xD051, "DSHHost", "dlopen failed: %{public}s", msg.c_str());
            DshState::GetInstance().SetError("ERR_DLOPEN_LIBNODE", msg);
            NotifyEvent("status", "{\"phase\":\"error\",\"errorCode\":\"ERR_DLOPEN_LIBNODE\",\"errorMessage\":\"" + msg + "\"}");
            is_running_.store(false);
            return;
        }

        typedef int (*NodeStartFunc)(int argc, char** argv);
        NodeStartFunc node_start = (NodeStartFunc)dlsym(node_handle, "_ZN4node5StartEiPPc");
        if (!node_start) {
            node_start = (NodeStartFunc)dlsym(node_handle, "node_start");
        }
        if (!node_start) {
            const char* dl_err = dlerror();
            std::string msg = dl_err ? dl_err : "Failed to find node::Start symbol";
            OH_LOG_Print(LOG_APP, LOG_ERROR, 0xD051, "DSHHost", "dlsym failed: %{public}s", msg.c_str());
            DshState::GetInstance().SetError("ERR_NODE_SYMBOL", msg);
            NotifyEvent("status", "{\"phase\":\"error\",\"errorCode\":\"ERR_NODE_SYMBOL\",\"errorMessage\":\"" + msg + "\"}");
            is_running_.store(false);
            return;
        }

        // 2. Prepare workspace directory & environment variables
#if (defined(__linux__) || defined(__OHOS__)) && defined(__aarch64__)
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = HandleSigsys;
        sa.sa_flags = SA_SIGINFO | SA_RESTART;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGSYS, &sa, &g_prev_sigsys);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x3201, "DSHHost", "SIGSYS trap emulation handler installed with chaining.");
#endif
        setenv("UV_USE_IO_URING", "0", 1);
        setenv("NODE_OPTIONS", "", 1);

        if (!options.workspace_root.empty()) {
            mkdir(options.workspace_root.c_str(), 0777);
            chmod(options.workspace_root.c_str(), 0777);
            std::string dsh_dir = options.workspace_root + "/.dsh";
            mkdir(dsh_dir.c_str(), 0777);
            chmod(dsh_dir.c_str(), 0777);
            std::string tmp_dir = options.workspace_root + "/.tmp";
            mkdir(tmp_dir.c_str(), 0777);
            chmod(tmp_dir.c_str(), 0777);
            chdir(options.workspace_root.c_str());
            umask(0);

            setenv("HOME", options.workspace_root.c_str(), 1);
            setenv("DSH_HOME", dsh_dir.c_str(), 1);
            setenv("TMPDIR", tmp_dir.c_str(), 1);
            setenv("TMP", tmp_dir.c_str(), 1);
            setenv("TEMP", tmp_dir.c_str(), 1);

            // Write $DSH_HOME/cordis.patch.yml so DSH loads Swai tools directly and disables desktop-only plugins
            std::string home_patch_yml = dsh_dir + "/cordis.patch.yml";
            std::string tools_mjs = options.runtime_root + "/bridge/swai-tools.mjs";
            FILE* hpf = fopen(home_patch_yml.c_str(), "w");
            if (hpf) {
                fprintf(hpf,
                    "- insert:\n"
                    "    - id: swai-tools\n"
                    "      name: \"%s\"\n"
                    "- id: otel\n"
                    "  disabled: true\n"
                    "- id: session-telemetry-otel\n"
                    "  disabled: true\n"
                    "- id: desktop-product-telemetry\n"
                    "  disabled: true\n"
                    "- id: product-analytics\n"
                    "  disabled: true\n"
                    "- id: hmr\n"
                    "  disabled: true\n"
                    "- id: client-hmr\n"
                    "  disabled: true\n"
                    "- id: office-kit\n"
                    "  disabled: true\n"
                    "- id: skill-office\n"
                    "  disabled: true\n"
                    "- id: action-cards\n"
                    "  disabled: true\n"
                    "- id: client-ui-action-cards\n"
                    "  disabled: true\n"
                    "- id: creation-recommendations\n"
                    "  disabled: true\n"
                    "- id: client-ui-creation-recommendations\n"
                    "  disabled: true\n"
                    "- id: plugin-recommendations\n"
                    "  disabled: true\n"
                    "- id: client-ui-plugin-recommendations\n"
                    "  disabled: true\n"
                    "- id: open-in-app\n"
                    "  disabled: true\n"
                    "- id: ui-open-in-app\n"
                    "  disabled: true\n"
                    "- id: pwsh-sandbox\n"
                    "  disabled: true\n"
                    "- id: tool-pwsh\n"
                    "  disabled: true\n"
                    "- id: plugin-inventory\n"
                    "  disabled: true\n"
                    "- id: plugin-package-inventory-deepseek\n"
                    "  disabled: true\n"
                    "- id: message-feedback\n"
                    "  disabled: true\n"
                    "- id: ui-message-feedback\n"
                    "  disabled: true\n"
                    "- id: directory-picker\n"
                    "  disabled: true\n"
                    "- id: ui-shortcuts\n"
                    "  disabled: true\n"
                    "- id: ui-sidebar-terminal\n"
                    "  disabled: true\n"
                    "- id: terminal-controller\n"
                    "  disabled: true\n"
                    "- id: ui-plugin-manager\n"
                    "  disabled: true\n"
                    "- id: harness-dev-context\n"
                    "  disabled: true\n"
                    "- id: ui-cordis\n"
                    "  disabled: true\n"
                    "- id: session-log-download\n"
                    "  disabled: true\n"
                    "- id: ui-trajectory\n"
                    "  disabled: true\n"
                    "- id: cli-account\n"
                    "  disabled: true\n"
                    "- id: remote-connection\n"
                    "  disabled: true\n"
                    "- id: ui-settings-shell\n"
                    "  disabled: true\n"
                    "- id: ui-settings-session-log\n"
                    "  disabled: true\n"
                    "- id: entry-customization\n"
                    "  disabled: true\n"
                    "- id: ui-workflow-run\n"
                    "  disabled: true\n"
                    "- id: agent-team\n"
                    "  disabled: true\n"
                    "- id: tool-agent-team\n"
                    "  disabled: true\n"
                    "- id: ui-agent-team\n"
                    "  disabled: true\n"
                    "- id: ui-account-notifications\n"
                    "  disabled: true\n"
                    "- id: session-turn-outline\n"
                    "  disabled: true\n"
                    "- id: ui-session-panel\n"
                    "  disabled: true\n",
                    tools_mjs.c_str());
                fclose(hpf);
            }
        }
        if (!options.runtime_root.empty()) {
            std::string compile_cache_dir = options.runtime_root + "/.compile-cache";
            mkdir(compile_cache_dir.c_str(), 0777);
            chmod(compile_cache_dir.c_str(), 0777);
            setenv("NODE_COMPILE_CACHE", compile_cache_dir.c_str(), 1);
        }
        std::string node_modules = options.runtime_root + "/node_modules";
        setenv("NODE_PATH", node_modules.c_str(), 1);

        // 3. Create preload.js to prevent process.exit from killing host app, cache startup fs lookups, and push ready event
        std::string preload_js = options.workspace_root + "/preload.js";
        FILE* pfp = fopen(preload_js.c_str(), "w");
        if (pfp) {
            std::string script =
                "const fs = require('fs');\n"
                "const path = require('path');\n"
                "const { Readable } = require('stream');\n"
                "const { EventEmitter } = require('events');\n"
                "const Module = require('module');\n"
                "const http = require('http');\n"
                "const home = process.env.HOME || '.';\n"
                "const logFile = path.join(home, 'stderr.log');\n"
                "const outLogFile = path.join(home, 'stdout.log');\n"
                "const readyFile = path.join(home, 'ready.json');\n"
                "try { fs.chmodSync(home, 0o777); } catch(e){}\n"
                "let errLogStream = null;\n"
                "let outLogStream = null;\n"
                "function getErrLogStream() {\n"
                "  if (!errLogStream) {\n"
                "    try { errLogStream = fs.createWriteStream(logFile, { flags: 'a' }); errLogStream.on('error', () => {}); } catch(_e) {}\n"
                "  }\n"
                "  return errLogStream;\n"
                "}\n"
                "function getOutLogStream() {\n"
                "  if (!outLogStream) {\n"
                "    try { outLogStream = fs.createWriteStream(outLogFile, { flags: 'a' }); outLogStream.on('error', () => {}); } catch(_e) {}\n"
                "  }\n"
                "  return outLogStream;\n"
                "}\n"
                "function writeLog(prefix, msg) {\n"
                "  try {\n"
                "    const s = getErrLogStream();\n"
                "    if (s) s.write(`[${new Date().toISOString()}] ${prefix}: ${msg}\\n`);\n"
                "  } catch(e){}\n"
                "}\n"
                "writeLog('PRELOAD', 'Node preload script executing...');\n"
                "// Startup boot-cache: caches read-only node_modules stat/realpath/package.json lookups until server ready\n"
                "let disableBootCache = () => {};\n"
                "try {\n"
                "  const nodeModulesRoot = process.env.NODE_PATH ? (path.resolve(process.env.NODE_PATH) + '/') : '';\n"
                "  if (nodeModulesRoot.length > 1) {\n"
                "    const origStatSync = fs.statSync;\n"
                "    const origLstatSync = fs.lstatSync;\n"
                "    const origExistsSync = fs.existsSync;\n"
                "    const origRealpathSync = fs.realpathSync;\n"
                "    const origRealpathNative = fs.realpathSync.native;\n"
                "    const origReadFileSync = fs.readFileSync;\n"
                "    const statCache = new Map();\n"
                "    const lstatCache = new Map();\n"
                "    const realCache = new Map();\n"
                "    const realNativeCache = new Map();\n"
                "    const pkgCache = new Map();\n"
                "    let bootCacheActive = true;\n"
                "    const isEligible = (p) => bootCacheActive && typeof p === 'string' && p.startsWith(nodeModulesRoot) && !p.includes('..') && !p.endsWith('/');\n"
                "    const makeNoEntryErr = (syscall, p) => Object.assign(new Error(`ENOENT: no such file or directory, ${syscall} '${p}'`), { errno: -2, code: 'ENOENT', syscall, path: p });\n"
                "    const syncEsm = () => { try { if (typeof Module.syncBuiltinESMExports === 'function') Module.syncBuiltinESMExports(); } catch(_e) {} };\n"
                "    const cachedStat = (cache, origFn, syscall, p, opts) => {\n"
                "      if (!isEligible(p) || (opts && opts.bigint)) return origFn.call(fs, p, opts);\n"
                "      let entry = cache.get(p);\n"
                "      if (entry === undefined) {\n"
                "        try {\n"
                "          entry = { st: origFn.call(fs, p) };\n"
                "          cache.set(p, entry);\n"
                "        } catch (err) {\n"
                "          if (err && (err.code === 'ENOENT' || err.code === 'ENOTDIR')) {\n"
                "            entry = { missing: err.code };\n"
                "            cache.set(p, entry);\n"
                "          } else {\n"
                "            throw err;\n"
                "          }\n"
                "        }\n"
                "      }\n"
                "      if (entry.missing) {\n"
                "        if (opts && opts.throwIfNoEntry === false) return undefined;\n"
                "        throw makeNoEntryErr(syscall, p);\n"
                "      }\n"
                "      return entry.st;\n"
                "    };\n"
                "    fs.statSync = function(p, opts) { return cachedStat(statCache, origStatSync, 'stat', p, opts); };\n"
                "    fs.lstatSync = function(p, opts) { return cachedStat(lstatCache, origLstatSync, 'lstat', p, opts); };\n"
                "    fs.existsSync = function(p) {\n"
                "      if (!isEligible(p)) return origExistsSync.call(fs, p);\n"
                "      let entry = statCache.get(p);\n"
                "      if (entry === undefined) {\n"
                "        try {\n"
                "          entry = { st: origStatSync.call(fs, p) };\n"
                "          statCache.set(p, entry);\n"
                "        } catch (err) {\n"
                "          if (err && (err.code === 'ENOENT' || err.code === 'ENOTDIR')) {\n"
                "            entry = { missing: err.code };\n"
                "            statCache.set(p, entry);\n"
                "          } else {\n"
                "            return false;\n"
                "          }\n"
                "        }\n"
                "      }\n"
                "      return !entry.missing;\n"
                "    };\n"
                "    const isUtf8RealpathOpts = (opts) => !opts || opts === 'utf8' || opts === 'utf-8' || (typeof opts === 'object' && (!opts.encoding || opts.encoding === 'utf8' || opts.encoding === 'utf-8'));\n"
                "    const cachedRealpath = (cache, origFn, p, opts) => {\n"
                "      if (!isEligible(p) || !isUtf8RealpathOpts(opts)) return origFn.call(fs, p, opts);\n"
                "      let entry = cache.get(p);\n"
                "      if (entry === undefined) {\n"
                "        try {\n"
                "          entry = { val: origFn.call(fs, p, opts) };\n"
                "          cache.set(p, entry);\n"
                "        } catch (err) {\n"
                "          if (err && (err.code === 'ENOENT' || err.code === 'ENOTDIR')) {\n"
                "            entry = { err };\n"
                "            cache.set(p, entry);\n"
                "          } else {\n"
                "            throw err;\n"
                "          }\n"
                "        }\n"
                "      }\n"
                "      if (entry.err) throw entry.err;\n"
                "      return entry.val;\n"
                "    };\n"
                "    const wrappedRealpath = function(p, opts) { return cachedRealpath(realCache, origRealpathSync, p, opts); };\n"
                "    wrappedRealpath.native = function(p, opts) { return cachedRealpath(realNativeCache, origRealpathNative, p, opts); };\n"
                "    fs.realpathSync = wrappedRealpath;\n"
                "    const isUtf8ReadOpts = (opts) => opts === 'utf8' || opts === 'utf-8' || (opts !== null && typeof opts === 'object' && /^utf-?8$/i.test(opts.encoding || '') && opts.flag === undefined);\n"
                "    fs.readFileSync = function(p, opts) {\n"
                "      if (isEligible(p) && p.endsWith('/package.json') && isUtf8ReadOpts(opts)) {\n"
                "        let text = pkgCache.get(p);\n"
                "        if (text === undefined) {\n"
                "          text = origReadFileSync.call(fs, p, opts);\n"
                "          pkgCache.set(p, text);\n"
                "        }\n"
                "        return text;\n"
                "      }\n"
                "      return origReadFileSync.apply(fs, arguments);\n"
                "    };\n"
                "    syncEsm();\n"
                "    disableBootCache = () => {\n"
                "      if (!bootCacheActive) return;\n"
                "      bootCacheActive = false;\n"
                "      fs.statSync = origStatSync;\n"
                "      fs.lstatSync = origLstatSync;\n"
                "      fs.existsSync = origExistsSync;\n"
                "      origRealpathSync.native = origRealpathNative;\n"
                "      fs.realpathSync = origRealpathSync;\n"
                "      fs.readFileSync = origReadFileSync;\n"
                "      syncEsm();\n"
                "      statCache.clear(); lstatCache.clear(); realCache.clear(); realNativeCache.clear(); pkgCache.clear();\n"
                "    };\n"
                "    const t = setTimeout(disableBootCache, 25000);\n"
                "    if (t && typeof t.unref === 'function') t.unref();\n"
                "  }\n"
                "} catch(e) { writeLog('PRELOAD_BOOT_CACHE_ERR', String(e)); }\n"
                "try {\n"
                "  const dummyStdin = new Readable({ read() {} });\n"
                "  dummyStdin.isTTY = false;\n"
                "  dummyStdin.setRawMode = () => dummyStdin;\n"
                "  dummyStdin.pause = () => dummyStdin;\n"
                "  dummyStdin.resume = () => dummyStdin;\n"
                "  Object.defineProperty(process, 'stdin', {\n"
                "    configurable: true,\n"
                "    enumerable: true,\n"
                "    get() { return dummyStdin; }\n"
                "  });\n"
                "} catch (e) { writeLog('PRELOAD_ERR', 'stdin: ' + e); }\n"
                "let dshServerReady = false;\n"
                "if (typeof globalThis.WebAssembly === 'undefined') {\n"
                "  const wasmUnavailable = () => Promise.reject(new Error('WebAssembly is disabled in --jitless mode'));\n"
                "  const WasmStub = function() { throw new Error('WebAssembly is disabled in --jitless mode'); };\n"
                "  globalThis.WebAssembly = {\n"
                "    compile: wasmUnavailable,\n"
                "    compileStreaming: wasmUnavailable,\n"
                "    instantiate: wasmUnavailable,\n"
                "    instantiateStreaming: wasmUnavailable,\n"
                "    validate: () => false,\n"
                "    Module: WasmStub,\n"
                "    Instance: WasmStub,\n"
                "    Memory: WasmStub,\n"
                "    Table: WasmStub,\n"
                "    Global: WasmStub,\n"
                "    Tag: WasmStub,\n"
                "    Exception: WasmStub,\n"
                "    CompileError: Error,\n"
                "    LinkError: Error,\n"
                "    RuntimeError: Error\n"
                "  };\n"
                "  writeLog('PRELOAD_WASM', 'Installed jitless WebAssembly safety stub');\n"
                "}\n"
                "const signalHandlers = new Map();\n"
                "const crashListenerMap = new WeakMap();\n"
                "const origOn = process.on.bind(process);\n"
                "const origAddListener = process.addListener.bind(process);\n"
                "const origPrepend = process.prependListener.bind(process);\n"
                "const origOnce = process.once.bind(process);\n"
                "const origRemove = process.removeListener.bind(process);\n"
                "function isSignal(name) {\n"
                "  return typeof name === 'string' && /^SIG[A-Z0-9]+$/.test(name);\n"
                "}\n"
                "function wrapCrashListener(ev, fn) {\n"
                "  if ((ev === 'unhandledRejection' || ev === 'uncaughtException') && typeof fn === 'function') {\n"
                "    let wrapped = crashListenerMap.get(fn);\n"
                "    if (!wrapped) {\n"
                "      wrapped = function(...cargs) {\n"
                "        const reason = cargs[0];\n"
                "        const detail = reason && reason.stack ? reason.stack : String(reason);\n"
                "        if (ev === 'unhandledRejection' && detail.includes('WebAssembly is disabled in --jitless mode')) {\n"
                "          writeLog('ISOLATED_JITLESS_WASM_ERR', `Ignored expected --jitless WebAssembly rejection: ${detail}`);\n"
                "          return;\n"
                "        }\n"
                "        if (dshServerReady) {\n"
                "          writeLog('ISOLATED_RUNTIME_ERR', `Prevented ${ev} from tearing down live DSH server: ${detail}`);\n"
                "          return;\n"
                "        }\n"
                "        return fn.apply(this, cargs);\n"
                "      };\n"
                "      crashListenerMap.set(fn, wrapped);\n"
                "    }\n"
                "    return wrapped;\n"
                "  }\n"
                "  return fn;\n"
                "}\n"
                "function handleSignal(ev, fn, once) {\n"
                "  if (isSignal(ev)) {\n"
                "    writeLog('PRELOAD_SIGNAL', `Intercepted signal: ${ev}`);\n"
                "    let list = signalHandlers.get(ev);\n"
                "    if (!list) { list = []; signalHandlers.set(ev, list); }\n"
                "    list.push({ fn, once: !!once });\n"
                "    return true;\n"
                "  }\n"
                "  return false;\n"
                "}\n"
                "process.on = function(ev, fn) {\n"
                "  if (handleSignal(ev, fn, false)) return process;\n"
                "  return origOn.call(this, ev, wrapCrashListener(ev, fn));\n"
                "};\n"
                "process.addListener = function(ev, fn) {\n"
                "  if (handleSignal(ev, fn, false)) return process;\n"
                "  return origAddListener.call(this, ev, wrapCrashListener(ev, fn));\n"
                "};\n"
                "process.prependListener = function(ev, fn) {\n"
                "  if (handleSignal(ev, fn, false)) return process;\n"
                "  return origPrepend.call(this, ev, wrapCrashListener(ev, fn));\n"
                "};\n"
                "process.once = function(ev, fn) {\n"
                "  if (handleSignal(ev, fn, true)) return process;\n"
                "  return origOnce.call(this, ev, wrapCrashListener(ev, fn));\n"
                "};\n"
                "process.removeListener = function(ev, fn) {\n"
                "  if (isSignal(ev)) {\n"
                "    let list = signalHandlers.get(ev) || [];\n"
                "    signalHandlers.set(ev, list.filter(item => item.fn !== fn));\n"
                "    return process;\n"
                "  }\n"
                "  return origRemove.call(this, ev, crashListenerMap.get(fn) || fn);\n"
                "};\n"
                "process.off = process.removeListener;\n"
                "const origKill = process.kill ? process.kill.bind(process) : null;\n"
                "process.kill = function(pid, sig) {\n"
                "  if ((!pid || pid === process.pid) && isSignal(sig)) {\n"
                "    writeLog('PRELOAD_KILL', `Intercepted process.kill(${pid}, ${sig})`);\n"
                "    const list = signalHandlers.get(sig) || [];\n"
                "    for (const item of list) { try { item.fn(); } catch(e){} }\n"
                "    return true;\n"
                "  }\n"
                "  if (origKill) return origKill(pid, sig);\n"
                "  return true;\n"
                "};\n"
                "try {\n"
                "  const origStdoutWrite = process.stdout.write.bind(process.stdout);\n"
                "  process.stdout.write = function(chunk, encoding, cb) {\n"
                "    try {\n"
                "      const s = getOutLogStream();\n"
                "      if (s) s.write(chunk);\n"
                "      const str = typeof chunk === 'string' ? chunk : chunk.toString();\n"
                "      const m = str.match(/http:\\/\\/127\\.0\\.0\\.1:(\\d+)\\/\\?token=([a-zA-Z0-9_\\-]+)/);\n"
                "      if (m && !dshServerReady) {\n"
                "        dshServerReady = true;\n"
                "        disableBootCache();\n"
                "        const readyPort = parseInt(m[1], 10);\n"
                "        const info = {\n"
                "          phase: 'running',\n"
                "          port: readyPort,\n"
                "          baseUrl: 'http://127.0.0.1:' + m[1],\n"
                "          token: m[2],\n"
                "          url: m[0]\n"
                "        };\n"
                "        const payload = JSON.stringify(info);\n"
                "        try {\n"
                "          const rReq = http.request({\n"
                "            hostname: '127.0.0.1',\n"
                "            port: 38081,\n"
                "            path: '/v1/host/ready',\n"
                "            method: 'POST',\n"
                "            headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },\n"
                "            timeout: 1500\n"
                "          }, (rRes) => { rRes.resume(); });\n"
                "          rReq.on('error', () => {});\n"
                "          rReq.write(payload);\n"
                "          rReq.end();\n"
                "        } catch(_re) {}\n"
                "        fs.writeFile(readyFile, payload, () => {});\n"
                "        writeLog('READY', `DSH Web Server is ready at ${info.url}`);\n"
                "        // Persist V8 compile cache to disk after server is ready (app exits via SIGKILL, never natural exit)\n"
                "        if (typeof Module.flushCompileCache === 'function') {\n"
                "          const flushOnce = (tag) => {\n"
                "            try {\n"
                "              const tFlush = Date.now();\n"
                "              Module.flushCompileCache();\n"
                "              writeLog('COMPILE_CACHE_FLUSHED', `${tag} elapsed=${Date.now() - tFlush}ms dir=${process.env.NODE_COMPILE_CACHE || ''}`);\n"
                "            } catch (_fcErr) {}\n"
                "          };\n"
                "          const ft1 = setTimeout(() => flushOnce('t+2500ms'), 2500);\n"
                "          if (ft1 && typeof ft1.unref === 'function') ft1.unref();\n"
                "          const ft2 = setTimeout(() => flushOnce('t+10000ms'), 10000);\n"
                "          if (ft2 && typeof ft2.unref === 'function') ft2.unref();\n"
                "        }\n"
                "      }\n"
                "    } catch(e){}\n"
                "    return origStdoutWrite(chunk, encoding, cb);\n"
                "  };\n"
                "} catch(e) {}\n"
                "try {\n"
                "  const origStderrWrite = process.stderr.write.bind(process.stderr);\n"
                "  process.stderr.write = function(chunk, encoding, cb) {\n"
                "    try {\n"
                "      const str = typeof chunk === 'string' ? chunk : chunk.toString();\n"
                "      if (!str.startsWith('[../../arkweb/') && !str.startsWith('[../../content/') && !str.startsWith('[../../cef/') && !str.startsWith('[../../ohos_nweb/') && !str.startsWith('[../../media/') && !str.startsWith('[../../net/')) {\n"
                "        const s = getErrLogStream();\n"
                "        if (s) s.write(chunk);\n"
                "      }\n"
                "    } catch(e){}\n"
                "    return origStderrWrite(chunk, encoding, cb);\n"
                "  };\n"
                "} catch(e) {}\n"
                "origOn('uncaughtException', (err, origin) => {\n"
                "  const msg = err && err.stack ? err.stack : String(err);\n"
                "  writeLog('UNCAUGHT_EXCEPTION', `${origin} - ${msg}`);\n"
                "  console.error('DSH UNCAUGHT EXCEPTION:', origin, msg);\n"
                "});\n"
                "origOn('unhandledRejection', (reason) => {\n"
                "  const msg = reason && reason.stack ? reason.stack : String(reason);\n"
                "  writeLog('UNHANDLED_REJECTION', msg);\n"
                "  console.error('DSH UNHANDLED REJECTION:', msg);\n"
                "});\n"
                "if (!process.execArgv.includes('--expose-internals')) {\n"
                "  process.execArgv.push('--expose-internals');\n"
                "}\n"
                "try {\n"
                "  const Module = require('module');\n"
                "  const origRequire = Module.prototype.require;\n"
                "  Module.prototype.require = function(id) {\n"
                "    if (id === 'node-addon-require-builtin') {\n"
                "      return {\n"
                "        requireBuiltin(mid) {\n"
                "          try { return origRequire.call(this, mid); } catch(e) {\n"
                "            return origRequire.call(this, mid.startsWith('internal/') ? mid : `internal/${mid}`);\n"
                "          }\n"
                "        },\n"
                "        isAllowedInternalId() { return true; },\n"
                "        getBindingInfo() { return { backend: 'native-internal', abi: 'v24' }; }\n"
                "      };\n"
                "    }\n"
                "    return origRequire.apply(this, arguments);\n"
                "  };\n"
                "} catch(e) { writeLog('PRELOAD_MODULE_ERR', 'Module shim: ' + e); }\n"
                "try {\n"
                "  const fs = require('fs');\n"
                "  const path = require('path');\n"
                "  const candidates = [\n"
                "    '/data/storage/el2/base/haps/entry/files/dsh-runtime/node_modules/@deepseek-ai/node-addon-system/lib/flock.js',\n"
                "    path.join(process.cwd(), '../dsh-runtime/node_modules/@deepseek-ai/node-addon-system/lib/flock.js')\n"
                "  ];\n"
                "  const flockCode = 'export function tryLockExclusive(_fd) { return Promise.resolve(); }\\nexport const __esModule = true;\\nexport default { tryLockExclusive };\\n';\n"
                "  for (const fp of candidates) {\n"
                "    try {\n"
                "      if (fs.existsSync(fp)) {\n"
                "        const cur = fs.readFileSync(fp, 'utf8');\n"
                "        if (cur.indexOf('ERR_FLOCK_UNSUPPORTED_PLATFORM') !== -1) {\n"
                "          fs.writeFileSync(fp, flockCode);\n"
                "          writeLog('PRELOAD_FLOCK', 'Patched flock.js for OpenHarmony');\n"
                "        }\n"
                "      }\n"
                "    } catch(e) {}\n"
                "  }\n"
                "} catch(e) {}\n"
                "try {\n"
                "  const fs = require('fs');\n"
                "  const fsp = require('fs/promises');\n"
                "  const origFspLink = fsp.link;\n"
                "  fsp.link = async function(existingPath, newPath) {\n"
                "    try {\n"
                "      return await origFspLink.call(this, existingPath, newPath);\n"
                "    } catch(err) {\n"
                "      if (err && (err.code === 'EACCES' || err.code === 'EPERM' || err.code === 'EXDEV' || err.code === 'ENOSYS')) {\n"
                "        writeLog('PRELOAD_LINK_SHIM', `Hardlink denied (${err.code}), fallback to copyFile_EXCL: ${existingPath} -> ${newPath}`);\n"
                "        await fsp.copyFile(existingPath, newPath, fs.constants.COPYFILE_EXCL);\n"
                "        return;\n"
                "      }\n"
                "      throw err;\n"
                "    }\n"
                "  };\n"
                "  fs.link = function(existingPath, newPath, callback) {\n"
                "    fsp.link(existingPath, newPath).then(() => callback(null), (err) => callback(err));\n"
                "  };\n"
                "  const origFsLinkSync = fs.linkSync;\n"
                "  fs.linkSync = function(existingPath, newPath) {\n"
                "    try {\n"
                "      return origFsLinkSync.call(this, existingPath, newPath);\n"
                "    } catch(err) {\n"
                "      if (err && (err.code === 'EACCES' || err.code === 'EPERM' || err.code === 'EXDEV' || err.code === 'ENOSYS')) {\n"
                "        fs.copyFileSync(existingPath, newPath, fs.constants.COPYFILE_EXCL);\n"
                "        return;\n"
                "      }\n"
                "      throw err;\n"
                "    }\n"
                "  };\n"
                "  const origFspChmod = fsp.chmod;\n"
                "  fsp.chmod = async function(path, mode) {\n"
                "    try { return await origFspChmod.call(this, path, mode); } catch(err) {\n"
                "      if (err && (err.code === 'EPERM' || err.code === 'EACCES' || err.code === 'ENOSYS')) return;\n"
                "      throw err;\n"
                "    }\n"
                "  };\n"
                "  const origFsChmodSync = fs.chmodSync;\n"
                "  fs.chmodSync = function(path, mode) {\n"
                "    try { return origFsChmodSync.call(this, path, mode); } catch(err) {\n"
                "      if (err && (err.code === 'EPERM' || err.code === 'EACCES' || err.code === 'ENOSYS')) return;\n"
                "      throw err;\n"
                "    }\n"
                "  };\n"
                "  const origFspOpen = fsp.open;\n"
                "  fsp.open = async function(...args) {\n"
                "    const h = await origFspOpen.apply(this, args);\n"
                "    if (h && typeof h.chmod === 'function') {\n"
                "      const origHChmod = h.chmod.bind(h);\n"
                "      h.chmod = async function(...cargs) {\n"
                "        try { return await origHChmod.apply(this, cargs); } catch(err) {\n"
                "          if (err && (err.code === 'EPERM' || err.code === 'EACCES' || err.code === 'ENOSYS')) return;\n"
                "          throw err;\n"
                "        }\n"
                "      };\n"
                "    }\n"
                "    if (h && typeof h.sync === 'function') {\n"
                "      const origHSync = h.sync.bind(h);\n"
                "      h.sync = async function(...sargs) {\n"
                "        try { return await origHSync.apply(this, sargs); } catch(err) {\n"
                "          if (err && (err.code === 'EINVAL' || err.code === 'EBADF' || err.code === 'EPERM' || err.code === 'EACCES' || err.code === 'EROFS' || err.code === 'ENOSYS')) return;\n"
                "          throw err;\n"
                "        }\n"
                "      };\n"
                "    }\n"
                "    return h;\n"
                "  };\n"
                "} catch(e) { writeLog('PRELOAD_LINK_ERR', 'link/chmod shim: ' + e); }\n"
                "const origExit = process.exit;\n"
                "process.exit = function(code) {\n"
                "  const st = new Error().stack;\n"
                "  writeLog('PROCESS_EXIT_PREVENTED', `code=${code}\\n${st}`);\n"
                "  console.error(`DSH PROCESS.EXIT(${code}) intercepted to protect OHOS host process.`);\n"
                "};\n"
                "try {\n"
                "  const cp = require('child_process');\n"
                "  const http = require('http');\n"
                "  const { Readable, Writable } = require('stream');\n"
                "  const mockPids = new Set();\n"
                "  const origSpawnSync = cp.spawnSync;\n"
                "  cp.spawnSync = function(cmd, args, options) {\n"
                "    writeLog('SPAWN_SYNC', `cmd=${cmd}`);\n"
                "    return {\n"
                "      status: 127,\n"
                "      stdout: '',\n"
                "      stderr: `command not found: ${cmd}\\n`,\n"
                "      error: Object.assign(new Error(`spawnSync ${cmd} ENOENT`), { code: 'ENOENT' })\n"
                "    };\n"
                "  };\n"
                "  const origSpawn = cp.spawn;\n"
                "  cp.spawn = function(command, args, options) {\n"
                "    const actualArgs = Array.isArray(args) ? args : [];\n"
                "    writeLog('SPAWN_INTERCEPT', `cmd=${command} args=${JSON.stringify(actualArgs)}`);\n"
                "    let fullCmd = command;\n"
                "    if ((command === 'bash' || command === 'sh' || command === '/bin/bash' || command === '/bin/sh') && actualArgs[0] === '-c') {\n"
                "      fullCmd = actualArgs.slice(1).join(' ');\n"
                "    } else if (actualArgs.length > 0) {\n"
                "      fullCmd = `${command} ${actualArgs.join(' ')}`;\n"
                "    }\n"
                "    const targetCwd = options && options.cwd ? options.cwd : (process.env.HOME || process.cwd());\n"
                "    let effectiveCmd = fullCmd.trim();\n"
                "    if (targetCwd && !effectiveCmd.startsWith('cd ') && !effectiveCmd.startsWith('cd/') && !effectiveCmd.startsWith('if ! cd ')) {\n"
                "      effectiveCmd = `if ! cd ${JSON.stringify(targetCwd)} 2>/dev/null; then cd /data/local/tmp 2>/dev/null || true; fi\\n${effectiveCmd}`;\n"
                "    }\n"
                "    const child = new EventEmitter();\n"
                "    const pid = Math.floor(Math.random() * 20000) + 10000;\n"
                "    mockPids.add(pid);\n"
                "    child.pid = pid;\n"
                "    child.exitCode = null;\n"
                "    child.signalCode = null;\n"
                "    child.connected = false;\n"
                "    child.killed = false;\n"
                "    child.spawnfile = command;\n"
                "    child.spawnargs = [command, ...actualArgs];\n"
                "    child.unref = () => child;\n"
                "    child.ref = () => child;\n"
                "    const stdout = new Readable({ read() {} });\n"
                "    const stderr = new Readable({ read() {} });\n"
                "    const stdin = new Writable({ write(chunk, enc, cb) { cb(); } });\n"
                "    child.stdout = stdout;\n"
                "    child.stderr = stderr;\n"
                "    child.stdin = stdin;\n"
                "    child.stdio = [stdin, stdout, stderr];\n"
                "    const reqId = `dsh-cp-${Date.now()}-${pid}`;\n"
                "    const reqTimeoutMs = (options && typeof options.timeout === 'number' && Number.isFinite(options.timeout) && options.timeout > 0)\n"
                "      ? Math.min(Math.max(Math.round(options.timeout), 1000), 305000)\n"
                "      : 60000;\n"
                "    const cmdTimeoutSec = Math.max(1, Math.min(300, Math.ceil(reqTimeoutMs / 1000)));\n"
                "    const httpTimeoutMs = reqTimeoutMs + 5000;\n"
                "    let req = null;\n"
                "    function sendSpawnCancel() {\n"
                "      try {\n"
                "        const cBody = JSON.stringify({ requestId: reqId });\n"
                "        const cReq = http.request({\n"
                "          hostname: '127.0.0.1',\n"
                "          port: 38081,\n"
                "          path: '/v1/tool/cancel',\n"
                "          method: 'POST',\n"
                "          headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(cBody) },\n"
                "          timeout: 1500\n"
                "        }, (cres) => { cres.resume(); });\n"
                "        cReq.on('error', () => {});\n"
                "        cReq.on('timeout', () => { cReq.destroy(); });\n"
                "        cReq.write(cBody);\n"
                "        cReq.end();\n"
                "      } catch (e) {}\n"
                "    }\n"
                "    child.kill = function(sig) {\n"
                "      child.killed = true;\n"
                "      child.signalCode = sig || 'SIGTERM';\n"
                "      sendSpawnCancel();\n"
                "      if (req && !req.destroyed) { try { req.destroy(); } catch(e){} }\n"
                "      return true;\n"
                "    };\n"
                "    process.nextTick(() => {\n"
                "      child.emit('spawn');\n"
                "      const reqData = JSON.stringify({\n"
                "        requestId: reqId,\n"
                "        tool: 'bash',\n"
                "        args: { command: effectiveCmd, timeout_seconds: cmdTimeoutSec },\n"
                "        deadlineMs: Date.now() + httpTimeoutMs\n"
                "      });\n"
                "      req = http.request({\n"
                "        hostname: '127.0.0.1',\n"
                "        port: 38081,\n"
                "        path: '/v1/tool/execute',\n"
                "        method: 'POST',\n"
                "        headers: {\n"
                "          'Content-Type': 'application/json',\n"
                "          'Content-Length': Buffer.byteLength(reqData)\n"
                "        },\n"
                "        timeout: httpTimeoutMs\n"
                "      }, (res) => {\n"
                "        let body = '';\n"
                "        res.on('data', chunk => { body += chunk; });\n"
                "        res.on('end', () => {\n"
                "          mockPids.delete(pid);\n"
                "          try {\n"
                "            const parsed = JSON.parse(body);\n"
                "            if (parsed.output) stdout.push(parsed.output);\n"
                "            if (parsed.error) stderr.push(parsed.error);\n"
                "            stdout.push(null);\n"
                "            stderr.push(null);\n"
                "            const exitCode = parsed.ok ? (parsed.exitCode || 0) : (parsed.exitCode || 1);\n"
                "            child.exitCode = exitCode;\n"
                "            child.emit('exit', exitCode, null);\n"
                "            child.emit('close', exitCode, null);\n"
                "          } catch(e) {\n"
                "            stderr.push(`Bridge response parse error: ${e.message}\\n`);\n"
                "            stdout.push(null);\n"
                "            stderr.push(null);\n"
                "            child.exitCode = 1;\n"
                "            child.emit('exit', 1, null);\n"
                "            child.emit('close', 1, null);\n"
                "          }\n"
                "        });\n"
                "      });\n"
                "      req.on('error', (err) => {\n"
                "        mockPids.delete(pid);\n"
                "        writeLog('SPAWN_ERR', `Bridge error: ${err.message}`);\n"
                "        stderr.push(`Tool bridge connection error: ${err.message}\\n`);\n"
                "        stdout.push(null);\n"
                "        stderr.push(null);\n"
                "        child.exitCode = 1;\n"
                "        if (child.listenerCount && child.listenerCount('error') > 0) {\n"
                "          try { child.emit('error', err); } catch(e){}\n"
                "        }\n"
                "        child.emit('exit', 1, null);\n"
                "        child.emit('close', 1, null);\n"
                "      });\n"
                "      req.write(reqData);\n"
                "      req.end();\n"
                "    });\n"
                "    return child;\n"
                "  };\n"
                "  const prevKill = process.kill;\n"
                "  process.kill = function(pid, sig) {\n"
                "    const absPid = Math.abs(pid);\n"
                "    if (mockPids.has(absPid)) {\n"
                "      if (sig === 0) return true;\n"
                "      mockPids.delete(absPid);\n"
                "      return true;\n"
                "    }\n"
                "    if (prevKill) {\n"
                "      try { return prevKill.call(process, pid, sig); } catch(e) {\n"
                "        if (sig === 0) throw e;\n"
                "        return false;\n"
                "      }\n"
                "    }\n"
                "    if (sig === 0) {\n"
                "      const err = new Error('kill ESRCH');\n"
                "      err.code = 'ESRCH';\n"
                "      throw err;\n"
                "    }\n"
                "    return true;\n"
                "  };\n"
                "} catch(e) { writeLog('PRELOAD_CP_ERR', 'child_process shim: ' + e); }\n"
                "try {\n"
                "  const https = require('https');\n"
                "  const http = require('http');\n"
                "  const { URL } = require('url');\n"
                "  function createFetchPolyfill() {\n"
                "    const httpsAgent = new https.Agent({\n"
                "      keepAlive: true,\n"
                "      keepAliveMsecs: 15000,\n"
                "      timeout: 55000,\n"
                "      maxSockets: 32,\n"
                "      maxFreeSockets: 8,\n"
                "      maxCachedSessions: 0,\n"
                "      rejectUnauthorized: false\n"
                "    });\n"
                "    const httpAgent = new http.Agent({\n"
                "      keepAlive: true,\n"
                "      keepAliveMsecs: 15000,\n"
                "      timeout: 55000,\n"
                "      maxSockets: 32,\n"
                "      maxFreeSockets: 8\n"
                "    });\n"
                "    const MAX_RETRIES = 2;\n"
                "    const RETRYABLE_CODES = new Set([\n"
                "      'ERR_SSL_CIPHER_OPERATION_FAILED',\n"
                "      'EPROTO',\n"
                "      'ECONNRESET',\n"
                "      'ECONNABORTED',\n"
                "      'EPIPE',\n"
                "      'ERR_SSL_WRONG_VERSION_NUMBER',\n"
                "      'ERR_SOCKET_CONNECTION_TIMEOUT'\n"
                "    ]);\n"
                "    const RETRYABLE_RE = /ossl_gcm_stream_update|cipher operation failed|wrong version number|header too long|socket hang up|disconnected before secure TLS|ECONNRESET|ECONNABORTED|EPROTO/i;\n"
                "    function isRetryableNetError(err, signal) {\n"
                "      if (!err || err.name === 'AbortError' || (signal && signal.aborted)) return false;\n"
                "      if (err.code && RETRYABLE_CODES.has(err.code)) return true;\n"
                "      const msg = String(err.message || err);\n"
                "      if (msg === 'aborted') return true;\n"
                "      return RETRYABLE_RE.test(msg);\n"
                "    }\n"
                "    function evictHostFreeSockets(agent, hostname) {\n"
                "      const freeMap = agent && agent.freeSockets;\n"
                "      if (!freeMap) return;\n"
                "      for (const key of Object.keys(freeMap)) {\n"
                "        if (!hostname || key === hostname || key.startsWith(hostname + ':')) {\n"
                "          const list = freeMap[key];\n"
                "          if (Array.isArray(list)) {\n"
                "            for (const sock of list.slice()) {\n"
                "              try { sock.destroy(); } catch (_e) {}\n"
                "            }\n"
                "          }\n"
                "        }\n"
                "      }\n"
                "    }\n"
                "    function normalizeBody(bodyData) {\n"
                "      if (bodyData === undefined || bodyData === null) {\n"
                "        return { bodyBuf: null, isStreamBody: false };\n"
                "      }\n"
                "      if (typeof bodyData.pipe === 'function') {\n"
                "        return { bodyBuf: null, isStreamBody: true };\n"
                "      }\n"
                "      if (Buffer.isBuffer(bodyData)) {\n"
                "        return { bodyBuf: bodyData, isStreamBody: false };\n"
                "      }\n"
                "      if (typeof bodyData === 'string') {\n"
                "        return { bodyBuf: Buffer.from(bodyData, 'utf8'), isStreamBody: false };\n"
                "      }\n"
                "      if (ArrayBuffer.isView(bodyData)) {\n"
                "        return { bodyBuf: Buffer.from(bodyData.buffer, bodyData.byteOffset, bodyData.byteLength), isStreamBody: false };\n"
                "      }\n"
                "      if (bodyData instanceof ArrayBuffer) {\n"
                "        return { bodyBuf: Buffer.from(bodyData), isStreamBody: false };\n"
                "      }\n"
                "      return { bodyBuf: null, isStreamBody: false };\n"
                "    }\n"
                "    return function customFetch(input, init = {}) {\n"
                "      return new Promise((resolve, reject) => {\n"
                "        const signal = init.signal || (input && input.signal);\n"
                "        if (signal && signal.aborted) {\n"
                "          const err = new Error('This operation was aborted');\n"
                "          err.name = 'AbortError';\n"
                "          return reject(err);\n"
                "        }\n"
                "        let settled = false;\n"
                "        let retryTimer = null;\n"
                "        let activeReq = null;\n"
                "        let abortHandler = null;\n"
                "        function cleanup() {\n"
                "          if (retryTimer) {\n"
                "            clearTimeout(retryTimer);\n"
                "            retryTimer = null;\n"
                "          }\n"
                "          if (signal && abortHandler) {\n"
                "            try { signal.removeEventListener('abort', abortHandler); } catch (_e) {}\n"
                "            abortHandler = null;\n"
                "          }\n"
                "        }\n"
                "        if (signal) {\n"
                "          abortHandler = () => {\n"
                "            if (settled) return;\n"
                "            settled = true;\n"
                "            cleanup();\n"
                "            if (activeReq) {\n"
                "              try { activeReq.destroy(); } catch (_e) {}\n"
                "            }\n"
                "            const err = new Error('This operation was aborted');\n"
                "            err.name = 'AbortError';\n"
                "            reject(err);\n"
                "          };\n"
                "          signal.addEventListener('abort', abortHandler, { once: true });\n"
                "        }\n"
                "        try {\n"
                "          const inputUrl = typeof input === 'string' ? input : (input && input.url ? input.url : String(input));\n"
                "          const parsedUrl = new URL(inputUrl);\n"
                "          const isHttps = parsedUrl.protocol === 'https:';\n"
                "          const client = isHttps ? https : http;\n"
                "          const agent = isHttps ? httpsAgent : httpAgent;\n"
                "          const method = (init.method || (input && input.method) || 'GET').toUpperCase();\n"
                "          const outHeaders = {};\n"
                "          const inHeaders = init.headers || (input && input.headers);\n"
                "          if (inHeaders) {\n"
                "            if (typeof inHeaders.forEach === 'function') {\n"
                "              inHeaders.forEach((v, k) => { outHeaders[k] = v; });\n"
                "            } else if (Array.isArray(inHeaders)) {\n"
                "              for (const [k, v] of inHeaders) outHeaders[k] = v;\n"
                "            } else if (typeof inHeaders === 'object') {\n"
                "              Object.assign(outHeaders, inHeaders);\n"
                "            }\n"
                "          }\n"
                "          const rawBody = init.body !== undefined ? init.body : (input && input.body);\n"
                "          const { bodyBuf, isStreamBody } = normalizeBody(rawBody);\n"
                "          if (bodyBuf !== null) {\n"
                "            let hasLenOrTE = false;\n"
                "            for (const hk of Object.keys(outHeaders)) {\n"
                "              const low = hk.toLowerCase();\n"
                "              if (low === 'content-length' || low === 'transfer-encoding') {\n"
                "                hasLenOrTE = true;\n"
                "                break;\n"
                "              }\n"
                "            }\n"
                "            if (!hasLenOrTE) {\n"
                "              outHeaders['Content-Length'] = String(bodyBuf.length);\n"
                "            }\n"
                "          }\n"
                "          function runAttempt(attempt) {\n"
                "            if (settled) return;\n"
                "            let attemptDone = false;\n"
                "            let req = null;\n"
                "            function failAttempt(logTag, err) {\n"
                "              if (attemptDone || settled) return;\n"
                "              attemptDone = true;\n"
                "              writeLog(logTag, (err && err.message) ? err.message : String(err));\n"
                "              if (req) {\n"
                "                try { if (req.socket) req.socket.destroy(); } catch (_e) {}\n"
                "                try { req.destroy(); } catch (_e) {}\n"
                "              }\n"
                "              if (!isStreamBody && attempt < MAX_RETRIES && isRetryableNetError(err, signal)) {\n"
                "                evictHostFreeSockets(agent, parsedUrl.hostname);\n"
                "                const reason = (err && (err.code || err.message)) || 'unknown';\n"
                "                writeLog('FETCH_RETRY', `attempt=${attempt + 1}/${MAX_RETRIES} url=${inputUrl} reason=${reason}`);\n"
                "                retryTimer = setTimeout(() => {\n"
                "                  retryTimer = null;\n"
                "                  if (settled || (signal && signal.aborted)) return;\n"
                "                  runAttempt(attempt + 1);\n"
                "                }, 250 * (attempt + 1));\n"
                "                return;\n"
                "              }\n"
                "              settled = true;\n"
                "              cleanup();\n"
                "              reject(err);\n"
                "            }\n"
                "            try {\n"
                "              const reqOptions = {\n"
                "                protocol: parsedUrl.protocol,\n"
                "                hostname: parsedUrl.hostname,\n"
                "                port: parsedUrl.port || (isHttps ? 443 : 80),\n"
                "                path: parsedUrl.pathname + parsedUrl.search,\n"
                "                method,\n"
                "                headers: outHeaders,\n"
                "                agent,\n"
                "                rejectUnauthorized: false\n"
                "              };\n"
                "              req = client.request(reqOptions, (res) => {\n"
                "                const redirectMode = init.redirect || 'follow';\n"
                "                if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location && (redirectMode === 'error' || redirectMode === 'follow')) {\n"
                "                  res.resume();\n"
                "                  if (attemptDone || settled) return;\n"
                "                  attemptDone = true;\n"
                "                  settled = true;\n"
                "                  cleanup();\n"
                "                  if (redirectMode === 'error') {\n"
                "                    return reject(new Error('Redirect blocked: ' + res.statusCode + ' to ' + res.headers.location));\n"
                "                  }\n"
                "                  const nextUrl = new URL(res.headers.location, parsedUrl).toString();\n"
                "                  const nextInit = { ...init };\n"
                "                  if (res.statusCode === 303 || ((res.statusCode === 301 || res.statusCode === 302) && method === 'POST')) {\n"
                "                    nextInit.method = 'GET';\n"
                "                    delete nextInit.body;\n"
                "                  }\n"
                "                  return resolve(customFetch(nextUrl, nextInit));\n"
                "                }\n"
                "                const resHeaders = (typeof Headers !== 'undefined') ? new Headers() : new Map();\n"
                "                for (const [key, val] of Object.entries(res.headers)) {\n"
                "                  if (Array.isArray(val)) {\n"
                "                    val.forEach(v => {\n"
                "                      if (resHeaders.append) resHeaders.append(key, v);\n"
                "                      else resHeaders.set(key, v);\n"
                "                    });\n"
                "                  } else if (val !== undefined) {\n"
                "                    resHeaders.set(key, val);\n"
                "                  }\n"
                "                }\n"
                "                const chunks = [];\n"
                "                res.on('data', chunk => chunks.push(chunk));\n"
                "                res.on('end', () => {\n"
                "                  if (attemptDone || settled) return;\n"
                "                  attemptDone = true;\n"
                "                  settled = true;\n"
                "                  cleanup();\n"
                "                  const bodyBuffer = Buffer.concat(chunks);\n"
                "                  const status = res.statusCode || 200;\n"
                "                  const statusText = res.statusMessage || '';\n"
                "                  const ok = status >= 200 && status < 300;\n"
                "                  let respObj;\n"
                "                  if (typeof Response !== 'undefined') {\n"
                "                    try {\n"
                "                      respObj = new Response(bodyBuffer, {\n"
                "                        status,\n"
                "                        statusText,\n"
                "                        headers: resHeaders\n"
                "                      });\n"
                "                    } catch (_e) {}\n"
                "                  }\n"
                "                  if (!respObj) {\n"
                "                    respObj = {\n"
                "                      status,\n"
                "                      statusText,\n"
                "                      ok,\n"
                "                      headers: resHeaders,\n"
                "                      url: parsedUrl.toString(),\n"
                "                      text: async () => bodyBuffer.toString('utf8'),\n"
                "                      json: async () => JSON.parse(bodyBuffer.toString('utf8')),\n"
                "                      arrayBuffer: async () => bodyBuffer.buffer.slice(bodyBuffer.byteOffset, bodyBuffer.byteOffset + bodyBuffer.byteLength),\n"
                "                      body: { cancel: async () => {} }\n"
                "                    };\n"
                "                  }\n"
                "                  resolve(respObj);\n"
                "                });\n"
                "                res.on('error', err => failAttempt('FETCH_RES_ERR', err));\n"
                "              });\n"
                "              activeReq = req;\n"
                "              req.on('error', err => failAttempt('FETCH_REQ_ERR', err));\n"
                "              if (bodyBuf !== null) {\n"
                "                req.write(bodyBuf);\n"
                "                req.end();\n"
                "              } else if (isStreamBody) {\n"
                "                rawBody.pipe(req);\n"
                "              } else {\n"
                "                req.end();\n"
                "              }\n"
                "            } catch (err) {\n"
                "              failAttempt('FETCH_EX', err);\n"
                "            }\n"
                "          }\n"
                "          runAttempt(0);\n"
                "        } catch (err) {\n"
                "          if (!settled) {\n"
                "            settled = true;\n"
                "            cleanup();\n"
                "            writeLog('FETCH_EX', err.message);\n"
                "            reject(err);\n"
                "          }\n"
                "        }\n"
                "      });\n"
                "    };\n"
                "  }\n"
                "  globalThis.fetch = createFetchPolyfill();\n"
                "  writeLog('PRELOAD_FETCH', 'Fetch polyfill installed successfully');\n"
                "} catch(e) { writeLog('PRELOAD_FETCH_ERR', 'fetch polyfill error: ' + e); }\n";
            fputs(script.c_str(), pfp);
            fclose(pfp);
        }

        // 4. Assemble arguments
        std::string bin_path = options.runtime_root + "/node_modules/@deepseek-ai/dsh/lib/bin.js";
        if (access(bin_path.c_str(), R_OK) != 0) {
            std::string alt = options.runtime_root + "/lib/bin.js";
            if (access(alt.c_str(), R_OK) == 0) bin_path = alt;
        }

        std::vector<std::string> args = {
            "node",
            "--jitless",
            "--expose-internals",
            "-r",
            preload_js,
            bin_path,
            "web",
            "--host",
            "127.0.0.1",
            "--port",
            "38927",
            "--no-open"
        };
        for (const auto& extra : options.extra_args) {
            args.push_back(extra);
        }

        std::vector<char*> argv_ptrs;
        for (auto& s : args) {
            argv_ptrs.push_back(s.data());
        }
        argv_ptrs.push_back(nullptr);

        // 5. Ensure STDIN_FILENO is a valid, pollable descriptor to prevent libuv epoll_ctl abort
#if defined(__linux__) || defined(__OHOS__) || defined(__aarch64__)
#if __has_include(<sys/epoll.h>)
        int test_epfd = epoll_create1(0);
        bool stdin_pollable = false;
        if (test_epfd >= 0) {
            struct epoll_event ev{};
            ev.events = EPOLLIN;
            if (epoll_ctl(test_epfd, EPOLL_CTL_ADD, STDIN_FILENO, &ev) == 0) {
                stdin_pollable = true;
                epoll_ctl(test_epfd, EPOLL_CTL_DEL, STDIN_FILENO, nullptr);
            }
            close(test_epfd);
        }
        if (!stdin_pollable) {
            int pfd[2];
            if (pipe(pfd) == 0) {
                dup2(pfd[0], STDIN_FILENO);
                close(pfd[0]);
                close(pfd[1]); // Write end closed: immediate EOF on read, but fd 0 is guaranteed pollable by epoll
                OH_LOG_Print(LOG_APP, LOG_INFO, 0x3201, "DSHHost", "Emulated pollable STDIN pipe for libuv.");
            }
        }
#endif
#endif

        // Run node without stdio hijacking to prevent ArkWeb log thrashing
        DisableFdsan();

        OH_LOG_Print(LOG_APP, LOG_INFO, 0x3201, "DSHHost", "Invoking node::Start with bin=%{public}s", bin_path.c_str());

        // 6. Run node
        int code = node_start(static_cast<int>(args.size()), argv_ptrs.data());

        OH_LOG_Print(LOG_APP, LOG_INFO, 0x3201, "DSHHost", "node::Start exited with code %{public}d", code);

        is_running_.store(false);
        DshState::GetInstance().SetExited(code);
        NotifyEvent("status", "{\"phase\":\"exited\",\"exitCode\":" + std::to_string(code) + "}");
    });

    NotifyEvent("status", "{\"phase\":\"starting\"}");
    return true;
}

void DshHost::Stop() {
    if (!is_running_.exchange(false)) {
        return;
    }

    stop_requested_.store(true);

    StopToolBridgeServer();

    if (status_watcher_thread_.joinable()) {
        status_watcher_thread_.join();
    }

    if (runner_thread_.joinable()) {
        runner_thread_.join();
    }

    DshState::GetInstance().SetExited(0);
    NotifyEvent("status", "{\"phase\":\"exited\",\"exitCode\":0}");
}

bool DshHost::IsRunning() const {
    return is_running_.load();
}

DshHostSnapshot DshHost::GetSnapshot() {
    return DshState::GetInstance().GetSnapshot();
}

void DshHost::StatusWatcherThread() {
    std::string ready_file = current_options_.workspace_root + "/ready.json";

    while (!stop_requested_.load()) {
        bool is_running = (DshState::GetInstance().GetSnapshot().phase == "running");
        if (!is_running) {
            FILE* rfp = fopen(ready_file.c_str(), "r");
            if (rfp) {
                char rbuf[512];
                size_t n = fread(rbuf, 1, sizeof(rbuf) - 1, rfp);
                fclose(rfp);
                if (n > 0) {
                    rbuf[n] = '\0';
                    std::string content(rbuf);
                    size_t p_pos = content.find("\"port\":");
                    size_t b_pos = content.find("\"baseUrl\":\"");
                    size_t t_pos = content.find("\"token\":\"");
                    if (p_pos != std::string::npos && b_pos != std::string::npos && t_pos != std::string::npos) {
                        int port = std::atoi(content.c_str() + p_pos + 7);
                        size_t b_end = content.find("\"", b_pos + 11);
                        std::string base_url = content.substr(b_pos + 11, b_end - (b_pos + 11));
                        size_t t_end = content.find("\"", t_pos + 9);
                        std::string token = content.substr(t_pos + 9, t_end - (t_pos + 9));
                        if (port > 0 && !token.empty()) {
                            DshState::GetInstance().SetReady(port, base_url, token);
                            NotifyEvent("ready", content);
                            is_running = true;
                        }
                    }
                }
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(is_running ? 2000 : 150));
    }
}

void DshHost::ProcessLine(const std::string& stream, const std::string& line) {
    // Filter out high-frequency ArkWeb/Chromium noise from stdout/stderr
    if (line.find("ExternalBeginFrameSourceOHOS") != std::string::npos ||
        line.find("ThrottleRatio") != std::string::npos ||
        line.find("DVsyncController") != std::string::npos ||
        line.find("kDefaultPassthroughCommandDecoder") != std::string::npos ||
        line.find("CefCookieManagerImpl") != std::string::npos ||
        line.find("ResReporter") != std::string::npos ||
        line.find("PRPPreload") != std::string::npos ||
        line.find("SetVsyncEnabled") != std::string::npos ||
        line.find("BlankScreenDetector") != std::string::npos) {
        return;
    }

    OH_LOG_Print(LOG_APP, LOG_INFO, 0x3201, "DSHNode", "[%{public}s] %{public}s", stream.c_str(), line.c_str());

    // Look for DSH ready line pattern:
    // "dsh web: http://127.0.0.1:38927/?token=..." or "http://127.0.0.1:PORT/?token=TOKEN"
    const std::string web_prefix = "http://127.0.0.1:";
    size_t prefix_pos = line.find(web_prefix);
    if (prefix_pos != std::string::npos) {
        size_t port_start = prefix_pos + web_prefix.size();
        size_t token_marker = line.find("/?token=", port_start);
        if (token_marker != std::string::npos) {
            std::string port_str = line.substr(port_start, token_marker - port_start);
            int port = std::atoi(port_str.c_str());
            size_t token_start = token_marker + 8;
            size_t token_end = line.find_first_of(" \t\r\n", token_start);
            std::string token = line.substr(token_start, token_end == std::string::npos ? std::string::npos : token_end - token_start);

            if (port > 0 && !token.empty()) {
                std::string base_url = "http://127.0.0.1:" + std::to_string(port);
                DshState::GetInstance().SetReady(port, base_url, token);
                std::string ready_json = "{\"phase\":\"running\",\"port\":" + std::to_string(port) +
                                         ",\"baseUrl\":\"" + base_url + "\",\"token\":\"" + token + "\"}";
                NotifyEvent("ready", ready_json);
            }
        }
    }

    NotifyEvent("log", "{\"stream\":\"" + stream + "\",\"line\":\"" + line + "\"}");
}

static std::string ToolJsonEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 16);
    for (char c : s) {
        if (c == '"') out += "\\\"";
        else if (c == '\\') out += "\\\\";
        else if (c == '\b') out += "\\b";
        else if (c == '\f') out += "\\f";
        else if (c == '\n') out += "\\n";
        else if (c == '\r') out += "\\r";
        else if (c == '\t') out += "\\t";
        else if (static_cast<unsigned char>(c) < 0x20) {
            char b[8];
            snprintf(b, sizeof(b), "\\u%04x", c);
            out += b;
        } else {
            out += c;
        }
    }
    return out;
}

void DshHost::StartToolBridgeServer() {
    if (tool_server_running_.load()) return;
    tool_server_fd_ = socket(AF_INET, SOCK_STREAM, 0);
    if (tool_server_fd_ < 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x3201, "DSHHost", "Failed to create tool bridge socket: %{public}d", errno);
        return;
    }
    int opt = 1;
    setsockopt(tool_server_fd_, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(38081);

    if (bind(tool_server_fd_, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x3201, "DSHHost", "Failed to bind tool bridge socket: %{public}d", errno);
        close(tool_server_fd_);
        tool_server_fd_ = -1;
        return;
    }
    if (listen(tool_server_fd_, 16) != 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x3201, "DSHHost", "Failed to listen on tool bridge socket: %{public}d", errno);
        close(tool_server_fd_);
        tool_server_fd_ = -1;
        return;
    }

    tool_server_running_.store(true);
    tool_server_thread_ = std::thread([this]() {
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x3201, "DSHHost", "Tool bridge server listening on 127.0.0.1:38081");
        while (tool_server_running_.load()) {
            struct pollfd pfd;
            pfd.fd = tool_server_fd_;
            pfd.events = POLLIN;
            int pr = poll(&pfd, 1, 500);
            if (pr <= 0) continue;

            sockaddr_in client_addr{};
            socklen_t client_len = sizeof(client_addr);
            int cfd = accept(tool_server_fd_, (struct sockaddr*)&client_addr, &client_len);
            if (cfd < 0) continue;

            std::thread([this, cfd]() {
                HandleToolHttpRequest(cfd);
                close(cfd);
            }).detach();
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x3201, "DSHHost", "Tool bridge server stopped.");
    });
}

void DshHost::StopToolBridgeServer() {
    tool_server_running_.store(false);
    if (tool_server_fd_ >= 0) {
        shutdown(tool_server_fd_, SHUT_RDWR);
        close(tool_server_fd_);
        tool_server_fd_ = -1;
    }
    if (tool_server_thread_.joinable()) {
        tool_server_thread_.join();
    }
}

static void SkipJsonWs(const std::string& s, size_t& i) {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) {
        ++i;
    }
}

static bool ParseJsonString(const std::string& s, size_t& i, std::string& out) {
    if (i >= s.size() || s[i] != '"') {
        return false;
    }
    ++i;
    out.clear();
    while (i < s.size()) {
        char c = s[i++];
        if (c == '"') {
            return true;
        }
        if (c == '\\') {
            if (i >= s.size()) {
                return false;
            }
            char esc = s[i++];
            switch (esc) {
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'n': out.push_back('\n'); break;
                case 'r': out.push_back('\r'); break;
                case 't': out.push_back('\t'); break;
                case 'u': {
                    if (i + 4 > s.size()) {
                        return false;
                    }
                    uint32_t cp = 0;
                    for (int k = 0; k < 4; ++k) {
                        char h = s[i++];
                        cp <<= 4;
                        if (h >= '0' && h <= '9') cp |= static_cast<uint32_t>(h - '0');
                        else if (h >= 'a' && h <= 'f') cp |= static_cast<uint32_t>(h - 'a' + 10);
                        else if (h >= 'A' && h <= 'F') cp |= static_cast<uint32_t>(h - 'A' + 10);
                        else return false;
                    }
                    if (cp < 0x80) {
                        out.push_back(static_cast<char>(cp));
                    } else if (cp < 0x800) {
                        out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
                        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                    } else {
                        out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
                        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                    }
                    break;
                }
                default:
                    out.push_back(esc);
                    break;
            }
        } else {
            out.push_back(c);
        }
    }
    return false;
}

static bool SkipJsonValue(const std::string& s, size_t& i) {
    SkipJsonWs(s, i);
    if (i >= s.size()) {
        return false;
    }
    char c = s[i];
    if (c == '"') {
        std::string tmp;
        return ParseJsonString(s, i, tmp);
    }
    if (c == '{' || c == '[') {
        int depth = 1;
        bool in_str = false;
        bool esc = false;
        ++i;
        while (i < s.size() && depth > 0) {
            char ch = s[i++];
            if (in_str) {
                if (esc) {
                    esc = false;
                } else if (ch == '\\') {
                    esc = true;
                } else if (ch == '"') {
                    in_str = false;
                }
            } else {
                if (ch == '"') {
                    in_str = true;
                } else if (ch == '{' || ch == '[') {
                    ++depth;
                } else if (ch == '}' || ch == ']') {
                    --depth;
                }
            }
        }
        return depth == 0;
    }
    size_t start = i;
    while (i < s.size() && s[i] != ',' && s[i] != '}' && s[i] != ']' &&
           s[i] != ' ' && s[i] != '\t' && s[i] != '\r' && s[i] != '\n') {
        ++i;
    }
    return i > start;
}

bool ParseToolHttpBodyJson(const std::string& body, ParsedToolHttpBody& out) {
    out = ParsedToolHttpBody{};
    size_t i = 0;
    SkipJsonWs(body, i);
    if (i >= body.size() || body[i] != '{') {
        return false;
    }
    ++i;
    SkipJsonWs(body, i);
    if (i < body.size() && body[i] == '}') {
        return true;
    }
    while (i < body.size()) {
        SkipJsonWs(body, i);
        std::string key;
        if (!ParseJsonString(body, i, key)) {
            return false;
        }
        SkipJsonWs(body, i);
        if (i >= body.size() || body[i] != ':') {
            return false;
        }
        ++i;
        SkipJsonWs(body, i);
        if (i >= body.size()) {
            return false;
        }

        if (key == "requestId" && body[i] == '"') {
            if (!ParseJsonString(body, i, out.request_id)) {
                return false;
            }
        } else if (key == "tool" && body[i] == '"') {
            if (!ParseJsonString(body, i, out.tool)) {
                return false;
            }
        } else if (key == "args" && body[i] == '{') {
            size_t start = i;
            if (!SkipJsonValue(body, i)) {
                return false;
            }
            out.args_json = body.substr(start, i - start);
        } else if (key == "deadlineMs" && (isdigit(static_cast<unsigned char>(body[i])) || body[i] == '-')) {
            size_t start = i;
            if (body[i] == '-') {
                ++i;
            }
            while (i < body.size() && isdigit(static_cast<unsigned char>(body[i]))) {
                ++i;
            }
            if (i > start) {
                try {
                    out.deadline_ms = std::stoll(body.substr(start, i - start));
                } catch (...) {
                    out.deadline_ms = 0;
                }
            }
        } else {
            if (!SkipJsonValue(body, i)) {
                return false;
            }
        }

        SkipJsonWs(body, i);
        if (i >= body.size()) {
            return false;
        }
        if (body[i] == ',') {
            ++i;
            continue;
        }
        if (body[i] == '}') {
            return true;
        }
        return false;
    }
    return false;
}

int ComputePollTimeoutMs(int64_t deadline_ms, int64_t now_epoch_ms) {
    if (deadline_ms <= 0) {
        return 60000;
    }
    int64_t diff = deadline_ms - now_epoch_ms;
    if (diff < 1000) {
        return 1000;
    }
    if (diff > 310000) {
        return 310000;
    }
    return static_cast<int>(diff);
}

bool ParseHostReadyBodyJson(const std::string& body, int& port, std::string& base_url, std::string& token) {
    port = 0;
    base_url.clear();
    token.clear();
    size_t i = 0;
    SkipJsonWs(body, i);
    if (i >= body.size() || body[i] != '{') {
        return false;
    }
    ++i;
    SkipJsonWs(body, i);
    if (i < body.size() && body[i] == '}') {
        return false;
    }
    while (i < body.size()) {
        SkipJsonWs(body, i);
        std::string key;
        if (!ParseJsonString(body, i, key)) {
            return false;
        }
        SkipJsonWs(body, i);
        if (i >= body.size() || body[i] != ':') {
            return false;
        }
        ++i;
        SkipJsonWs(body, i);
        if (i >= body.size()) {
            return false;
        }
        if (key == "port" && isdigit(static_cast<unsigned char>(body[i]))) {
            size_t start = i;
            while (i < body.size() && isdigit(static_cast<unsigned char>(body[i]))) {
                ++i;
            }
            try {
                port = std::stoi(body.substr(start, i - start));
            } catch (...) {
                port = 0;
            }
        } else if (key == "baseUrl" && body[i] == '"') {
            if (!ParseJsonString(body, i, base_url)) {
                return false;
            }
        } else if (key == "token" && body[i] == '"') {
            if (!ParseJsonString(body, i, token)) {
                return false;
            }
        } else {
            if (!SkipJsonValue(body, i)) {
                return false;
            }
        }
        SkipJsonWs(body, i);
        if (i >= body.size()) {
            return false;
        }
        if (body[i] == ',') {
            ++i;
            continue;
        }
        if (body[i] == '}') {
            return port > 0 && port <= 65535 && !base_url.empty() && !token.empty();
        }
        return false;
    }
    return false;
}

void DshHost::HandleToolHttpRequest(int cfd) {
    std::string req_data;
    char buf[2048];
    ssize_t n;
    size_t header_end = std::string::npos;

    while ((header_end = req_data.find("\r\n\r\n")) == std::string::npos) {
        n = recv(cfd, buf, sizeof(buf), 0);
        if (n <= 0) return;
        req_data.append(buf, n);
    }

    std::string req_path = "/v1/tool/execute";
    size_t line_end = req_data.find("\r\n");
    if (line_end != std::string::npos) {
        std::string first_line = req_data.substr(0, line_end);
        size_t sp1 = first_line.find(' ');
        if (sp1 != std::string::npos) {
            size_t sp2 = first_line.find(' ', sp1 + 1);
            if (sp2 != std::string::npos && sp2 > sp1 + 1) {
                req_path = first_line.substr(sp1 + 1, sp2 - sp1 - 1);
            }
        }
    }

    size_t content_length = 0;
    size_t cl_pos = req_data.find("Content-Length: ");
    if (cl_pos == std::string::npos) cl_pos = req_data.find("content-length: ");
    if (cl_pos != std::string::npos) {
        size_t cl_end = req_data.find("\r\n", cl_pos);
        if (cl_end != std::string::npos) {
            content_length = std::stoul(req_data.substr(cl_pos + 16, cl_end - (cl_pos + 16)));
        }
    }

    size_t body_start = header_end + 4;
    while (req_data.size() - body_start < content_length) {
        n = recv(cfd, buf, sizeof(buf), 0);
        if (n <= 0) break;
        req_data.append(buf, n);
    }

    std::string body = (content_length > 0 && req_data.size() >= body_start + content_length)
        ? req_data.substr(body_start, content_length)
        : req_data.substr(body_start);
    OH_LOG_Print(LOG_APP, LOG_DEBUG, 0x3201, "DSHHost", "Tool HTTP Request (%{public}s): %{public}s", req_path.c_str(), body.c_str());

    if (req_path == "/v1/host/ready") {
        int r_port = 0;
        std::string r_base_url;
        std::string r_token;
        bool ok = ParseHostReadyBodyJson(body, r_port, r_base_url, r_token);
        if (ok) {
            swshell::DshState::GetInstance().SetReady(r_port, r_base_url, r_token);
            NotifyEvent("ready", body);
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x3201, "DSHHost",
                         "Fast ready notification received: port=%{public}d", r_port);
        }
        std::string resp_json = std::string("{\"ok\":") + (ok ? "true" : "false") + "}";
        std::string http_resp = "HTTP/1.1 200 OK\r\n"
                                "Content-Type: application/json\r\n"
                                "Content-Length: " + std::to_string(resp_json.size()) + "\r\n"
                                "Connection: close\r\n\r\n" + resp_json;
        send(cfd, http_resp.data(), http_resp.size(), 0);
        return;
    }

    ParsedToolHttpBody parsed;
    ParseToolHttpBodyJson(body, parsed);

    if (req_path == "/v1/tool/cancel") {
        bool cancelled = false;
        if (!parsed.request_id.empty()) {
            cancelled = swshell::DshState::GetInstance().CancelToolFromNode(parsed.request_id);
        }
        std::string resp_json = std::string("{\"ok\":true,\"cancelled\":") + (cancelled ? "true" : "false") + "}";
        std::string http_resp = "HTTP/1.1 200 OK\r\n"
                                "Content-Type: application/json\r\n"
                                "Content-Length: " + std::to_string(resp_json.size()) + "\r\n"
                                "Connection: close\r\n\r\n" + resp_json;
        send(cfd, http_resp.data(), http_resp.size(), 0);
        return;
    }

    std::string req_id = !parsed.request_id.empty()
        ? parsed.request_id
        : ("req-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::string tool = !parsed.tool.empty() ? parsed.tool : "bash";
    std::string args_json = !parsed.args_json.empty() ? parsed.args_json : "{}";

    swshell::DshToolRequest treq;
    treq.request_id = req_id;
    treq.tool = tool;
    treq.args_json = args_json;
    treq.deadline_ms = parsed.deadline_ms;

    OH_LOG_Print(LOG_APP, LOG_INFO, 0x3201, "DSHHost",
                 "Dispatching tool to ArkTS: req_id=%{public}s tool=%{public}s",
                 req_id.c_str(), tool.c_str());

    std::string resp_json;
    if (!swshell::DshState::GetInstance().DispatchToolFromNode(treq)) {
        resp_json = "{\"ok\":false,\"output\":\"\",\"error\":\"DSH host is not running\",\"exitCode\":-1}";
    } else {
        int64_t now_epoch_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        int poll_ms = ComputePollTimeoutMs(treq.deadline_ms, now_epoch_ms);

        swshell::DshToolResponse resp;
        int res = swshell::DshState::GetInstance().PollToolResultForNode(req_id, resp, poll_ms);

        if (res == 1) { // Succeeded/Finished
            resp_json = "{\"ok\":" + std::string(resp.success ? "true" : "false") +
                        ",\"output\":\"" + ToolJsonEscape(resp.output) + "\"" +
                        ",\"error\":\"" + ToolJsonEscape(resp.error) + "\"" +
                        ",\"exitCode\":" + std::to_string(resp.exit_code) + "}";
        } else if (res == 2) { // Cancelled
            resp_json = "{\"ok\":false,\"output\":\"\",\"error\":\"Tool execution cancelled\",\"exitCode\":-1}";
        } else { // Timeout / pending
            resp_json = "{\"ok\":false,\"output\":\"\",\"error\":\"Tool execution timed out\",\"exitCode\":-1}";
        }
    }

    std::string http_resp = "HTTP/1.1 200 OK\r\n"
                            "Content-Type: application/json\r\n"
                            "Content-Length: " + std::to_string(resp_json.size()) + "\r\n"
                            "Connection: close\r\n\r\n" + resp_json;
    send(cfd, http_resp.data(), http_resp.size(), 0);
}

} // namespace swshell
