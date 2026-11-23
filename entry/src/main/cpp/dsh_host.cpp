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
        // Emulate return value -ENOSYS in register x0
        uc->uc_mcontext.regs[0] = static_cast<unsigned long>(-ENOSYS);
        // Advance PC past the 4-byte svc #0 instruction
        uc->uc_mcontext.pc += 4;
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

    DshState::GetInstance().SetStarting();
    is_running_.store(true);

    status_watcher_thread_ = std::thread([this]() {
        StatusWatcherThread();
    });

    StartToolBridgeServer();

    runner_thread_ = std::thread([this, options]() {
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xD051, "DSHHost", "DSH host runner thread starting...");

        // 1. Locate and dlopen libnode.so
        void* node_handle = dlopen("libnode.so", RTLD_NOW | RTLD_GLOBAL);
        if (!node_handle && !options.custom_node_path.empty()) {
            node_handle = dlopen(options.custom_node_path.c_str(), RTLD_NOW | RTLD_GLOBAL);
        }
        if (!node_handle) {
            node_handle = dlopen("/data/storage/el1/bundle/libs/arm64/libnode.so", RTLD_NOW | RTLD_GLOBAL);
        }
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
            chdir(options.workspace_root.c_str());
            umask(0);

            setenv("HOME", options.workspace_root.c_str(), 1);
            setenv("DSH_HOME", dsh_dir.c_str(), 1);

            // Write $DSH_HOME/cordis.patch.yml so DSH automatically loads Swai & PiHA tools/mcp
            std::string home_patch_yml = dsh_dir + "/cordis.patch.yml";
            std::string tools_mjs = options.runtime_root + "/bridge/swai-tools.mjs";
            FILE* hpf = fopen(home_patch_yml.c_str(), "w");
            if (hpf) {
                fprintf(hpf,
                    "- insert:\n"
                    "    - id: swai-tools\n"
                    "      name: \"%s\"\n"
                    "    - id: swai-mcp\n"
                    "      name: \"@deepseek-ai/dsh-mcp-client\"\n"
                    "      config:\n"
                    "        transport: \"streamable-http\"\n"
                    "        serverName: \"swai\"\n"
                    "        url: \"http://127.0.0.1:39001/mcp\"\n"
                    "    - id: piha-mcp\n"
                    "      name: \"@deepseek-ai/dsh-mcp-client\"\n"
                    "      config:\n"
                    "        transport: \"streamable-http\"\n"
                    "        serverName: \"piha\"\n"
                    "        url: \"http://127.0.0.1:39001/mcp\"\n",
                    tools_mjs.c_str());
                fclose(hpf);
            }
        }
        std::string node_modules = options.runtime_root + "/node_modules";
        setenv("NODE_PATH", node_modules.c_str(), 1);

        // 3. Create preload.js to prevent process.exit from killing host app, intercept signals, and capture unhandled errors
        std::string preload_js = options.workspace_root + "/preload.js";
        FILE* pfp = fopen(preload_js.c_str(), "w");
        if (pfp) {
            std::string script =
                "const fs = require('fs');\n"
                "const path = require('path');\n"
                "const { Readable } = require('stream');\n"
                "const { EventEmitter } = require('events');\n"
                "const home = process.env.HOME || '.';\n"
                "const logFile = path.join(home, 'stderr.log');\n"
                "const outLogFile = path.join(home, 'stdout.log');\n"
                "const readyFile = path.join(home, 'ready.json');\n"
                "try { fs.chmodSync(home, 0o777); } catch(e){}\n"
                "function writeLog(prefix, msg) {\n"
                "  try { fs.appendFileSync(logFile, `[${new Date().toISOString()}] ${prefix}: ${msg}\\n`); } catch(e){}\n"
                "}\n"
                "writeLog('PRELOAD', 'Node preload script executing...');\n"
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
                "const signalHandlers = new Map();\n"
                "const origOn = process.on.bind(process);\n"
                "const origAddListener = process.addListener.bind(process);\n"
                "const origPrepend = process.prependListener.bind(process);\n"
                "const origOnce = process.once.bind(process);\n"
                "const origRemove = process.removeListener.bind(process);\n"
                "function isSignal(name) {\n"
                "  return typeof name === 'string' && /^SIG[A-Z0-9]+$/.test(name);\n"
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
                "  return origOn.apply(this, arguments);\n"
                "};\n"
                "process.addListener = function(ev, fn) {\n"
                "  if (handleSignal(ev, fn, false)) return process;\n"
                "  return origAddListener.apply(this, arguments);\n"
                "};\n"
                "process.prependListener = function(ev, fn) {\n"
                "  if (handleSignal(ev, fn, false)) return process;\n"
                "  return origPrepend.apply(this, arguments);\n"
                "};\n"
                "process.once = function(ev, fn) {\n"
                "  if (handleSignal(ev, fn, true)) return process;\n"
                "  return origOnce.apply(this, arguments);\n"
                "};\n"
                "process.removeListener = function(ev, fn) {\n"
                "  if (isSignal(ev)) {\n"
                "    let list = signalHandlers.get(ev) || [];\n"
                "    signalHandlers.set(ev, list.filter(item => item.fn !== fn));\n"
                "    return process;\n"
                "  }\n"
                "  return origRemove.apply(this, arguments);\n"
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
                "      fs.appendFileSync(outLogFile, chunk);\n"
                "      const str = chunk.toString();\n"
                "      const m = str.match(/http:\\/\\/127\\.0\\.0\\.1:(\\d+)\\/\\?token=([a-zA-Z0-9_\\-]+)/);\n"
                "      if (m) {\n"
                "        const info = {\n"
                "          phase: 'running',\n"
                "          port: parseInt(m[1], 10),\n"
                "          baseUrl: 'http://127.0.0.1:' + m[1],\n"
                "          token: m[2],\n"
                "          url: m[0]\n"
                "        };\n"
                "        fs.writeFileSync(readyFile, JSON.stringify(info));\n"
                "        writeLog('READY', `DSH Web Server is ready at ${info.url}`);\n"
                "      }\n"
                "    } catch(e){}\n"
                "    return origStdoutWrite(chunk, encoding, cb);\n"
                "  };\n"
                "} catch(e) {}\n"
                "try {\n"
                "  const origStderrWrite = process.stderr.write.bind(process.stderr);\n"
                "  process.stderr.write = function(chunk, encoding, cb) {\n"
                "    try {\n"
                "      const str = chunk.toString();\n"
                "      if (!str.startsWith('[../../arkweb/') && !str.startsWith('[../../content/') && !str.startsWith('[../../cef/') && !str.startsWith('[../../ohos_nweb/') && !str.startsWith('[../../media/') && !str.startsWith('[../../net/')) {\n"
                "        fs.appendFileSync(logFile, chunk);\n"
                "      }\n"
                "    } catch(e){}\n"
                "    return origStderrWrite(chunk, encoding, cb);\n"
                "  };\n"
                "} catch(e) {}\n"
                "process.on('uncaughtException', (err, origin) => {\n"
                "  const msg = err && err.stack ? err.stack : String(err);\n"
                "  writeLog('UNCAUGHT_EXCEPTION', `${origin} - ${msg}`);\n"
                "  console.error('DSH UNCAUGHT EXCEPTION:', origin, msg);\n"
                "});\n"
                "process.on('unhandledRejection', (reason) => {\n"
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
                "    return h;\n"
                "  };\n"
                "} catch(e) { writeLog('PRELOAD_LINK_ERR', 'link/chmod shim: ' + e); }\n"
                "try {\n"
                "  const origFspStat = fsp.stat;\n"
                "  fsp.stat = async function(p, opts) {\n"
                "    try { return await origFspStat.call(this, p, opts); } catch (err) {\n"
                "      if (err && err.code === 'ENOENT' && typeof p === 'string') {\n"
                "        const pNorm = p.split('\\\\').join('/');\n"
                "        const homeNorm = (home || '').split('\\\\').join('/');\n"
                "        if (pNorm.includes('/workspace/workspace') || pNorm.endsWith(' ') || (homeNorm && pNorm.startsWith(homeNorm) && (pNorm.endsWith('/workspace') || pNorm.includes('/workspace/')))) {\n"
                "          try { fs.mkdirSync(p, { recursive: true }); return await origFspStat.call(this, p, opts); } catch(_e) {}\n"
                "        }\n"
                "      }\n"
                "      throw err;\n"
                "    }\n"
                "  };\n"
                "  const origFsStatSync = fs.statSync;\n"
                "  fs.statSync = function(p, opts) {\n"
                "    try { return origFsStatSync.call(this, p, opts); } catch (err) {\n"
                "      if (err && err.code === 'ENOENT' && typeof p === 'string') {\n"
                "        const pNorm = p.split('\\\\').join('/');\n"
                "        const homeNorm = (home || '').split('\\\\').join('/');\n"
                "        if (pNorm.includes('/workspace/workspace') || pNorm.endsWith(' ') || (homeNorm && pNorm.startsWith(homeNorm) && (pNorm.endsWith('/workspace') || pNorm.includes('/workspace/')))) {\n"
                "          try { fs.mkdirSync(p, { recursive: true }); return origFsStatSync.call(this, p, opts); } catch(_e) {}\n"
                "        }\n"
                "      }\n"
                "      throw err;\n"
                "    }\n"
                "  };\n"
                "} catch(e) { writeLog('PRELOAD_STAT_ERR', 'stat shim: ' + e); }\n"
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
                "    if (targetCwd && !effectiveCmd.startsWith('cd ') && !effectiveCmd.startsWith('cd/')) {\n"
                "      effectiveCmd = `cd ${JSON.stringify(targetCwd)} && ${effectiveCmd}`;\n"
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
                "    let req = null;\n"
                "    child.kill = function(sig) {\n"
                "      child.killed = true;\n"
                "      child.signalCode = sig || 'SIGTERM';\n"
                "      if (req && !req.destroyed) { try { req.destroy(); } catch(e){} }\n"
                "      return true;\n"
                "    };\n"
                "    process.nextTick(() => {\n"
                "      child.emit('spawn');\n"
                "      const reqData = JSON.stringify({\n"
                "        requestId: `dsh-cp-${Date.now()}-${pid}`,\n"
                "        tool: 'bash',\n"
                "        args: { command: effectiveCmd },\n"
                "        deadlineMs: Date.now() + 60000\n"
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
                "        timeout: 60000\n"
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
                "  process.env.SWAI_AUTO_START_MCP = '1';\n"
                "  process.env.PIHA_AUTO_START_MCP = '1';\n"
                "  const mcpPath = '" + options.runtime_root + "/bridge/swai-mcp-server.mjs';\n"
                "  import(mcpPath).then(() => {\n"
                "    writeLog('PRELOAD_MCP', 'Swai MCP server started on 39001');\n"
                "  }).catch(e => {\n"
                "    writeLog('PRELOAD_MCP_ERR', 'Failed to start Swai MCP server: ' + e);\n"
                "  });\n"
                "} catch(e) { writeLog('PRELOAD_MCP_EX', 'Swai MCP exception: ' + e); }\n"
                "try {\n"
                "  const https = require('https');\n"
                "  const http = require('http');\n"
                "  const { URL } = require('url');\n"
                "  function createFetchPolyfill() {\n"
                "    return function customFetch(input, init = {}) {\n"
                "      return new Promise((resolve, reject) => {\n"
                "        try {\n"
                "          const inputUrl = typeof input === 'string' ? input : (input && input.url ? input.url : String(input));\n"
                "          writeLog('FETCH', 'fetch called: ' + inputUrl);\n"
                "          const parsedUrl = new URL(inputUrl);\n"
                "          const isHttps = parsedUrl.protocol === 'https:';\n"
                "          const client = isHttps ? https : http;\n"
                "          const method = (init.method || (input && input.method) || 'GET').toUpperCase();\n"
                "          const signal = init.signal || (input && input.signal);\n"
                "          if (signal && signal.aborted) {\n"
                "            const err = new Error('This operation was aborted');\n"
                "            err.name = 'AbortError';\n"
                "            return reject(err);\n"
                "          }\n"
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
                "          const reqOptions = {\n"
                "            protocol: parsedUrl.protocol,\n"
                "            hostname: parsedUrl.hostname,\n"
                "            port: parsedUrl.port || (isHttps ? 443 : 80),\n"
                "            path: parsedUrl.pathname + parsedUrl.search,\n"
                "            method,\n"
                "            headers: outHeaders,\n"
                "            rejectUnauthorized: false\n"
                "          };\n"
                "          const req = client.request(reqOptions, (res) => {\n"
                "            const redirectMode = init.redirect || 'follow';\n"
                "            if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {\n"
                "              if (redirectMode === 'error') {\n"
                "                const err = new Error('Redirect blocked: ' + res.statusCode + ' to ' + res.headers.location);\n"
                "                return reject(err);\n"
                "              } else if (redirectMode === 'follow') {\n"
                "                const nextUrl = new URL(res.headers.location, parsedUrl).toString();\n"
                "                const nextInit = { ...init };\n"
                "                if (res.statusCode === 303 || ((res.statusCode === 301 || res.statusCode === 302) && method === 'POST')) {\n"
                "                  nextInit.method = 'GET';\n"
                "                  delete nextInit.body;\n"
                "                }\n"
                "                return resolve(customFetch(nextUrl, nextInit));\n"
                "              }\n"
                "            }\n"
                "            const resHeaders = (typeof Headers !== 'undefined') ? new Headers() : new Map();\n"
                "            for (const [key, val] of Object.entries(res.headers)) {\n"
                "              if (Array.isArray(val)) {\n"
                "                val.forEach(v => {\n"
                "                  if (resHeaders.append) resHeaders.append(key, v);\n"
                "                  else resHeaders.set(key, v);\n"
                "                });\n"
                "              } else if (val !== undefined) {\n"
                "                resHeaders.set(key, val);\n"
                "              }\n"
                "            }\n"
                "            const chunks = [];\n"
                "            res.on('data', chunk => chunks.push(chunk));\n"
                "            res.on('end', () => {\n"
                "              const bodyBuffer = Buffer.concat(chunks);\n"
                "              const status = res.statusCode || 200;\n"
                "              const statusText = res.statusMessage || '';\n"
                "              const ok = status >= 200 && status < 300;\n"
                "              let respObj;\n"
                "              if (typeof Response !== 'undefined') {\n"
                "                try {\n"
                "                  respObj = new Response(bodyBuffer, {\n"
                "                    status,\n"
                "                    statusText,\n"
                "                    headers: resHeaders\n"
                "                  });\n"
                "                } catch (_e) {}\n"
                "              }\n"
                "              if (!respObj) {\n"
                "                respObj = {\n"
                "                  status,\n"
                "                  statusText,\n"
                "                  ok,\n"
                "                  headers: resHeaders,\n"
                "                  url: parsedUrl.toString(),\n"
                "                  text: async () => bodyBuffer.toString('utf8'),\n"
                "                  json: async () => JSON.parse(bodyBuffer.toString('utf8')),\n"
                "                  arrayBuffer: async () => bodyBuffer.buffer.slice(bodyBuffer.byteOffset, bodyBuffer.byteOffset + bodyBuffer.byteLength),\n"
                "                  body: { cancel: async () => {} }\n"
                "                };\n"
                "              }\n"
                "              writeLog('FETCH_RES', 'status=' + status + ' len=' + bodyBuffer.length);\n"
                "              resolve(respObj);\n"
                "            });\n"
                "            res.on('error', err => {\n"
                "              writeLog('FETCH_RES_ERR', err.message);\n"
                "              reject(err);\n"
                "            });\n"
                "          });\n"
                "          req.on('error', err => {\n"
                "            writeLog('FETCH_REQ_ERR', err.message);\n"
                "            reject(err);\n"
                "          });\n"
                "          if (signal) {\n"
                "            const onAbort = () => {\n"
                "              req.destroy();\n"
                "              const err = new Error('This operation was aborted');\n"
                "              err.name = 'AbortError';\n"
                "              reject(err);\n"
                "            };\n"
                "            signal.addEventListener('abort', onAbort, { once: true });\n"
                "          }\n"
                "          const bodyData = init.body || (input && input.body);\n"
                "          if (bodyData) {\n"
                "            if (typeof bodyData === 'string' || Buffer.isBuffer(bodyData)) {\n"
                "              req.write(bodyData);\n"
                "            } else if (bodyData instanceof Uint8Array) {\n"
                "              req.write(Buffer.from(bodyData));\n"
                "            } else if (typeof bodyData.pipe === 'function') {\n"
                "              bodyData.pipe(req);\n"
                "              return;\n"
                "            }\n"
                "          }\n"
                "          req.end();\n"
                "        } catch (err) {\n"
                "          writeLog('FETCH_EX', err.message);\n"
                "          reject(err);\n"
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

        std::string patch_json = options.runtime_root + "/bridge/swai-host.patch.json";
        std::vector<std::string> args = {
            "node",
            "--jitless",
            "--no-opt",
            "--expose-internals",
            "-r",
            preload_js,
            bin_path,
            "web",
            "--patch",
            patch_json,
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
        // Check if ready.json was created by preload script
        if (DshState::GetInstance().GetSnapshot().phase != "running") {
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
                        }
                    }
                }
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
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

    std::string body = req_data.substr(body_start);
    OH_LOG_Print(LOG_APP, LOG_DEBUG, 0x3201, "DSHHost", "Tool HTTP Request: %{public}s", body.c_str());

    std::string req_id;
    std::string tool = "bash";
    std::string args_json = "{}";
    int64_t deadline_ms = 0;

    size_t r_pos = body.find("\"requestId\":");
    if (r_pos != std::string::npos) {
        size_t q1 = body.find('"', r_pos + 12);
        if (q1 != std::string::npos) {
            size_t q2 = body.find('"', q1 + 1);
            if (q2 != std::string::npos) {
                req_id = body.substr(q1 + 1, q2 - q1 - 1);
            }
        }
    }
    if (req_id.empty()) {
        req_id = "req-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
    }

    size_t t_pos = body.find("\"tool\":");
    if (t_pos != std::string::npos) {
        size_t q1 = body.find('"', t_pos + 7);
        if (q1 != std::string::npos) {
            size_t q2 = body.find('"', q1 + 1);
            if (q2 != std::string::npos) {
                tool = body.substr(q1 + 1, q2 - q1 - 1);
            }
        }
    }

    size_t a_pos = body.find("\"args\":");
    if (a_pos != std::string::npos) {
        size_t b1 = body.find('{', a_pos + 7);
        if (b1 != std::string::npos) {
            int depth = 1;
            size_t b2 = b1 + 1;
            for (; b2 < body.size() && depth > 0; b2++) {
                if (body[b2] == '{') depth++;
                else if (body[b2] == '}') depth--;
            }
            if (depth == 0) {
                args_json = body.substr(b1, b2 - b1);
            }
        }
    }

    size_t d_pos = body.find("\"deadlineMs\":");
    if (d_pos != std::string::npos) {
        size_t n1 = d_pos + 13;
        while (n1 < body.size() && (body[n1] == ' ' || body[n1] == ':')) n1++;
        size_t n2 = n1;
        while (n2 < body.size() && isdigit(body[n2])) n2++;
        if (n2 > n1) {
            deadline_ms = std::stoll(body.substr(n1, n2 - n1));
        }
    }

    swshell::DshToolRequest treq;
    treq.request_id = req_id;
    treq.tool = tool;
    treq.args_json = args_json;
    treq.deadline_ms = deadline_ms;

    OH_LOG_Print(LOG_APP, LOG_INFO, 0x3201, "DSHHost",
                 "Dispatching tool to ArkTS: req_id=%{public}s tool=%{public}s",
                 req_id.c_str(), tool.c_str());

    swshell::DshState::GetInstance().DispatchToolFromNode(treq);

    swshell::DshToolResponse resp;
    int res = swshell::DshState::GetInstance().PollToolResultForNode(req_id, resp, 60000);

    std::string resp_json;
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

    std::string http_resp = "HTTP/1.1 200 OK\r\n"
                            "Content-Type: application/json\r\n"
                            "Content-Length: " + std::to_string(resp_json.size()) + "\r\n"
                            "Connection: close\r\n\r\n" + resp_json;
    send(cfd, http_resp.data(), http_resp.size(), 0);
}

} // namespace swshell
