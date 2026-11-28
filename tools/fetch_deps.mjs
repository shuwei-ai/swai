#!/usr/bin/env node
/**
 * Prepares external binary & generated dependencies declared in deps.json.
 *
 * - Keeps existing valid local files untouched (zero redundant downloads).
 * - Downloads missing prebuilt binaries (e.g. libnode.so) with SHA-256 verification.
 * - Builds missing generated artifacts (e.g. dsh-runtime.zip) via their build script.
 *
 * Usage:
 *   node tools/fetch_deps.mjs                   # Ensure all deps exist locally
 *   node tools/fetch_deps.mjs --check           # Verify only (exit 1 if missing/mismatch)
 *   node tools/fetch_deps.mjs --skip-runtime    # Only fetch prebuilt binaries
 *   node tools/fetch_deps.mjs --rebuild-runtime # Force rebuild dsh-runtime.zip
 *   node tools/fetch_deps.mjs --force           # Re-download binaries & rebuild runtime
 *
 * Environment overrides:
 *   SWAI_LIBNODE_URL=<url>   Override download URL for libnode-ohos-arm64.tar.gz
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');
const MANIFEST_PATH = path.join(REPO_ROOT, 'deps.json');

const args = new Set(process.argv.slice(2));
const CHECK_ONLY = args.has('--check');
const SKIP_RUNTIME = args.has('--skip-runtime');
const REBUILD_RUNTIME = args.has('--rebuild-runtime');
const FORCE = args.has('--force');

async function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
    stream.on('error', reject);
  });
}

function formatMB(bytes) {
  return `${(bytes / 1048576).toFixed(1)} MB`;
}

async function downloadFile(url, destPath) {
  console.log(`[fetch_deps] Downloading ${url} ...`);
  const res = await fetch(url, { redirect: 'follow' });
  if (!res.ok || !res.body) {
    throw new Error(`HTTP ${res.status} ${res.statusText}`);
  }
  const totalBytes = Number(res.headers.get('content-length') || 0);
  let downloaded = 0;
  let lastPct = -1;

  const progressStream = new Readable({
    read() {},
  });

  const reader = res.body.getReader();
  (async () => {
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          progressStream.push(null);
          break;
        }
        downloaded += value.byteLength;
        if (totalBytes > 0) {
          const pct = Math.floor((downloaded / totalBytes) * 100);
          if (pct >= lastPct + 10 || pct === 100) {
            lastPct = pct;
            process.stdout.write(`\r[fetch_deps]   ${pct}% (${formatMB(downloaded)} / ${formatMB(totalBytes)})`);
          }
        }
        progressStream.push(Buffer.from(value));
      }
      if (totalBytes > 0) process.stdout.write('\n');
    } catch (err) {
      progressStream.destroy(err);
    }
  })();

  await pipeline(progressStream, fs.createWriteStream(destPath));
}

async function ensureBinary(dep) {
  const destPath = path.join(REPO_ROOT, dep.dest);
  const exists = fs.existsSync(destPath);

  if (exists && !FORCE) {
    const actualHash = await sha256File(destPath);
    if (actualHash === dep.sha256) {
      const size = fs.statSync(destPath).size;
      console.log(`[fetch_deps] OK: ${dep.dest} (${formatMB(size)}, sha256 verified)`);
      return true;
    }
    console.warn(`[fetch_deps] SHA-256 mismatch for ${dep.dest}: expected ${dep.sha256}, got ${actualHash}`);
    if (CHECK_ONLY) return false;
  } else if (!exists) {
    if (CHECK_ONLY) {
      console.error(`[fetch_deps] MISSING: ${dep.dest}`);
      return false;
    }
  }

  const candidateUrls = [];
  if (dep.envUrlOverride && process.env[dep.envUrlOverride]) {
    candidateUrls.push(process.env[dep.envUrlOverride]);
  }
  candidateUrls.push(...(dep.urls || []));

  if (candidateUrls.length === 0) {
    throw new Error(`No download URLs configured for ${dep.name}`);
  }

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), `swai-dep-${dep.name}-`));
  const archivePath = path.join(tmpDir, dep.archive || path.basename(dep.dest));

  try {
    let lastErr = null;
    for (const url of candidateUrls) {
      try {
        await downloadFile(url, archivePath);
        lastErr = null;
        break;
      } catch (err) {
        lastErr = err;
        console.warn(`[fetch_deps] Failed from ${url}: ${err.message}`);
      }
    }
    if (lastErr) {
      throw new Error(`All download URLs failed for ${dep.name}: ${lastErr.message}`);
    }

    if (dep.archiveSha256) {
      const archiveHash = await sha256File(archivePath);
      if (archiveHash !== dep.archiveSha256) {
        throw new Error(
          `Archive SHA-256 mismatch for ${dep.archive}: expected ${dep.archiveSha256}, got ${archiveHash}`
        );
      }
    }

    fs.mkdirSync(path.dirname(destPath), { recursive: true });
    if (dep.archive && dep.archive.endsWith('.tar.gz')) {
      execFileSync('tar', ['-xzf', archivePath, '-C', path.dirname(destPath)], { stdio: 'inherit' });
    } else {
      fs.copyFileSync(archivePath, destPath);
    }

    const finalHash = await sha256File(destPath);
    if (finalHash !== dep.sha256) {
      throw new Error(`Extracted file SHA-256 mismatch for ${dep.dest}: expected ${dep.sha256}, got ${finalHash}`);
    }
    const size = fs.statSync(destPath).size;
    console.log(`[fetch_deps] Installed: ${dep.dest} (${formatMB(size)}, sha256 verified)`);
    return true;
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

function ensureGenerated(item) {
  const destPath = path.join(REPO_ROOT, item.dest);
  const exists = fs.existsSync(destPath);

  if (exists && !FORCE && !REBUILD_RUNTIME) {
    const size = fs.statSync(destPath).size;
    console.log(`[fetch_deps] OK: ${item.dest} (${formatMB(size)}, present locally)`);
    return true;
  }
  if (CHECK_ONLY) {
    console.error(`[fetch_deps] MISSING: ${item.dest} (run: node ${item.buildScript})`);
    return false;
  }

  const scriptPath = path.join(REPO_ROOT, item.buildScript);
  console.log(`[fetch_deps] Building ${item.dest} via ${item.buildScript} ...`);
  execFileSync(process.execPath, [scriptPath, ...(item.args || [])], {
    cwd: REPO_ROOT,
    stdio: 'inherit',
  });
  return fs.existsSync(destPath);
}

async function main() {
  const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));
  let allOk = true;

  for (const bin of manifest.binaries || []) {
    const ok = await ensureBinary(bin);
    if (!ok) allOk = false;
  }

  if (!SKIP_RUNTIME) {
    for (const gen of manifest.generated || []) {
      const ok = ensureGenerated(gen);
      if (!ok) allOk = false;
    }
  }

  if (!allOk) {
    process.exit(1);
  }
  console.log('[fetch_deps] All external dependencies are ready.');
}

main().catch((err) => {
  console.error(`[fetch_deps] ERROR: ${err.message}`);
  process.exit(1);
});
