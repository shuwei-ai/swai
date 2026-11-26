/**
 * HarmonyOS NEXT Drop-In `sharp` Replacement for `@deepseek-ai/dsh-attachment-local`.
 *
 * Replaces unavailable `libvips` native binaries and `--jitless`-disabled WebAssembly
 * with:
 *   1. Fast, zero-dependency pure-JS container/header & EXIF metadata inspection
 *      for PNG, JPEG, WebP, and GIF (`probeImage` runs in < 0.05ms in-process);
 *   2. Hardware-accelerated raster verification, EXIF auto-orientation, resize, and
 *      8-bit sRGB JPEG/WebP encoding via Swai's HarmonyOS `@ohos.multimedia.image`
 *      bridge (`dsh_image_op`), exchanging raw bytes over shared sandbox temp files;
 *   3. Deterministic container metadata stripping so normalized outputs always satisfy
 *      `!detected.carriesMetadata` in `verifyNormalizedImage`.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { dispatchSwaiTool } from './bridge-client.mjs';

const VERIFIED_DIGEST_CACHE_LIMIT = 64;
const verifiedDigests = new Set();

function rememberVerifiedDigest(sha256) {
  if (verifiedDigests.size >= VERIFIED_DIGEST_CACHE_LIMIT) {
    const oldest = verifiedDigests.values().next().value;
    if (oldest !== undefined) {
      verifiedDigests.delete(oldest);
    }
  }
  verifiedDigests.add(sha256);
}

function sha256Hex(buf) {
  return createHash('sha256').update(buf).digest('hex');
}

function resolveTempDir() {
  const candidates = [
    process.env.TMPDIR,
    process.env.TMP,
    process.env.HOME ? path.join(process.env.HOME, '.tmp') : null,
    '/data/storage/el2/base/haps/entry/files/workspace/.tmp',
  ];
  for (const dir of candidates) {
    if (dir && dir !== '/tmp') {
      try {
        fs.mkdirSync(dir, { recursive: true });
        return dir;
      } catch (_) {}
    }
  }
  return '/tmp';
}

function toBuffer(input) {
  if (Buffer.isBuffer(input)) {
    return input;
  }
  if (input instanceof Uint8Array) {
    return Buffer.from(input.buffer, input.byteOffset, input.byteLength);
  }
  if (input instanceof ArrayBuffer) {
    return Buffer.from(input);
  }
  if (typeof input === 'string') {
    return fs.readFileSync(input);
  }
  throw new Error('Unsupported image input type');
}

/**
 * Parse TIFF IFD0 for Orientation tag (0x0112).
 * @param {Buffer} tiff - Buffer starting at TIFF header ("II*\0" or "MM\0*").
 * @returns {number | undefined} Orientation 1..8 if present.
 */
function parseTiffOrientation(tiff) {
  if (!tiff || tiff.length < 8) {
    return undefined;
  }
  let littleEndian;
  if (tiff[0] === 0x49 && tiff[1] === 0x49 && tiff[2] === 0x2a && tiff[3] === 0x00) {
    littleEndian = true;
  } else if (tiff[0] === 0x4d && tiff[1] === 0x4d && tiff[2] === 0x00 && tiff[3] === 0x2a) {
    littleEndian = false;
  } else {
    return undefined;
  }

  const readU16 = (off) => (littleEndian ? tiff.readUInt16LE(off) : tiff.readUInt16BE(off));
  const readU32 = (off) => (littleEndian ? tiff.readUInt32LE(off) : tiff.readUInt32BE(off));

  const ifdOffset = readU32(4);
  if (ifdOffset < 8 || ifdOffset + 2 > tiff.length) {
    return undefined;
  }
  const entryCount = readU16(ifdOffset);
  for (let i = 0; i < entryCount; i++) {
    const entryOff = ifdOffset + 2 + i * 12;
    if (entryOff + 12 > tiff.length) {
      break;
    }
    const tag = readU16(entryOff);
    if (tag === 0x0112) {
      const val = readU16(entryOff + 8);
      if (val >= 1 && val <= 8) {
        return val;
      }
      return undefined;
    }
  }
  return undefined;
}

function parsePngHeader(buf) {
  if (buf.length < 33) {
    throw new Error('PNG data too short');
  }
  let offset = 8;
  let width = 0;
  let height = 0;
  let depth = 'uchar';
  let hasAlpha = false;
  let pages = 1;
  let exif;
  let icc;
  let xmp;
  let comments;
  let orientation;
  let sawIhdr = false;
  let sawIend = false;

  while (offset + 12 <= buf.length) {
    const chunkLen = buf.readUInt32BE(offset);
    const type = buf.toString('ascii', offset + 4, offset + 8);
    const dataStart = offset + 8;
    const dataEnd = dataStart + chunkLen;
    if (dataEnd + 4 > buf.length) {
      throw new Error(`Truncated PNG chunk: ${type}`);
    }

    if (type === 'IHDR') {
      if (chunkLen !== 13) {
        throw new Error('Invalid PNG IHDR length');
      }
      width = buf.readUInt32BE(dataStart);
      height = buf.readUInt32BE(dataStart + 4);
      const bitDepth = buf[dataStart + 8];
      const colorType = buf[dataStart + 9];
      if (![1, 2, 4, 8, 16].includes(bitDepth)) {
        throw new Error('Invalid PNG bit depth');
      }
      depth = bitDepth === 16 ? 'ushort' : 'uchar';
      if (colorType === 4 || colorType === 6) {
        hasAlpha = true;
      }
      sawIhdr = true;
    } else if (type === 'tRNS') {
      hasAlpha = true;
    } else if (type === 'acTL' && chunkLen >= 8) {
      const frames = buf.readUInt32BE(dataStart);
      if (frames > 1) {
        pages = frames;
      }
    } else if (type === 'eXIf') {
      exif = true;
      const payload = buf.subarray(dataStart, dataEnd);
      const exifSlice =
        payload.length > 6 && payload.toString('ascii', 0, 6) === 'Exif\0\0'
          ? payload.subarray(6)
          : payload;
      orientation = parseTiffOrientation(exifSlice);
    } else if (type === 'iCCP') {
      icc = true;
    } else if (type === 'iTXt') {
      const payload = buf.subarray(dataStart, Math.min(dataEnd, dataStart + 32));
      if (payload.toString('ascii').startsWith('XML:com.adobe.xmp\0')) {
        xmp = true;
      } else {
        comments = true;
      }
    } else if (type === 'tEXt' || type === 'zTXt') {
      comments = true;
    } else if (type === 'IEND') {
      sawIend = true;
      break;
    }

    offset = dataEnd + 4;
  }

  if (!sawIhdr || !sawIend || width <= 0 || height <= 0) {
    throw new Error('Malformed or incomplete PNG stream');
  }

  return {
    format: 'png',
    width,
    height,
    pages,
    depth,
    space: 'srgb',
    hasAlpha,
    hasProfile: Boolean(icc),
    ...(exif ? { exif } : {}),
    ...(icc ? { icc } : {}),
    ...(xmp ? { xmp } : {}),
    ...(comments ? { comments } : {}),
    ...(orientation !== undefined ? { orientation } : {}),
  };
}

const JPEG_SOF_MARKERS = new Set([
  0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
]);

function parseJpegHeader(buf) {
  if (buf.length < 4) {
    throw new Error('JPEG data too short');
  }
  let offset = 2;
  let width = 0;
  let height = 0;
  let depth = 'uchar';
  let space = 'srgb';
  let exif;
  let xmp;
  let iptc;
  let icc;
  let comments;
  let orientation;
  let sawSosOrEoi = false;

  while (offset < buf.length) {
    if (buf[offset] !== 0xff) {
      throw new Error('Invalid JPEG marker alignment');
    }
    while (offset < buf.length && buf[offset] === 0xff) {
      offset++;
    }
    if (offset >= buf.length) {
      break;
    }
    const marker = buf[offset++];
    if (marker === 0xd9) {
      sawSosOrEoi = true;
      break;
    }
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      continue;
    }
    if (offset + 2 > buf.length) {
      throw new Error('Truncated JPEG segment length');
    }
    const segLen = buf.readUInt16BE(offset);
    if (segLen < 2 || offset + segLen > buf.length) {
      throw new Error('Truncated JPEG segment body');
    }
    const payloadStart = offset + 2;
    const segEnd = offset + segLen;

    if (JPEG_SOF_MARKERS.has(marker)) {
      if (segLen < 8) {
        throw new Error('Invalid JPEG SOF segment');
      }
      const precision = buf[payloadStart];
      height = buf.readUInt16BE(payloadStart + 1);
      width = buf.readUInt16BE(payloadStart + 3);
      const components = buf[payloadStart + 5];
      depth = precision > 8 ? 'ushort' : 'uchar';
      space = components === 4 ? 'cmyk' : 'srgb';
    } else if (marker === 0xe1) {
      const payload = buf.subarray(payloadStart, segEnd);
      if (payload.length >= 6 && payload.toString('ascii', 0, 6) === 'Exif\0\0') {
        exif = true;
        const parsedOrient = parseTiffOrientation(payload.subarray(6));
        if (parsedOrient !== undefined && orientation === undefined) {
          orientation = parsedOrient;
        }
      } else if (
        payload.length >= 29 &&
        payload.toString('ascii', 0, 29) === 'http://ns.adobe.com/xap/1.0/\0'
      ) {
        xmp = true;
      }
    } else if (marker === 0xe2) {
      const payload = buf.subarray(payloadStart, segEnd);
      if (payload.length >= 12 && payload.toString('ascii', 0, 12) === 'ICC_PROFILE\0') {
        icc = true;
      }
    } else if (marker === 0xed) {
      const payload = buf.subarray(payloadStart, segEnd);
      if (payload.length >= 14 && payload.toString('ascii', 0, 14) === 'Photoshop 3.0\0') {
        iptc = true;
      }
    } else if (marker === 0xfe) {
      comments = true;
    } else if (marker === 0xda) {
      sawSosOrEoi = true;
      break;
    }

    offset = segEnd;
  }

  // Verify trailing EOI marker exists somewhere after SOS
  let hasEoi = false;
  for (let i = buf.length - 2; i >= Math.max(2, buf.length - 64); i--) {
    if (buf[i] === 0xff && buf[i + 1] === 0xd9) {
      hasEoi = true;
      break;
    }
  }
  if (!hasEoi) {
    // Scan full buffer fallback in case of trailing padding
    for (let i = buf.length - 2; i >= offset; i--) {
      if (buf[i] === 0xff && buf[i + 1] === 0xd9) {
        hasEoi = true;
        break;
      }
    }
  }

  if (!sawSosOrEoi || !hasEoi || width <= 0 || height <= 0) {
    throw new Error('Malformed or incomplete JPEG stream');
  }

  return {
    format: 'jpeg',
    width,
    height,
    pages: 1,
    depth,
    space,
    hasAlpha: false,
    hasProfile: Boolean(icc),
    ...(exif ? { exif } : {}),
    ...(xmp ? { xmp } : {}),
    ...(iptc ? { iptc, tifftagPhotoshop: true } : {}),
    ...(icc ? { icc } : {}),
    ...(comments ? { comments } : {}),
    ...(orientation !== undefined ? { orientation } : {}),
  };
}

function parseWebpHeader(buf) {
  if (buf.length < 16) {
    throw new Error('WebP data too short');
  }
  const riffSize = buf.readUInt32LE(4);
  if (riffSize + 8 > buf.length) {
    throw new Error('Truncated WebP RIFF container');
  }

  let offset = 12;
  const end = Math.min(buf.length, riffSize + 8);
  let width = 0;
  let height = 0;
  let hasAlpha = false;
  let animated = false;
  let anmfCount = 0;
  let exif;
  let xmp;
  let icc;
  let orientation;

  while (offset + 8 <= end) {
    const fourCC = buf.toString('ascii', offset, offset + 4);
    const chunkSize = buf.readUInt32LE(offset + 4);
    const dataStart = offset + 8;
    const dataEnd = dataStart + chunkSize;
    if (dataEnd > end) {
      throw new Error(`Truncated WebP chunk: ${fourCC}`);
    }

    if (fourCC === 'VP8X') {
      if (chunkSize < 10) {
        throw new Error('Invalid WebP VP8X chunk');
      }
      const flags = buf[dataStart];
      if (flags & 0x10) hasAlpha = true;
      if (flags & 0x02) animated = true;
      if (flags & 0x20) icc = true;
      if (flags & 0x08) exif = true;
      if (flags & 0x04) xmp = true;
      width = 1 + buf.readUIntLE(dataStart + 4, 3);
      height = 1 + buf.readUIntLE(dataStart + 7, 3);
    } else if (fourCC === 'VP8 ' && width === 0) {
      if (
        chunkSize < 10 ||
        buf[dataStart + 3] !== 0x9d ||
        buf[dataStart + 4] !== 0x01 ||
        buf[dataStart + 5] !== 0x2a
      ) {
        throw new Error('Invalid WebP VP8 keyframe header');
      }
      width = buf.readUInt16LE(dataStart + 6) & 0x3fff;
      height = buf.readUInt16LE(dataStart + 8) & 0x3fff;
    } else if (fourCC === 'VP8L') {
      if (chunkSize < 5 || buf[dataStart] !== 0x2f) {
        throw new Error('Invalid WebP VP8L signature');
      }
      const bits = buf.readUInt32LE(dataStart + 1);
      if (width === 0) {
        width = (bits & 0x3fff) + 1;
        height = ((bits >>> 14) & 0x3fff) + 1;
      }
      if ((bits >>> 28) & 1) {
        hasAlpha = true;
      }
    } else if (fourCC === 'ALPH') {
      hasAlpha = true;
    } else if (fourCC === 'ANMF') {
      anmfCount++;
    } else if (fourCC === 'EXIF') {
      exif = true;
      const payload = buf.subarray(dataStart, dataEnd);
      const tiffSlice =
        payload.length > 6 && payload.toString('ascii', 0, 6) === 'Exif\0\0'
          ? payload.subarray(6)
          : payload;
      orientation = parseTiffOrientation(tiffSlice);
    } else if (fourCC === 'XMP ') {
      xmp = true;
    } else if (fourCC === 'ICCP') {
      icc = true;
    }

    offset = dataEnd + (chunkSize & 1);
  }

  if (width <= 0 || height <= 0) {
    throw new Error('Missing WebP dimensions');
  }

  return {
    format: 'webp',
    width,
    height,
    pages: animated ? Math.max(2, anmfCount) : 1,
    depth: 'uchar',
    space: 'srgb',
    hasAlpha,
    hasProfile: Boolean(icc),
    ...(exif ? { exif } : {}),
    ...(xmp ? { xmp } : {}),
    ...(icc ? { icc } : {}),
    ...(orientation !== undefined ? { orientation } : {}),
  };
}

function skipGifSubBlocks(buf, pos) {
  while (pos < buf.length) {
    const blockSize = buf[pos++];
    if (blockSize === 0) {
      return pos;
    }
    pos += blockSize;
    if (pos > buf.length) {
      throw new Error('Truncated GIF sub-block');
    }
  }
  throw new Error('Unterminated GIF sub-block');
}

function parseGifHeader(buf) {
  if (buf.length < 14) {
    throw new Error('GIF data too short');
  }
  const width = buf.readUInt16LE(6);
  const height = buf.readUInt16LE(8);
  if (width <= 0 || height <= 0) {
    throw new Error('Invalid GIF dimensions');
  }
  const packed = buf[10];
  let pos = 13;
  if (packed & 0x80) {
    const gctEntries = 1 << ((packed & 0x07) + 1);
    pos += 3 * gctEntries;
  }
  if (pos > buf.length) {
    throw new Error('Truncated GIF global color table');
  }

  let frames = 0;
  let hasAlpha = false;
  let comments;
  let xmp;
  let sawTrailer = false;

  while (pos < buf.length) {
    const introducer = buf[pos++];
    if (introducer === 0x3b) {
      sawTrailer = true;
      break;
    }
    if (introducer === 0x21) {
      if (pos >= buf.length) {
        throw new Error('Truncated GIF extension');
      }
      const label = buf[pos++];
      if (label === 0xf9) {
        if (pos + 5 <= buf.length && buf[pos] === 4) {
          const gceFlags = buf[pos + 1];
          if (gceFlags & 0x01) {
            hasAlpha = true;
          }
        }
        pos = skipGifSubBlocks(buf, pos);
      } else if (label === 0xfe) {
        comments = true;
        pos = skipGifSubBlocks(buf, pos);
      } else if (label === 0xff) {
        if (pos + 12 <= buf.length && buf[pos] === 11) {
          const appId = buf.toString('ascii', pos + 1, pos + 12);
          if (appId === 'XMP DataXMP') {
            xmp = true;
          }
        }
        pos = skipGifSubBlocks(buf, pos);
      } else {
        pos = skipGifSubBlocks(buf, pos);
      }
    } else if (introducer === 0x2c) {
      if (pos + 9 > buf.length) {
        throw new Error('Truncated GIF image descriptor');
      }
      const imgPacked = buf[pos + 8];
      pos += 9;
      if (imgPacked & 0x80) {
        const lctEntries = 1 << ((imgPacked & 0x07) + 1);
        pos += 3 * lctEntries;
      }
      if (pos >= buf.length) {
        throw new Error('Truncated GIF LZW header');
      }
      pos++; // LZW minimum code size
      pos = skipGifSubBlocks(buf, pos);
      frames++;
    } else {
      throw new Error(`Unexpected GIF block byte: 0x${introducer.toString(16)}`);
    }
  }

  if (!sawTrailer || frames === 0) {
    throw new Error('Incomplete GIF stream');
  }

  return {
    format: 'gif',
    width,
    height,
    pages: frames,
    depth: 'uchar',
    space: 'srgb',
    hasAlpha,
    hasProfile: false,
    ...(comments ? { comments } : {}),
    ...(xmp ? { xmp } : {}),
  };
}

/**
 * Parse intrinsic header metadata for PNG, JPEG, WebP, or GIF.
 * Throws on unsupported or truncated/corrupted headers.
 */
export function parseImageHeader(input) {
  const buf = toBuffer(input);
  if (buf.length < 4) {
    throw new Error('Image buffer is empty or too short');
  }
  if (
    buf.length >= 8 &&
    buf[0] === 0x89 &&
    buf[1] === 0x50 &&
    buf[2] === 0x4e &&
    buf[3] === 0x47 &&
    buf[4] === 0x0d &&
    buf[5] === 0x0a &&
    buf[6] === 0x1a &&
    buf[7] === 0x0a
  ) {
    return parsePngHeader(buf);
  }
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) {
    return parseJpegHeader(buf);
  }
  if (
    buf.length >= 12 &&
    buf.toString('ascii', 0, 4) === 'RIFF' &&
    buf.toString('ascii', 8, 12) === 'WEBP'
  ) {
    return parseWebpHeader(buf);
  }
  if (buf.length >= 6) {
    const sig = buf.toString('ascii', 0, 6);
    if (sig === 'GIF87a' || sig === 'GIF89a') {
      return parseGifHeader(buf);
    }
  }
  throw new Error('Unsupported or malformed image format');
}

/**
 * Strip EXIF/XMP/ICC/IPTC/Comment segments from freshly encoded JPEG or WebP
 * so `carriesRetainedMetadata(metadata)` is guaranteed false.
 */
export function stripImageMetadata(buf, format) {
  if (format === 'jpeg' && buf.length >= 4 && buf[0] === 0xff && buf[1] === 0xd8) {
    const chunks = [buf.subarray(0, 2)];
    let offset = 2;
    while (offset < buf.length) {
      if (buf[offset] !== 0xff) {
        chunks.push(buf.subarray(offset));
        break;
      }
      const markerStart = offset;
      while (offset < buf.length && buf[offset] === 0xff) {
        offset++;
      }
      if (offset >= buf.length) {
        break;
      }
      const marker = buf[offset++];
      if (marker === 0xd9) {
        chunks.push(buf.subarray(markerStart, offset));
        break;
      }
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
        chunks.push(buf.subarray(markerStart, offset));
        continue;
      }
      if (offset + 2 > buf.length) {
        chunks.push(buf.subarray(markerStart));
        break;
      }
      const segLen = buf.readUInt16BE(offset);
      const segEnd = offset + segLen;
      if (marker === 0xda) {
        chunks.push(buf.subarray(markerStart));
        break;
      }
      // Drop APP1 (Exif/XMP), APP2 (ICC), APP13 (IPTC/Photoshop), COM (Comments)
      if (marker !== 0xe1 && marker !== 0xe2 && marker !== 0xed && marker !== 0xfe) {
        chunks.push(buf.subarray(markerStart, segEnd));
      }
      offset = segEnd;
    }
    return Buffer.concat(chunks);
  }

  if (
    format === 'webp' &&
    buf.length >= 16 &&
    buf.toString('ascii', 0, 4) === 'RIFF' &&
    buf.toString('ascii', 8, 12) === 'WEBP'
  ) {
    const riffSize = buf.readUInt32LE(4);
    const end = Math.min(buf.length, riffSize + 8);
    const kept = [];
    let offset = 12;
    while (offset + 8 <= end) {
      const fourCC = buf.toString('ascii', offset, offset + 4);
      const chunkSize = buf.readUInt32LE(offset + 4);
      const paddedLen = 8 + chunkSize + (chunkSize & 1);
      if (offset + paddedLen > end) {
        break;
      }
      if (fourCC !== 'EXIF' && fourCC !== 'XMP ' && fourCC !== 'ICCP') {
        const slice = Buffer.from(buf.subarray(offset, offset + paddedLen));
        if (fourCC === 'VP8X' && chunkSize >= 10) {
          // Clear ICC (0x20), EXIF (0x08), and XMP (0x04) flags
          slice[8] &= ~(0x20 | 0x08 | 0x04);
        }
        kept.push(slice);
      }
      offset += paddedLen;
    }
    const bodyLen = 4 + kept.reduce((sum, c) => sum + c.length, 0);
    const header = Buffer.alloc(12);
    header.write('RIFF', 0, 'ascii');
    header.writeUInt32LE(bodyLen, 4);
    header.write('WEBP', 8, 'ascii');
    return Buffer.concat([header, ...kept]);
  }

  return buf;
}

function computeTargetDimensions(srcW, srcH, resizeOpts) {
  if (!resizeOpts) {
    return { width: srcW, height: srcH };
  }
  const withoutEnlargement = resizeOpts.withoutEnlargement === true;
  const reqW = resizeOpts.width;
  const reqH = resizeOpts.height;

  if (reqW !== undefined && reqH !== undefined) {
    let scale = Math.min(reqW / srcW, reqH / srcH);
    if (withoutEnlargement && scale > 1) {
      scale = 1;
    }
    return {
      width: Math.max(1, Math.round(srcW * scale)),
      height: Math.max(1, Math.round(srcH * scale)),
    };
  }

  if (reqW !== undefined) {
    const outW = withoutEnlargement ? Math.min(srcW, reqW) : reqW;
    const outH = outW === srcW ? srcH : Math.max(1, Math.round((outW * srcH) / srcW));
    return { width: Math.max(1, outW), height: outH };
  }

  if (reqH !== undefined) {
    const outH = withoutEnlargement ? Math.min(srcH, reqH) : reqH;
    const outW = outH === srcH ? srcW : Math.max(1, Math.round((outH * srcW) / srcH));
    return { width: outW, height: Math.max(1, outH) };
  }

  return { width: srcW, height: srcH };
}

class SwaiSharpPipeline {
  constructor(input, options = {}) {
    this._buffer = toBuffer(input);
    this._options = options;
    this._autoOrient = false;
    this._resizeOpts = null;
    this._rawMode = false;
    this._outputFormat = null; // 'jpeg' | 'webp'
    this._outputQuality = 85;
  }

  clone() {
    const copy = new SwaiSharpPipeline(this._buffer, this._options);
    copy._autoOrient = this._autoOrient;
    copy._resizeOpts = this._resizeOpts ? { ...this._resizeOpts } : null;
    copy._rawMode = this._rawMode;
    copy._outputFormat = this._outputFormat;
    copy._outputQuality = this._outputQuality;
    return copy;
  }

  async metadata() {
    return parseImageHeader(this._buffer);
  }

  rotate() {
    this._autoOrient = true;
    return this;
  }

  toColourspace(_space) {
    return this;
  }

  resize(widthOrOpts, height, opts) {
    if (typeof widthOrOpts === 'object' && widthOrOpts !== null) {
      this._resizeOpts = { ...widthOrOpts };
    } else {
      this._resizeOpts = {
        ...(typeof widthOrOpts === 'number' ? { width: widthOrOpts } : {}),
        ...(typeof height === 'number' ? { height } : {}),
        ...(opts || {}),
      };
    }
    return this;
  }

  raw() {
    this._rawMode = true;
    return this;
  }

  jpeg(opts = {}) {
    this._outputFormat = 'jpeg';
    if (typeof opts.quality === 'number') {
      this._outputQuality = opts.quality;
    }
    return this;
  }

  webp(opts = {}) {
    this._outputFormat = 'webp';
    if (typeof opts.quality === 'number') {
      this._outputQuality = opts.quality;
    }
    return this;
  }

  async toBuffer(opts = {}) {
    const meta = parseImageHeader(this._buffer);

    if (this._rawMode) {
      const digest = sha256Hex(this._buffer);
      if (!verifiedDigests.has(digest)) {
        const tmpDir = resolveTempDir();
        const inPath = path.join(tmpDir, `swai-img-verify-${randomUUID()}.${meta.format}`);
        try {
          await fsp.writeFile(inPath, this._buffer);
          const res = await dispatchSwaiTool(
            'dsh_image_op',
            { op: 'verify', inputPath: inPath },
            30000
          );
          if (!res.ok) {
            throw new Error(res.error || 'Native raster decode verification failed');
          }
          rememberVerifiedDigest(digest);
        } finally {
          await fsp.unlink(inPath).catch(() => {});
        }
      }
      // `detectImage` discards the raw pixel buffer after awaiting `image.raw().toBuffer()`
      const placeholder = Buffer.alloc(0);
      if (opts && opts.resolveWithObject) {
        return {
          data: placeholder,
          info: {
            format: 'raw',
            width: meta.width,
            height: meta.height,
            channels: meta.hasAlpha ? 4 : 3,
            size: 0,
          },
        };
      }
      return placeholder;
    }

    const format = this._outputFormat || (meta.hasAlpha ? 'webp' : 'jpeg');
    const mimeFormat = format === 'webp' ? 'image/webp' : 'image/jpeg';
    const orientation = this._autoOrient && meta.orientation ? meta.orientation : 1;
    const transposed = orientation >= 5 && orientation <= 8;
    const orientedW = transposed ? meta.height : meta.width;
    const orientedH = transposed ? meta.width : meta.height;
    const target = computeTargetDimensions(orientedW, orientedH, this._resizeOpts);

    const tmpDir = resolveTempDir();
    const id = randomUUID();
    const inPath = path.join(tmpDir, `swai-img-in-${id}.${meta.format}`);
    const outPath = path.join(tmpDir, `swai-img-out-${id}.${format}`);

    try {
      await fsp.writeFile(inPath, this._buffer);
      const res = await dispatchSwaiTool(
        'dsh_image_op',
        {
          op: 'transform',
          inputPath: inPath,
          outputPath: outPath,
          orientation,
          targetWidth: target.width,
          targetHeight: target.height,
          format: mimeFormat,
          quality: this._outputQuality,
        },
        30000
      );
      if (!res.ok) {
        throw new Error(res.error || 'Native image transform failed');
      }
      const rawOut = await fsp.readFile(outPath);
      const cleanOut = stripImageMetadata(rawOut, format);
      const outMeta = parseImageHeader(cleanOut);
      rememberVerifiedDigest(sha256Hex(cleanOut));

      if (opts && opts.resolveWithObject) {
        return {
          data: cleanOut,
          info: {
            format: outMeta.format,
            width: outMeta.width,
            height: outMeta.height,
            channels: outMeta.hasAlpha ? 4 : 3,
            size: cleanOut.length,
          },
        };
      }
      return cleanOut;
    } finally {
      await fsp.unlink(inPath).catch(() => {});
      await fsp.unlink(outPath).catch(() => {});
    }
  }
}

export function swaiSharp(input, options) {
  return new SwaiSharpPipeline(input, options);
}

export default swaiSharp;
