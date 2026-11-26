/*
 * Swai <-> DSH Native Image Processor
 *
 * Executes hardware-accelerated raster verification, EXIF orientation normalization,
 * aspect-preserving resize, and metadata-free JPEG/WebP encoding via HarmonyOS
 * @ohos.multimedia.image for @deepseek-ai/dsh-attachment-local (replacing libvips/sharp).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
import fs from '@ohos.file.fs';
import image from '@ohos.multimedia.image';
import hilog from '@ohos.hilog';

const DOMAIN: number = 0x3F00;
const TAG: string = 'DshImageProcessor';

export interface DshImageOpOutput {
  ok: boolean;
  output: string;
  error: string;
}

export class DshImageProcessor {
  static async execute(argsJson: string): Promise<DshImageOpOutput> {
    let args: Record<string, Object>;
    try {
      args = JSON.parse(argsJson || '{}') as Record<string, Object>;
    } catch (e) {
      return {
        ok: false,
        output: '',
        error: `Invalid JSON arguments: ${e}`
      };
    }

    const op = (args['op'] as string) || '';
    const inputPath = (args['inputPath'] as string) || '';
    if (inputPath.length === 0) {
      return {
        ok: false,
        output: '',
        error: 'Missing inputPath'
      };
    }

    if (op === 'verify') {
      return await DshImageProcessor.verifyRaster(inputPath);
    }
    if (op === 'transform') {
      const outputPath = (args['outputPath'] as string) || '';
      const orientation = typeof args['orientation'] === 'number' ? (args['orientation'] as number) : 1;
      const targetWidth = typeof args['targetWidth'] === 'number' ? Math.max(1, Math.round(args['targetWidth'] as number)) : 0;
      const targetHeight = typeof args['targetHeight'] === 'number' ? Math.max(1, Math.round(args['targetHeight'] as number)) : 0;
      const format = (args['format'] as string) || 'image/jpeg';
      const quality = typeof args['quality'] === 'number' ? Math.min(100, Math.max(1, Math.round(args['quality'] as number))) : 85;

      if (outputPath.length === 0 || targetWidth <= 0 || targetHeight <= 0) {
        return {
          ok: false,
          output: '',
          error: 'Invalid transform parameters'
        };
      }
      return await DshImageProcessor.transformRaster(
        inputPath,
        outputPath,
        orientation,
        targetWidth,
        targetHeight,
        format,
        quality
      );
    }

    return {
      ok: false,
      output: '',
      error: `Unsupported image operation: ${op}`
    };
  }

  private static async verifyRaster(inputPath: string): Promise<DshImageOpOutput> {
    let openedFile: fs.File | undefined = undefined;
    let imageSource: image.ImageSource | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      openedFile = fs.openSync(inputPath, fs.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(openedFile.fd);
      const info = await imageSource.getImageInfo();
      if (!info || !info.size || info.size.width <= 0 || info.size.height <= 0) {
        return {
          ok: false,
          output: '',
          error: 'Invalid image dimensions'
        };
      }
      const frameCount = await imageSource.getFrameCount();
      // Decode frame 0 to verify the raster stream is complete and uncorrupted
      const decodeOpts: image.DecodingOptions = {
        index: 0
      };
      pixelMap = await imageSource.createPixelMap(decodeOpts);
      const payload = JSON.stringify({
        width: info.size.width,
        height: info.size.height,
        mimeType: info.mimeType || '',
        frameCount: frameCount
      });
      return {
        ok: true,
        output: payload,
        error: ''
      };
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'verifyRaster failed for %{public}s: %{public}s', inputPath, `${err}`);
      return {
        ok: false,
        output: '',
        error: `Image decode failed: ${err}`
      };
    } finally {
      if (pixelMap) {
        try {
          await pixelMap.release();
        } catch (_e) {}
      }
      if (imageSource) {
        try {
          await imageSource.release();
        } catch (_e) {}
      }
      if (openedFile) {
        try {
          fs.closeSync(openedFile);
        } catch (_e) {}
      }
    }
  }

  private static async applyExifOrientation(pixelMap: image.PixelMap, orientation: number): Promise<void> {
    switch (orientation) {
      case 2:
        await pixelMap.flip(true, false);
        break;
      case 3:
        await pixelMap.rotate(180);
        break;
      case 4:
        await pixelMap.flip(false, true);
        break;
      case 5:
        await pixelMap.rotate(90);
        await pixelMap.flip(true, false);
        break;
      case 6:
        await pixelMap.rotate(90);
        break;
      case 7:
        await pixelMap.rotate(270);
        await pixelMap.flip(true, false);
        break;
      case 8:
        await pixelMap.rotate(270);
        break;
      default:
        break;
    }
  }

  private static async transformRaster(
    inputPath: string,
    outputPath: string,
    orientation: number,
    targetWidth: number,
    targetHeight: number,
    format: string,
    quality: number
  ): Promise<DshImageOpOutput> {
    let openedFile: fs.File | undefined = undefined;
    let imageSource: image.ImageSource | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;

    try {
      openedFile = fs.openSync(inputPath, fs.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(openedFile.fd);

      const transposed = orientation >= 5 && orientation <= 8;
      const preW = transposed ? targetHeight : targetWidth;
      const preH = transposed ? targetWidth : targetHeight;

      const decodeOpts: image.DecodingOptions = {
        index: 0,
        editable: true,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        desiredSize: { width: preW, height: preH }
      };
      pixelMap = await imageSource.createPixelMap(decodeOpts);

      if (orientation >= 2 && orientation <= 8) {
        await DshImageProcessor.applyExifOrientation(pixelMap, orientation);
      }

      const pmInfo = await pixelMap.getImageInfo();
      if (pmInfo.size.width !== targetWidth || pmInfo.size.height !== targetHeight) {
        const sx = targetWidth / Math.max(1, pmInfo.size.width);
        const sy = targetHeight / Math.max(1, pmInfo.size.height);
        await pixelMap.scale(sx, sy);
      }

      packer = image.createImagePacker();
      const packOpts: image.PackingOption = {
        format: format,
        quality: quality,
        needsPackProperties: false
      };
      const packedBuffer = await packer.packToData(pixelMap, packOpts);

      const outFile = fs.openSync(outputPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(outFile.fd, packedBuffer);
      } finally {
        fs.closeSync(outFile);
      }

      const finalInfo = await pixelMap.getImageInfo();
      const payload = JSON.stringify({
        width: finalInfo.size.width,
        height: finalInfo.size.height,
        bytes: packedBuffer.byteLength,
        format: format
      });
      return {
        ok: true,
        output: payload,
        error: ''
      };
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'transformRaster failed for %{public}s -> %{public}s: %{public}s', inputPath, format, `${err}`);
      return {
        ok: false,
        output: '',
        error: `Image transform failed: ${err}`
      };
    } finally {
      if (packer) {
        try {
          await packer.release();
        } catch (_e) {}
      }
      if (pixelMap) {
        try {
          await pixelMap.release();
        } catch (_e) {}
      }
      if (imageSource) {
        try {
          await imageSource.release();
        } catch (_e) {}
      }
      if (openedFile) {
        try {
          fs.closeSync(openedFile);
        } catch (_e) {}
      }
    }
  }
}
