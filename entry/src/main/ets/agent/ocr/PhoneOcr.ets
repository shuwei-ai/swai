/*
 * Native HarmonyOS OCR Engine inspired by Mika's PhoneOcr (com.wangzan101.mika.cap.phone.a11y.PhoneOcr).
 * Utilizes HarmonyOS CoreVisionKit on-device hardware-accelerated text recognition (@kit.CoreVisionKit).
 * Provides fast, offline visual text extraction with exact bounding boxes and center coordinates.
 */
import { textRecognition } from '@kit.CoreVisionKit';
import image from '@ohos.multimedia.image';
import buffer from '@ohos.buffer';
import { BridgeController } from '../../common/BridgeController';
import hilog from '@ohos.hilog';

const DOMAIN = 0x3202;
const TAG = 'PhoneOcr';
const OCR_SCREEN_PATH = '/data/local/tmp/_ocr_screen.jpeg';

export interface OcrTextLine {
  text: string;
  left: number;
  top: number;
  right: number;
  bottom: number;
  cx: number;
  cy: number;
  confidence?: number;
}

export interface OcrRoiBounds {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

export interface OcrResult {
  ok: boolean;
  fullText: string;
  lines: OcrTextLine[];
  imageWidth: number;
  imageHeight: number;
  durationMs: number;
  roiBounds?: OcrRoiBounds;
  excludeBounds?: OcrRoiBounds[];
  excludedCount?: number;
  error?: string;
}

export class PhoneOcr {
  /**
   * Performs text recognition on a provided PixelMap using HarmonyOS CoreVisionKit.
   */
  static async recognizePixelMap(pixelMap: image.PixelMap): Promise<OcrResult> {
    const startTime = Date.now();
    try {
      const imgInfo = await pixelMap.getImageInfo();
      const w = imgInfo.size.width;
      const h = imgInfo.size.height;

      const visionInfo: textRecognition.VisionInfo = {
        pixelMap: pixelMap
      };

      const res: textRecognition.TextRecognitionResult = await textRecognition.recognizeText(visionInfo);
      const lines: OcrTextLine[] = [];

      if (res && Array.isArray(res.blocks)) {
        for (let b = 0; b < res.blocks.length; b++) {
          const block = res.blocks[b];
          if (!block || !Array.isArray(block.lines)) {
            continue;
          }
          for (let l = 0; l < block.lines.length; l++) {
            const line = block.lines[l];
            const rawVal = (line.value ?? '').trim();
            if (rawVal.length === 0) {
              continue;
            }

            let left = 0;
            let top = 0;
            let right = 0;
            let bottom = 0;

            if (Array.isArray(line.cornerPoints) && line.cornerPoints.length > 0) {
              left = line.cornerPoints[0].x;
              top = line.cornerPoints[0].y;
              right = line.cornerPoints[0].x;
              bottom = line.cornerPoints[0].y;

              for (let p = 1; p < line.cornerPoints.length; p++) {
                const pt = line.cornerPoints[p];
                if (pt.x < left) left = pt.x;
                if (pt.x > right) right = pt.x;
                if (pt.y < top) top = pt.y;
                if (pt.y > bottom) bottom = pt.y;
              }
            }

            lines.push({
              text: rawVal,
              left: Math.round(left),
              top: Math.round(top),
              right: Math.round(right),
              bottom: Math.round(bottom),
              cx: Math.round((left + right) / 2),
              cy: Math.round((top + bottom) / 2)
            });
          }
        }
      }

      return {
        ok: true,
        fullText: res ? (res.value ?? '') : '',
        lines: lines,
        imageWidth: w,
        imageHeight: h,
        durationMs: Date.now() - startTime
      };
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'recognizePixelMap error: %{public}s', `${err}`);
      return {
        ok: false,
        fullText: '',
        lines: [],
        imageWidth: 0,
        imageHeight: 0,
        durationMs: Date.now() - startTime,
        error: `OCR recognition failed: ${err}`
      };
    }
  }

  private static isLineInExcludedRect(line: OcrTextLine, rect: OcrRoiBounds, pad: number): boolean {
    const exLeft = rect.left - pad;
    const exTop = rect.top - pad;
    const exRight = rect.right + pad;
    const exBottom = rect.bottom + pad;

    if (line.cx >= exLeft && line.cx <= exRight && line.cy >= exTop && line.cy <= exBottom) {
      return true;
    }

    const interW = Math.min(line.right, exRight) - Math.max(line.left, exLeft);
    const interH = Math.min(line.bottom, exBottom) - Math.max(line.top, exTop);
    if (interW <= 0 || interH <= 0) {
      return false;
    }
    const lineArea = Math.max(1, (line.right - line.left) * (line.bottom - line.top));
    return (interW * interH) / lineArea >= 0.35;
  }

  /**
   * Captures the current live screen and performs OCR recognition directly.
   * When roiBounds is provided (e.g. target app window in split-screen), keeps lines inside that ROI.
   * When excludeBounds is provided (e.g. PiP Thinking Capsule / overlay), drops lines overlapping those rects.
   */
  static async recognizeScreen(roiBounds?: OcrRoiBounds, excludeBounds?: OcrRoiBounds[]): Promise<OcrResult> {
    const startTime = Date.now();
    try {
      // 1. Hardware snapshot to /data/local/tmp/_ocr_screen.jpeg (~100ms)
      const snapCmd =
        `rm -f ${OCR_SCREEN_PATH} && ` +
        `(snapshot_display -f ${OCR_SCREEN_PATH} >/dev/null 2>&1 || uitest screenCap -p ${OCR_SCREEN_PATH} >/dev/null 2>&1) && ` +
        `[ -s ${OCR_SCREEN_PATH} ]`;

      const snapRes = await BridgeController.getInstance().exec(snapCmd, '', 10);
      if (!snapRes.ok) {
        return {
          ok: false,
          fullText: '',
          lines: [],
          imageWidth: 0,
          imageHeight: 0,
          durationMs: Date.now() - startTime,
          error: `Screen capture for OCR failed: ${snapRes.error || snapRes.output}`
        };
      }

      // 2. Read image bytes into base64 via shell
      const readCmd =
        `if [ ! -s ${OCR_SCREEN_PATH} ]; then echo '__ERR__'; exit 0; fi; ` +
        `echo '___B64___'; base64 ${OCR_SCREEN_PATH} 2>/dev/null; echo '___END___'`;

      const readRes = await BridgeController.getInstance().exec(readCmd, '', 15);
      if (!readRes.ok || !readRes.output.includes('___B64___')) {
        return {
          ok: false,
          fullText: '',
          lines: [],
          imageWidth: 0,
          imageHeight: 0,
          durationMs: Date.now() - startTime,
          error: `Reading screen capture failed: ${readRes.error || readRes.output}`
        };
      }

      const out = readRes.output;
      const startTag = '___B64___\n';
      const endTag = '\n___END___';
      const startIdx = out.indexOf(startTag);
      const endIdx = out.lastIndexOf(endTag);
      if (startIdx === -1 || endIdx === -1 || endIdx <= startIdx) {
        return {
          ok: false,
          fullText: '',
          lines: [],
          imageWidth: 0,
          imageHeight: 0,
          durationMs: Date.now() - startTime,
          error: 'Corrupted base64 screenshot payload'
        };
      }

      const b64 = out.substring(startIdx + startTag.length, endIdx).replace(/\s+/g, '');
      const rawBuf = buffer.from(b64, 'base64');
      const arrayBuf = rawBuf.buffer.slice(rawBuf.byteOffset, rawBuf.byteOffset + rawBuf.length);

      const imageSource = image.createImageSource(arrayBuf);
      const pixelMap = await imageSource.createPixelMap();

      try {
        const result = await PhoneOcr.recognizePixelMap(pixelMap);
        if (result.ok && (roiBounds || (excludeBounds && excludeBounds.length > 0))) {
          const pad = 8;
          let filteredLines = result.lines;
          if (roiBounds) {
            filteredLines = filteredLines.filter(l =>
              l.cx >= roiBounds.left - pad &&
              l.cx <= roiBounds.right + pad &&
              l.cy >= roiBounds.top - pad &&
              l.cy <= roiBounds.bottom + pad
            );
          }
          let excludedCount = 0;
          if (excludeBounds && excludeBounds.length > 0) {
            const afterExclude: OcrTextLine[] = [];
            for (let i = 0; i < filteredLines.length; i++) {
              const line = filteredLines[i];
              let hit = false;
              for (let j = 0; j < excludeBounds.length; j++) {
                if (PhoneOcr.isLineInExcludedRect(line, excludeBounds[j], 12)) {
                  hit = true;
                  break;
                }
              }
              if (hit) {
                excludedCount++;
              } else {
                afterExclude.push(line);
              }
            }
            filteredLines = afterExclude;
          }
          return {
            ok: result.ok,
            fullText: filteredLines.map(l => l.text).join('\n'),
            lines: filteredLines,
            imageWidth: result.imageWidth,
            imageHeight: result.imageHeight,
            durationMs: result.durationMs,
            roiBounds: roiBounds,
            excludeBounds: excludeBounds,
            excludedCount: excludedCount
          };
        }
        return result;
      } finally {
        try {
          await pixelMap.release();
        } catch (_e) {
          // ignore
        }
        try {
          await imageSource.release();
        } catch (_e) {
          // ignore
        }
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'recognizeScreen exception: %{public}s', `${err}`);
      return {
        ok: false,
        fullText: '',
        lines: [],
        imageWidth: 0,
        imageHeight: 0,
        durationMs: Date.now() - startTime,
        error: `recognizeScreen error: ${err}`
      };
    }
  }

  /**
   * Formats OCR results into a human/LLM readable layout summary.
   */
  static formatSummary(result: OcrResult, maxLines: number = 60): string {
    if (!result.ok) {
      return `[OCR Error]: ${result.error ?? 'Unknown error'}`;
    }
    const roiText = result.roiBounds
      ? ` ROI=[${result.roiBounds.left},${result.roiBounds.top}][${result.roiBounds.right},${result.roiBounds.bottom}]`
      : '';
    const exclText = result.excludedCount && result.excludedCount > 0
      ? ` (excluded ${result.excludedCount} overlay lines)`
      : '';
    const header = `[OCR Text Recognition] ${result.imageWidth}x${result.imageHeight}${roiText} | Found ${result.lines.length} text lines${exclText} (${result.durationMs}ms):`;
    if (result.lines.length === 0) {
      return `${header}\n(No readable text detected on screen)`;
    }

    const lines: string[] = [header];
    const cap = Math.min(result.lines.length, maxLines);
    for (let i = 0; i < cap; i++) {
      const l = result.lines[i];
      lines.push(`@ocr${i} [Text] "${l.text}" center=(${l.cx},${l.cy}) bounds=[${l.left},${l.top}][${l.right},${l.bottom}]`);
    }
    if (result.lines.length > cap) {
      lines.push(`... (+${result.lines.length - cap} more text lines)`);
    }
    return lines.join('\n');
  }
}
