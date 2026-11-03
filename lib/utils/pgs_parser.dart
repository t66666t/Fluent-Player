import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/subtitle_model.dart';

class PgsRenderParams {
  final PgsPcs pcs;
  final PgsPds pds;
  final Map<int, PgsOds> objects;

  PgsRenderParams(this.pcs, this.pds, this.objects);
}

class PgsParser {
  static const maxFileBytes = 256 * 1024 * 1024;
  static const maxPixels = 4096 * 4096;
  static const maxObjectBytes = 64 * 1024 * 1024;

  static void validateDimensions(int width, int height) {
    if (width <= 0 || height <= 0 || width * height > maxPixels) {
      throw const FormatException('PGS 字幕尺寸无效或超过解码内存上限');
    }
  }

  static Future<List<SubtitleItem>> parse(String path) async {
    final file = File(path);
    if (!await file.exists()) return [];
    if (await file.length() > maxFileBytes) {
      throw const FormatException('PGS 字幕文件超过 256 MiB，无法在内存中解码');
    }

    final bytes = await file.readAsBytes();
    final data = ByteData.sublistView(bytes);
    int offset = 0;

    List<SubtitleItem> subtitles = [];

    PgsPcs? currentPcs;
    PgsPds? lastPds;
    final Map<int, PgsPds> paletteById = <int, PgsPds>{};
    final Map<int, PgsOds> objectById = <int, PgsOds>{};
    final Map<int, _PgsOdsAccumulator> odsAccumulators =
        <int, _PgsOdsAccumulator>{};

    // Palette and object definitions can be reused by later display sets.

    while (offset < data.lengthInBytes) {
      if (offset + 13 > data.lengthInBytes) break; // Header is 13 bytes

      // PG header
      // 0-1: Magic 'PG' (0x50, 0x47)
      // 2-5: PTS (Presentation Time Stamp) - 90kHz
      // 6-9: DTS (Decoding Time Stamp) - 0 (often)
      // 10: Segment Type
      // 11-12: Segment Length

      final magic = data.getUint16(offset);
      if (magic != 0x5047) {
        // Scan forward to find next PG
        offset++;
        continue;
      }

      final pts = data.getUint32(offset + 2);
      // Skip DTS (4 bytes)
      final type = data.getUint8(offset + 10);
      final length = data.getUint16(offset + 11);

      final segmentDataOffset = offset + 13;
      final nextSegmentOffset = segmentDataOffset + length;

      if (nextSegmentOffset > data.lengthInBytes) {
        throw const FormatException('PGS 字幕段不完整');
      }

      final segmentBytes = bytes.sublist(segmentDataOffset, nextSegmentOffset);
      final segmentByteData = ByteData.sublistView(segmentBytes);

      // Process Segment
      switch (type) {
        case 0x14: // PDS - Palette Definition Segment
          final pds = PgsPds.parse(segmentByteData);
          paletteById[pds.id] = pds;
          lastPds = pds;
          break;
        case 0x15: // ODS - Object Definition Segment
          final segment = _parseOdsSegment(segmentByteData);
          if (segment != null) {
            if ((segment.sequenceFlag & 0x80) != 0) {
              odsAccumulators[segment.id] = _PgsOdsAccumulator(
                id: segment.id,
                version: segment.version,
                width: segment.width ?? 0,
                height: segment.height ?? 0,
                dataLength: segment.dataLength,
              );
            }
            final accumulator = odsAccumulators[segment.id];
            if (accumulator != null) {
              accumulator.add(segment.data);
              if ((segment.sequenceFlag & 0x40) != 0) {
                final ods = accumulator.build();
                if (ods != null) {
                  objectById[segment.id] = ods;
                }
                odsAccumulators.remove(segment.id);
              }
            }
          }
          break;
        case 0x16: // PCS - Presentation Composition Segment
          currentPcs = PgsPcs.parse(segmentByteData, pts);
          break;
        case 0x17: // WDS - Window Definition Segment
          // currentWds = PgsWds.parse(segmentByteData);
          break;
        case 0x80: // END - End of Display Set
          if (currentPcs != null) {
            // Keep the object versions used by this display set. Later ODS
            // updates must not change an already-created subtitle's bitmap.
            if (currentPcs.objects.isNotEmpty) {
              final capturedPcs = currentPcs;
              final capturedObjects = <int, PgsOds>{
                for (final object in capturedPcs.objects)
                  object.objectId: ?objectById[object.objectId],
              };
              final capturedPds = paletteById[capturedPcs.paletteId] ?? lastPds;
              if (capturedPds != null && capturedObjects.isNotEmpty) {
                final startTime = Duration(
                  milliseconds: (capturedPcs.pts / 90).round(),
                );
                subtitles.add(
                  SubtitleItem(
                    index: subtitles.length + 1,
                    startTime: startTime,
                    endTime: startTime + const Duration(seconds: 2),
                    imageLoader: () async {
                      return compute(
                        _renderSubtitleCompute,
                        PgsRenderParams(
                          capturedPcs,
                          capturedPds,
                          capturedObjects,
                        ),
                      );
                    },
                  ),
                );
              }
            } else {
              // PCS with 0 objects -> Clear screen.
              // We can use this to set the endTime of the previous subtitle.
              final clearTime = Duration(
                milliseconds: (currentPcs.pts / 90).round(),
              );
              if (subtitles.isNotEmpty) {
                final last = subtitles.last;
                if (last.endTime ==
                    last.startTime + const Duration(seconds: 2)) {
                  subtitles[subtitles.length - 1] = SubtitleItem(
                    index: last.index,
                    startTime: last.startTime,
                    endTime: clearTime,
                    text: last.text,
                    imageLoader: last.imageLoader,
                  );
                }
              }
            }
          }

          // Palettes and objects persist across display sets in one epoch.
          currentPcs = null;
          break;
      }

      offset = nextSegmentOffset;
    }

    // Sort and fix durations
    subtitles.sort((a, b) => a.startTime.compareTo(b.startTime));
    for (int i = 0; i < subtitles.length - 1; i++) {
      if (subtitles[i].endTime > subtitles[i + 1].startTime) {
        subtitles[i] = SubtitleItem(
          index: subtitles[i].index,
          startTime: subtitles[i].startTime,
          endTime: subtitles[i + 1].startTime,
          text: subtitles[i].text,
          imageLoader: subtitles[i].imageLoader,
        );
      }
    }

    return subtitles;
  }

  static Future<Uint8List?> _renderSubtitleCompute(
    PgsRenderParams params,
  ) async {
    return _renderSubtitle(params.pcs, params.pds, params.objects);
  }

  static _PgsOdsSegment? _parseOdsSegment(ByteData data) {
    if (data.lengthInBytes < 4) {
      throw const FormatException('PGS ODS 段不完整');
    }
    final id = data.getUint16(0);
    final version = data.getUint8(2);
    final sequenceFlag = data.getUint8(3);
    int dataLength = 0;
    int offset = 4;
    int? width;
    int? height;
    if ((sequenceFlag & 0x80) != 0) {
      if (data.lengthInBytes < 11) {
        throw const FormatException('PGS ODS 首段不完整');
      }
      // Only the first fragment contains the length and dimensions. The
      // declared length includes four dimension bytes, but excludes this header.
      dataLength =
          (data.getUint8(4) << 16) | (data.getUint8(5) << 8) | data.getUint8(6);
      if (dataLength < 4) throw const FormatException('PGS ODS 长度无效');
      dataLength -= 4;
      width = data.getUint16(7);
      height = data.getUint16(9);
      validateDimensions(width, height);
      offset = 11;
    }
    final part = data.buffer.asUint8List(
      data.offsetInBytes + offset,
      data.lengthInBytes - offset,
    );
    return _PgsOdsSegment(
      id: id,
      version: version,
      sequenceFlag: sequenceFlag,
      dataLength: dataLength,
      width: width,
      height: height,
      data: part,
    );
  }

  static Future<Uint8List?> _renderSubtitle(
    PgsPcs pcs,
    PgsPds pds,
    Map<int, PgsOds> objects,
  ) async {
    validateDimensions(pcs.width, pcs.height);
    final canvas = Uint32List(pcs.width * pcs.height);
    for (final object in pcs.objects) {
      final ods = objects[object.objectId];
      if (ods == null) continue;
      validateDimensions(ods.width, ods.height);
      final indices = _decodeRle(ods.rleData, ods.width, ods.height);
      final cropX = object.cropX ?? 0;
      final cropY = object.cropY ?? 0;
      final cropWidth = object.cropWidth ?? ods.width;
      final cropHeight = object.cropHeight ?? ods.height;
      if (cropX + cropWidth > ods.width || cropY + cropHeight > ods.height) {
        throw const FormatException('PGS 字幕裁剪范围超出对象尺寸');
      }
      for (var y = 0; y < cropHeight; y++) {
        final destY = object.y + y;
        if (destY >= pcs.height) break;
        for (var x = 0; x < cropWidth; x++) {
          final destX = object.x + x;
          if (destX >= pcs.width) break;
          final index = indices[(cropY + y) * ods.width + cropX + x];
          final color = pds.palette[index] ?? 0;
          final alpha = color >>> 24;
          if (alpha == 0) continue;
          final offset = destY * pcs.width + destX;
          if (alpha == 255) {
            canvas[offset] = color;
          } else {
            final old = canvas[offset];
            final oldAlpha = old >>> 24;
            final background = oldAlpha * (255 - alpha);
            final numerator = alpha * 255 + background;
            int blend(int shift) =>
                (((color >> shift) & 255) * alpha * 255 +
                    ((old >> shift) & 255) * background) ~/
                numerator;
            canvas[offset] =
                (((numerator + 127) ~/ 255) << 24) |
                (blend(16) << 16) |
                (blend(8) << 8) |
                blend(0);
          }
        }
      }
    }
    return _createBmp(canvas, pcs.width, pcs.height);
  }

  static Uint8List _decodeRle(Uint8List rle, int width, int height) {
    validateDimensions(width, height);
    final pixels = Uint8List(width * height);
    int pixelIndex = 0;
    int offset = 0;
    int rowStart = 0;

    while (offset < rle.length && pixelIndex < pixels.length) {
      final b0 = rle[offset++];

      if (b0 != 0) {
        pixels[pixelIndex++] = b0;
      } else {
        if (offset >= rle.length) break;
        final b1 = rle[offset++];

        if (b1 == 0) {
          // EOL pads the unfilled part of this scanline with transparent pixels.
          pixelIndex = (rowStart + width).clamp(0, pixels.length);
          rowStart = pixelIndex;
        } else if ((b1 & 0xC0) == 0) {
          // 00xxxxxx : Run of 0, length x
          int count = b1 & 0x3F;
          if (pixelIndex + count > pixels.length) {
            count = pixels.length - pixelIndex;
          }
          pixelIndex += count; // 0 is default in Uint8List
        } else if ((b1 & 0xC0) == 0x40) {
          // 01xxxxxx LLLLLLLL : Run of 0, length ((x<<8) + L)
          if (offset >= rle.length) break;
          final b2 = rle[offset++];
          int count = ((b1 & 0x3F) << 8) + b2;
          if (pixelIndex + count > pixels.length) {
            count = pixels.length - pixelIndex;
          }
          pixelIndex += count;
        } else if ((b1 & 0xC0) == 0x80) {
          // 10xxxxxx CCCCCCCC : Run of color C, length x
          if (offset >= rle.length) break;
          final color = rle[offset++];
          int count = b1 & 0x3F;
          if (pixelIndex + count > pixels.length) {
            count = pixels.length - pixelIndex;
          }
          pixels.fillRange(pixelIndex, pixelIndex + count, color);
          pixelIndex += count;
        } else if ((b1 & 0xC0) == 0xC0) {
          // 11xxxxxx LLLLLLLL CCCCCCCC : Run of color C, length ((x<<8) + L)
          if (offset + 1 >= rle.length) break;
          final b2 = rle[offset++];
          final color = rle[offset++];
          int count = ((b1 & 0x3F) << 8) + b2;
          if (pixelIndex + count > pixels.length) {
            count = pixels.length - pixelIndex;
          }
          pixels.fillRange(pixelIndex, pixelIndex + count, color);
          pixelIndex += count;
        }
      }
    }

    return pixels;
  }

  static Uint8List _createBmp(Uint32List pixels, int width, int height) {
    // A top-down 32-bit BMP stores each ARGB value as little-endian BGRA.
    final fileSize = 54 + (width * height * 4);
    final bmp = Uint8List(fileSize);
    final view = ByteData.view(bmp.buffer);

    // File Header
    view.setUint16(0, 0x424D, Endian.little); // 'BM'
    view.setUint32(2, fileSize, Endian.little);
    view.setUint32(10, 54, Endian.little); // Offset to pixel data

    // Info Header
    view.setUint32(14, 40, Endian.little); // Header size
    view.setInt32(18, width, Endian.little);
    view.setInt32(22, -height, Endian.little); // Negative height for top-down
    view.setUint16(26, 1, Endian.little); // Planes
    view.setUint16(28, 32, Endian.little); // BPP
    view.setUint32(30, 0, Endian.little); // Compression (BI_RGB)
    view.setUint32(34, width * height * 4, Endian.little); // Image size

    // Pixels
    int pixelOffset = 54;
    for (final color in pixels) {
      view.setUint32(pixelOffset, color, Endian.little);
      pixelOffset += 4;
    }

    return bmp;
  }
}

class _PgsOdsSegment {
  final int id;
  final int version;
  final int sequenceFlag;
  final int dataLength;
  final int? width;
  final int? height;
  final Uint8List data;

  _PgsOdsSegment({
    required this.id,
    required this.version,
    required this.sequenceFlag,
    required this.dataLength,
    required this.width,
    required this.height,
    required this.data,
  });
}

class _PgsOdsAccumulator {
  final int id;
  final int version;
  final int width;
  final int height;
  final int dataLength;
  final BytesBuilder _builder = BytesBuilder(copy: false);

  _PgsOdsAccumulator({
    required this.id,
    required this.version,
    required this.width,
    required this.height,
    required this.dataLength,
  });

  void add(Uint8List data) {
    if (_builder.length + data.length > dataLength ||
        _builder.length + data.length > PgsParser.maxObjectBytes) {
      throw const FormatException('PGS 字幕对象数据超过声明长度');
    }
    _builder.add(data);
  }

  PgsOds? build() {
    PgsParser.validateDimensions(width, height);
    final bytes = _builder.takeBytes();
    if (bytes.length != dataLength) {
      throw const FormatException('PGS 字幕对象数据不完整');
    }
    if (bytes.isEmpty) return null;
    return PgsOds(
      id: id,
      version: version,
      width: width,
      height: height,
      rleData: bytes,
    );
  }
}

class PgsPcs {
  final int pts;
  final int width;
  final int height;
  final int frameRate;
  final int compositionNumber;
  final CompositionState state;
  final int paletteId;
  final List<PgsCompositionObject> objects;

  PgsPcs({
    required this.pts,
    required this.width,
    required this.height,
    required this.frameRate,
    required this.compositionNumber,
    required this.state,
    required this.paletteId,
    required this.objects,
  });

  static PgsPcs parse(ByteData data, int pts) {
    if (data.lengthInBytes < 11) throw const FormatException('PGS PCS 段不完整');
    // offset 0: width (2)
    // offset 2: height (2)
    // offset 4: frame_rate (1)
    // offset 5: composition_number (2)
    // offset 7: state (1)
    // offset 8: palette_update_flag (1)
    // offset 9: palette_id (1)
    // offset 10: number_of_composition_objects (1)

    final width = data.getUint16(0);
    final height = data.getUint16(2);
    PgsParser.validateDimensions(width, height);
    final frameRate = data.getUint8(4);
    final compositionNumber = data.getUint16(5);
    final stateRaw = data.getUint8(7);
    final state = CompositionState.values.firstWhere(
      (e) => e.index == (stateRaw >> 6),
      orElse: () => CompositionState.normal,
    );
    final paletteId = data.getUint8(9);

    final count = data.getUint8(10);
    final objects = <PgsCompositionObject>[];

    int offset = 11;
    for (int i = 0; i < count; i++) {
      if (offset + 8 > data.lengthInBytes) {
        throw const FormatException('PGS 合成对象不完整');
      }
      final objId = data.getUint16(offset);
      final winId = data.getUint8(offset + 2);
      final cropped = (data.getUint8(offset + 3) & 0x80) != 0;
      final x = data.getUint16(offset + 4);
      final y = data.getUint16(offset + 6);

      final len = cropped ? 16 : 8;
      if (offset + len > data.lengthInBytes) {
        throw const FormatException('PGS 裁剪信息不完整');
      }
      objects.add(
        PgsCompositionObject(
          objectId: objId,
          windowId: winId,
          x: x,
          y: y,
          cropX: cropped ? data.getUint16(offset + 8) : null,
          cropY: cropped ? data.getUint16(offset + 10) : null,
          cropWidth: cropped ? data.getUint16(offset + 12) : null,
          cropHeight: cropped ? data.getUint16(offset + 14) : null,
        ),
      );
      offset += len;
    }

    return PgsPcs(
      pts: pts,
      width: width,
      height: height,
      frameRate: frameRate,
      compositionNumber: compositionNumber,
      state: state,
      paletteId: paletteId,
      objects: objects,
    );
  }
}

enum CompositionState {
  normal, // 0x00
  acquisitionPoint, // 0x40
  epochStart, // 0x80
}

class PgsCompositionObject {
  final int objectId;
  final int windowId;
  final int x;
  final int y;

  final int? cropX, cropY, cropWidth, cropHeight;

  PgsCompositionObject({
    required this.objectId,
    required this.windowId,
    required this.x,
    required this.y,
    this.cropX,
    this.cropY,
    this.cropWidth,
    this.cropHeight,
  });
}

class PgsPds {
  final int id;
  final int version;
  final Map<int, int> palette; // Index -> ARGB

  PgsPds({required this.id, required this.version, required this.palette});

  static PgsPds parse(ByteData data) {
    if (data.lengthInBytes < 2) throw const FormatException('PGS PDS 段不完整');
    final id = data.getUint8(0);
    final version = data.getUint8(1);
    final palette = <int, int>{};

    int offset = 2;
    while (offset + 5 <= data.lengthInBytes) {
      final index = data.getUint8(offset);
      final y = data.getUint8(offset + 1);
      final cr = data.getUint8(offset + 2);
      final cb = data.getUint8(offset + 3);
      final a = data.getUint8(offset + 4);

      // Convert YCrCbA to ARGB with the BT.601 coefficients below.

      final yValue = y.toDouble();
      final cbValue = cb.toDouble();
      final crValue = cr.toDouble();

      final r = (yValue + 1.402 * (crValue - 128)).clamp(0, 255).toInt();
      final g =
          (yValue - 0.344136 * (cbValue - 128) - 0.714136 * (crValue - 128))
              .clamp(0, 255)
              .toInt();
      final b = (yValue + 1.772 * (cbValue - 128)).clamp(0, 255).toInt();

      // Alpha in PGS is 0=Transparent, 255=Opaque.
      // Store as Int32 ARGB
      palette[index] = (a << 24) | (r << 16) | (g << 8) | b;

      offset += 5;
    }

    return PgsPds(id: id, version: version, palette: palette);
  }
}

class PgsOds {
  final int id;
  final int version;
  final int width;
  final int height;
  final Uint8List rleData;

  PgsOds({
    required this.id,
    required this.version,
    required this.width,
    required this.height,
    required this.rleData,
  });

  static PgsOds parse(ByteData data) {
    if (data.lengthInBytes < 11) throw const FormatException('PGS ODS 段不完整');
    final id = data.getUint16(0);
    final version = data.getUint8(2);
    // sequence_flag = data.getUint8(3);
    // 0x80 = First, 0x40 = Last.
    // data_length (3 bytes) -> 4,5,6

    // This helper accepts one complete ODS; the stream parser accumulates
    // first/continuation/last fragments through _PgsOdsAccumulator.
    final width = data.getUint16(7);
    final height = data.getUint16(9);
    PgsParser.validateDimensions(width, height);
    final rleData = data.buffer.asUint8List(
      data.offsetInBytes + 11,
      data.lengthInBytes - 11,
    );

    return PgsOds(
      id: id,
      version: version,
      width: width,
      height: height,
      rleData: rleData,
    );
  }
}
