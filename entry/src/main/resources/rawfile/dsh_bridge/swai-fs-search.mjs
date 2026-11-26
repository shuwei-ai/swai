/**
 * Native In-Process Filesystem Search Backend for DSH (`glob` & `grep`) on HarmonyOS NEXT.
 *
 * Replaces `@vscode/ripgrep` subprocess spawning (unavailable under HarmonyOS app sandbox /
 * musl ABI) with fast in-process Node `fs` traversal + `picomatch` matching, and falls back
 * to Swai's uid-2000 HDC shell bridge when searching external system directories (e.g. /data/local/tmp).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

let picomatch = null;
try {
  picomatch = require('picomatch');
} catch (_) {
  try {
    picomatch = require('../node_modules/picomatch');
  } catch (_2) {
    picomatch = null;
  }
}

const VCS_EXCLUDES = new Set(['.git', '.svn', '.hg', '.bzr', '.jj', '.sl']);
const MAX_GREP_FILE_BYTES = 16 * 1024 * 1024; // 16 MiB per file cap to skip huge archives/binaries
const BINARY_SNIFF_BYTES = 8192;

function makeSearchError(SearchErrorClass, message, code, cause) {
  if (typeof SearchErrorClass === 'function') {
    return new SearchErrorClass(message, code, cause !== undefined ? { cause } : undefined);
  }
  const err = new Error(message);
  err.code = code;
  if (cause !== undefined) {
    err.cause = cause;
  }
  return err;
}

function normalizeSandboxAlias(rawPath) {
  if (typeof rawPath !== 'string') {
    return rawPath;
  }
  return rawPath.replace(/^\/mnt\/debug\/\d+\/debug_hap\/[^/]+\/data\/storage(?=\/|$)/, '/data/storage');
}

function fallbackGlobToRegExp(globPattern) {
  let re = '^';
  let i = 0;
  while (i < globPattern.length) {
    const c = globPattern[i];
    if (c === '*') {
      if (globPattern[i + 1] === '*') {
        if (globPattern[i + 2] === '/') {
          re += '(?:.+/)?';
          i += 3;
          continue;
        }
        re += '.*';
        i += 2;
        continue;
      }
      re += '[^/]*';
    } else if (c === '?') {
      re += '[^/]';
    } else if ('\\^$.|+()[]{}'.includes(c)) {
      re += '\\' + c;
    } else {
      re += c;
    }
    i++;
  }
  re += '$';
  return new RegExp(re);
}

function compileGlobMatcher(rawPattern, toolName, SearchErrorClass) {
  let pat = rawPattern;
  if (pat.startsWith('./') && pat.length > 2) {
    pat = pat.slice(2);
  }
  if (pat.startsWith('/') && pat.length > 1) {
    pat = pat.slice(1);
  }
  const matchBasenameOnly = !pat.includes('/');

  try {
    if (picomatch) {
      // Validate unbalanced brackets/braces explicitly as picomatch may otherwise treat some literally
      let bracketDepth = 0;
      for (let i = 0; i < pat.length; i++) {
        if (pat[i] === '\\') {
          i++;
          continue;
        }
        if (pat[i] === '[') bracketDepth++;
        else if (pat[i] === ']' && bracketDepth > 0) bracketDepth--;
      }
      if (bracketDepth > 0) {
        throw new Error('unclosed character class');
      }
      const isMatch = picomatch(pat, { dot: true, posixSlashes: true });
      return (relPosixPath, baseName) => {
        if (matchBasenameOnly) {
          return isMatch(baseName);
        }
        return isMatch(relPosixPath);
      };
    }
    const rx = fallbackGlobToRegExp(pat);
    return (relPosixPath, baseName) => rx.test(matchBasenameOnly ? baseName : relPosixPath);
  } catch (err) {
    throw makeSearchError(
      SearchErrorClass,
      `${toolName} pattern rejected by ripgrep: error parsing glob '${rawPattern}': ${err.message || String(err)}`,
      'SEARCH_INVALID_PATTERN',
      err
    );
  }
}

function compileRipgrepRegex(rawPattern, SearchErrorClass) {
  let pattern = rawPattern;
  let flags = 'u';

  // Translate leading ripgrep inline flags e.g. (?i), (?m), (?s), (?ims)
  const inlineMatch = /^\(\?([ims]+)\)/.exec(pattern);
  if (inlineMatch) {
    const f = inlineMatch[1];
    if (f.includes('i') && !flags.includes('i')) flags += 'i';
    if (f.includes('s') && !flags.includes('s')) flags += 's';
    pattern = pattern.slice(inlineMatch[0].length);
  }

  try {
    return new RegExp(pattern, flags);
  } catch (err) {
    try {
      // Retry without unicode 'u' flag in case pattern uses raw escapes allowed in non-u JS RegExp
      const nonUFlags = flags.replace('u', '');
      return new RegExp(pattern, nonUFlags);
    } catch (err2) {
      throw makeSearchError(
        SearchErrorClass,
        `grep pattern rejected by ripgrep: regex parse error: ${err2.message || String(err2)}`,
        'SEARCH_INVALID_PATTERN',
        err2
      );
    }
  }
}

function parseArgvForGlob(argv) {
  let userGlob = '*';
  let targetPath;
  const dashIdx = argv.indexOf('--');
  const flagEnd = dashIdx === -1 ? argv.length : dashIdx;
  if (dashIdx !== -1 && dashIdx + 1 < argv.length) {
    targetPath = argv[dashIdx + 1];
  }
  const sortIdx = argv.indexOf('--sort=modified');
  const searchLimit = sortIdx !== -1 && sortIdx < flagEnd ? sortIdx : flagEnd;
  for (let i = 0; i < searchLimit; i++) {
    const arg = argv[i];
    if (arg.startsWith('--glob=') && !arg.startsWith('--glob=!')) {
      userGlob = arg.slice('--glob='.length);
    }
  }
  return { userGlob, targetPath };
}

function parseArgvForGrep(argv) {
  let regexPattern = '';
  let includeGlob;
  let targetPath;
  const dashIdx = argv.indexOf('--');
  const flagEnd = dashIdx === -1 ? argv.length : dashIdx;
  if (dashIdx !== -1 && dashIdx + 1 < argv.length) {
    targetPath = argv[dashIdx + 1];
  }
  for (let i = 0; i < flagEnd; i++) {
    const arg = argv[i];
    if (arg.startsWith('--regexp=')) {
      regexPattern = arg.slice('--regexp='.length);
    } else if (arg.startsWith('--glob=') && !arg.startsWith('--glob=!')) {
      includeGlob = arg.slice('--glob='.length);
    }
  }
  return { regexPattern, includeGlob, targetPath };
}

function execViaShellBridge(command, timeoutMs = 25000) {
  const port = Number(process.env.SWAI_TOOL_BRIDGE_PORT || process.env.PIHA_TOOL_BRIDGE_PORT || 38081);
  const postData = JSON.stringify({
    requestId: `swai-search-${Date.now()}-${Math.floor(Math.random() * 100000)}`,
    tool: 'bash',
    args: { command, timeout_seconds: Math.max(5, Math.ceil(timeoutMs / 1000)) },
    deadlineMs: Date.now() + timeoutMs
  });
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1',
      port,
      path: '/v1/tool/execute',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData)
      },
      timeout: timeoutMs
    }, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => {
        try {
          resolve(JSON.parse(body));
        } catch (e) {
          reject(e);
        }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => {
      req.destroy();
      reject(new Error('Shell bridge timeout'));
    });
    req.write(postData);
    req.end();
  });
}

function shellSingleQuote(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

async function fallbackShellGlob(searchTarget, matcher, workdir, rawOutputMaxBytes, SearchErrorClass) {
  const cmd = `find ${shellSingleQuote(searchTarget)} -type f 2>/dev/null`;
  const res = await execViaShellBridge(cmd);
  if (!res || !res.ok) {
    throw makeSearchError(
      SearchErrorClass,
      `glob search failed (exit 2): ${res?.error || 'Permission denied'}`,
      'SEARCH_FAILED'
    );
  }
  const matched = [];
  for (const rawLine of (res.output || '').split(/\r?\n/)) {
    const filePath = rawLine.trim();
    if (!filePath) continue;
    const rel = path.relative(searchTarget, filePath).split(path.sep).join('/');
    if (rel.split('/').some((seg) => VCS_EXCLUDES.has(seg))) continue;
    const baseName = path.basename(filePath);
    if (matcher(rel, baseName)) {
      matched.push(filePath);
    }
  }
  const stdout = matched.join('\n');
  if (Buffer.byteLength(stdout, 'utf8') > rawOutputMaxBytes) {
    throw makeSearchError(
      SearchErrorClass,
      `glob produced more than ${rawOutputMaxBytes} bytes of raw output; narrow pattern or path and retry`,
      'SEARCH_RAW_OUTPUT_OVERFLOW'
    );
  }
  return { stdout, noMatches: matched.length === 0, workdir };
}

async function fallbackShellGrep(searchTarget, regex, includeMatcher, workdir, rawOutputMaxBytes, SearchErrorClass) {
  const cmd = `grep -rnI '' ${shellSingleQuote(searchTarget)} 2>/dev/null`;
  const res = await execViaShellBridge(cmd);
  if (!res || (!res.ok && !res.output)) {
    throw makeSearchError(
      SearchErrorClass,
      `grep search failed (exit 2): ${res?.error || 'Permission denied'}`,
      'SEARCH_FAILED'
    );
  }
  const records = [];
  let totalBytes = 0;
  for (const rawLine of (res.output || '').split(/\r?\n/)) {
    if (!rawLine) continue;
    const m = /^(.*?):(\d+):(.*)$/.exec(rawLine);
    if (!m) continue;
    const [, filePath, lineNoStr, lineContent] = m;
    const rel = path.relative(searchTarget, filePath).split(path.sep).join('/');
    if (rel.split('/').some((seg) => VCS_EXCLUDES.has(seg))) continue;
    if (includeMatcher && !includeMatcher(rel, path.basename(filePath))) continue;
    regex.lastIndex = 0;
    if (!regex.test(lineContent)) continue;
    const rec = JSON.stringify({
      type: 'match',
      data: {
        path: { text: filePath },
        line_number: Number(lineNoStr),
        lines: { text: lineContent + '\n' }
      }
    });
    totalBytes += Buffer.byteLength(rec, 'utf8') + 1;
    if (totalBytes > rawOutputMaxBytes) {
      throw makeSearchError(
        SearchErrorClass,
        `grep produced ${totalBytes} bytes of raw output, over the ${rawOutputMaxBytes}-byte cap; narrow pattern, path, or include and retry`,
        'SEARCH_RAW_OUTPUT_OVERFLOW'
      );
    }
    records.push(rec);
  }
  return { stdout: records.join('\n'), noMatches: records.length === 0, workdir };
}

async function walkFiles(rootTarget, rootStat, signal, onFile) {
  if (rootStat.isFile()) {
    await onFile(rootTarget, '', path.basename(rootTarget), rootStat);
    return;
  }
  if (!rootStat.isDirectory()) {
    return;
  }

  const visitedDirs = new Set();
  if (rootStat.dev !== undefined && rootStat.ino !== undefined) {
    visitedDirs.add(`${rootStat.dev}:${rootStat.ino}`);
  }

  const stack = [rootTarget];
  while (stack.length > 0) {
    if (signal?.aborted) {
      const err = new Error('aborted');
      err.name = 'AbortError';
      throw err;
    }
    const currentDir = stack.pop();
    let entries;
    try {
      entries = await fsp.readdir(currentDir, { withFileTypes: true });
    } catch (_) {
      continue;
    }
    // Push in reverse so stack traversal visits entries in deterministic order
    for (let i = entries.length - 1; i >= 0; i--) {
      const entry = entries[i];
      const name = entry.name;
      if (VCS_EXCLUDES.has(name)) {
        continue;
      }
      const fullPath = path.join(currentDir, name);
      if (entry.isDirectory()) {
        try {
          const st = await fsp.stat(fullPath);
          const key = `${st.dev}:${st.ino}`;
          if (visitedDirs.has(key)) continue;
          visitedDirs.add(key);
        } catch (_) {
          continue;
        }
        stack.push(fullPath);
      } else if (entry.isFile() || entry.isSymbolicLink()) {
        let st;
        try {
          st = await fsp.stat(fullPath);
        } catch (_) {
          continue;
        }
        if (st.isDirectory()) {
          const key = `${st.dev}:${st.ino}`;
          if (!visitedDirs.has(key)) {
            visitedDirs.add(key);
            stack.push(fullPath);
          }
          continue;
        }
        if (!st.isFile()) continue;
        const relPosix = path.relative(rootTarget, fullPath).split(path.sep).join('/');
        await onFile(fullPath, relPosix, name, st);
      }
    }
  }
}

function isLikelyBinary(buf) {
  const checkLen = Math.min(buf.length, BINARY_SNIFF_BYTES);
  for (let i = 0; i < checkLen; i++) {
    if (buf[i] === 0) {
      return true;
    }
  }
  return false;
}

export async function runSwaiFsSearch(ctx, exec, toolName, argv, rawOutputMaxBytes, SearchErrorClass) {
  const signal = exec?.signal;
  if (signal?.aborted) {
    throw makeSearchError(
      SearchErrorClass,
      `${toolName} was aborted before completion (tool timeout or caller cancellation)`,
      'SEARCH_ABORTED'
    );
  }

  const rawWorkdir = exec?.agent === undefined
    ? process.cwd()
    : await ctx.workingDirectory.ensure(exec.agent, signal);
  const workdir = normalizeSandboxAlias(rawWorkdir);

  if (toolName === 'glob') {
    const { userGlob, targetPath } = parseArgvForGlob(argv);
    const matcher = compileGlobMatcher(userGlob, 'glob', SearchErrorClass);
    const normalizedTarget = targetPath !== undefined ? normalizeSandboxAlias(targetPath) : undefined;
    const searchTarget = normalizedTarget !== undefined
      ? (path.isAbsolute(normalizedTarget) ? normalizedTarget : path.resolve(workdir, normalizedTarget))
      : workdir;

    let rootStat;
    try {
      rootStat = await fsp.stat(searchTarget);
    } catch (err) {
      if ((err.code === 'EACCES' || err.code === 'EPERM') && !searchTarget.startsWith('/data/storage')) {
        return await fallbackShellGlob(searchTarget, matcher, workdir, rawOutputMaxBytes, SearchErrorClass);
      }
      throw makeSearchError(
        SearchErrorClass,
        `glob search failed (exit 2): ${searchTarget}: ${err.message || String(err)}`,
        'SEARCH_FAILED',
        err
      );
    }

    const found = [];
    try {
      await walkFiles(searchTarget, rootStat, signal, async (fullPath, relPosix, baseName, st) => {
        const candidateRel = relPosix || baseName;
        if (matcher(candidateRel, baseName)) {
          found.push({ path: fullPath, mtimeMs: st.mtimeMs || 0 });
        }
      });
    } catch (err) {
      if (signal?.aborted || err?.name === 'AbortError') {
        throw makeSearchError(
          SearchErrorClass,
          'glob was aborted before completion (tool timeout or caller cancellation)',
          'SEARCH_ABORTED'
        );
      }
      throw makeSearchError(SearchErrorClass, `glob search failed: ${err.message || String(err)}`, 'SEARCH_FAILED', err);
    }

    found.sort((a, b) => b.mtimeMs - a.mtimeMs);
    const stdout = found.map((item) => item.path).join('\n');
    const byteLen = Buffer.byteLength(stdout, 'utf8');
    if (byteLen > rawOutputMaxBytes) {
      throw makeSearchError(
        SearchErrorClass,
        `glob produced ${byteLen} bytes of raw output, over the ${rawOutputMaxBytes}-byte cap; narrow pattern, path, or include and retry`,
        'SEARCH_RAW_OUTPUT_OVERFLOW'
      );
    }
    return {
      stdout,
      noMatches: found.length === 0,
      workdir
    };
  }

  // grep
  const { regexPattern, includeGlob, targetPath } = parseArgvForGrep(argv);
  const regex = compileRipgrepRegex(regexPattern, SearchErrorClass);
  const includeMatcher = includeGlob !== undefined
    ? compileGlobMatcher(includeGlob, 'grep', SearchErrorClass)
    : null;
  const normalizedTarget = targetPath !== undefined ? normalizeSandboxAlias(targetPath) : undefined;
  const searchTarget = normalizedTarget !== undefined
    ? (path.isAbsolute(normalizedTarget) ? normalizedTarget : path.resolve(workdir, normalizedTarget))
    : workdir;

  let rootStat;
  try {
    rootStat = await fsp.stat(searchTarget);
  } catch (err) {
    if ((err.code === 'EACCES' || err.code === 'EPERM') && !searchTarget.startsWith('/data/storage')) {
      return await fallbackShellGrep(searchTarget, regex, includeMatcher, workdir, rawOutputMaxBytes, SearchErrorClass);
    }
    throw makeSearchError(
      SearchErrorClass,
      `grep search failed (exit 2): ${searchTarget}: ${err.message || String(err)}`,
      'SEARCH_FAILED',
      err
    );
  }

  const records = [];
  let totalBytes = 0;

  try {
    await walkFiles(searchTarget, rootStat, signal, async (fullPath, relPosix, baseName, st) => {
      if (st.size === 0 || st.size > MAX_GREP_FILE_BYTES) {
        return;
      }
      if (includeMatcher && relPosix !== '') {
        if (!includeMatcher(relPosix, baseName)) {
          return;
        }
      }
      let buf;
      try {
        buf = await fsp.readFile(fullPath);
      } catch (_) {
        return;
      }
      if (isLikelyBinary(buf)) {
        return;
      }
      const text = buf.toString('utf8');
      const lines = text.split(/\r?\n/);
      if (lines.length > 0 && lines[lines.length - 1] === '' && text.endsWith('\n')) {
        lines.pop();
      }
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        regex.lastIndex = 0;
        if (regex.test(line)) {
          const rec = JSON.stringify({
            type: 'match',
            data: {
              path: { text: fullPath },
              line_number: i + 1,
              lines: { text: line + '\n' }
            }
          });
          totalBytes += Buffer.byteLength(rec, 'utf8') + 1;
          if (totalBytes > rawOutputMaxBytes) {
            throw makeSearchError(
              SearchErrorClass,
              `grep produced ${totalBytes} bytes of raw output, over the ${rawOutputMaxBytes}-byte cap; narrow pattern, path, or include and retry`,
              'SEARCH_RAW_OUTPUT_OVERFLOW'
            );
          }
          records.push(rec);
        }
      }
    });
  } catch (err) {
    if (err?.code === 'SEARCH_RAW_OUTPUT_OVERFLOW' || err?.code === 'SEARCH_INVALID_PATTERN' || err?.code === 'SEARCH_ABORTED') {
      throw err;
    }
    if (signal?.aborted || err?.name === 'AbortError') {
      throw makeSearchError(
        SearchErrorClass,
        'grep was aborted before completion (tool timeout or caller cancellation)',
        'SEARCH_ABORTED'
      );
    }
    throw makeSearchError(SearchErrorClass, `grep search failed: ${err.message || String(err)}`, 'SEARCH_FAILED', err);
  }

  return {
    stdout: records.join('\n'),
    noMatches: records.length === 0,
    workdir
  };
}
