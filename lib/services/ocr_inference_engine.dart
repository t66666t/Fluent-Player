import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as im;
import 'ocr_ort_runtime.dart';
import 'package:yaml/yaml.dart';

import 'ocr_onnx.dart';
import 'ocr_native_accelerator.dart';
import 'ocr_subtitle_geometry.dart';

export 'ocr_subtitle_geometry.dart';

import '../models/ocr_model_files.dart';
import '../models/ocr_accelerator_contract.dart';

class OcrTextResult {
  final String text;
  final double confidence;
  final List<OcrTextLineResult> lines;
  const OcrTextResult(this.text, this.confidence, [this.lines = const []]);
}

class OcrTextLineResult {
  final String text;
  final double confidence;
  final int left;
  final int top;
  final int right;
  final int bottom;

  const OcrTextLineResult({
    required this.text,
    required this.confidence,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  int get width => right - left;
  int get height => bottom - top;
}

/// Shared PP-OCR runner; configuration travels with each downloaded model.
class OcrInferenceEngine {
  final OcrModelFiles files;
  final bool preferHardwareAcceleration;
  final int cpuThreads;
  int batchLimit;
  final String? provider;
  final int deviceId;
  final String coreMLUnits;
  final int? gpuMemoryLimit;
  final bool conservative;
  OrtSession? _detSession, _recSession;
  List<String> _characters = const [];
  bool _configurationLoaded = false;
  bool _batchSupported = true;
  List<double> _detMean = const [0.5, 0.5, 0.5];
  List<double> _detStd = const [0.5, 0.5, 0.5];
  bool _detBgr = false, _recBgr = false;
  int _recHeight = 48, _recBaseWidth = 320, _recMaxWidth = 3200;
  double _detThreshold = 0.3, _boxThreshold = 0.45;
  String _provider = 'CPU';
  String activeBackend = 'CPU';
  final _inputs = <String, ({OrtValueTensor tensor, Float32List data})>{};
  final Map<String, int> lastTimingsUs = {};
  final _executionShapes = <String>{};
  String get executionShape => _executionShapes.join(',');
  T _timed<T>(String phase, T Function() action) {
    final watch = Stopwatch()..start();
    try {
      return action();
    } finally {
      lastTimingsUs.update(
        phase,
        (n) => n + watch.elapsedMicroseconds,
        ifAbsent: () => watch.elapsedMicroseconds,
      );
    }
  }

  OcrInferenceEngine(
    this.files, {
    this.preferHardwareAcceleration = false,
    this.cpuThreads = 2,
    this.batchLimit = 1,
    this.provider,
    this.deviceId = 0,
    this.coreMLUnits = 'ALL',
    this.gpuMemoryLimit,
    this.conservative = false,
  });

  static String get runtimeVersion =>
      '${OrtEnv.version}:${OcrNativeAccelerator.instance?.version ?? 'ort'}';

  /// The environment is isolate-owned. Call only when a dedicated worker has
  /// disposed every session and tensor, immediately before that worker exits.
  static void releaseWorkerEnvironment() => OrtEnv.instance.release();

  static List<String> availableBackends() {
    final providers = OrtEnv.instance.availableProviders();
    return [
      'CPU',
      if (OcrNativeAccelerator.instance != null) ...ocrNativeProviders.keys,
      if (providers.contains(OrtProvider.xnnpack)) 'XNNPACK',
      if (Platform.isAndroid && providers.contains(OrtProvider.nnapi)) 'NNAPI',
      if ((Platform.isMacOS || Platform.isIOS) &&
          providers.contains(OrtProvider.coreml))
        'CoreML',
      if (Platform.isWindows && providers.contains(OrtProvider.directml))
        'DirectML',
      if ((Platform.isWindows || Platform.isLinux) &&
          providers.contains(OrtProvider.cuda))
        'CUDA',
      if ((Platform.isWindows || Platform.isLinux) &&
          providers.contains(OrtProvider.tensorrt))
        'TensorRT',
      if ((Platform.isWindows || Platform.isLinux) &&
          providers.contains(OrtProvider.openvino))
        'OpenVINO',
      if (Platform.isLinux && providers.contains(OrtProvider.migraphx))
        'MIGraphX',
    ];
  }

  Future<void> _loadConfiguration() async {
    if (_configurationLoaded) return;
    if (files.legacy) {
      _characters = [
        '',
        ...(await File(
          files.dictionary,
        ).readAsLines()).where((s) => s.isNotEmpty),
        ' ',
      ];
    } else {
      final rec = loadYaml(await File(files.dictionary).readAsString()) as Map;
      if ((rec['PostProcess'] as Map)['name'] != 'CTCLabelDecode') {
        throw StateError('OCR 识别模型的输出约定不受支持');
      }
      bool bgr(Map config) {
        final ops = (config['PreProcess'] as Map)['transform_ops'] as List;
        final decode = ops
            .whereType<Map>()
            .map((m) => m['DecodeImage'])
            .whereType<Map>()
            .first;
        final mode = decode['img_mode'];
        if (mode != 'BGR' && mode != 'RGB') throw StateError('OCR 模型颜色配置无效');
        return mode == 'BGR';
      }

      _recBgr = bgr(rec);
      final resize = ((rec['PreProcess'] as Map)['transform_ops'] as List)
          .whereType<Map>()
          .map((m) => m['RecResizeImg'])
          .whereType<Map>()
          .first;
      final shape = List<int>.from(resize['image_shape'] as List);
      if (shape.length != 3 ||
          shape[0] != 3 ||
          shape[1] <= 0 ||
          shape[2] <= 0) {
        throw StateError('OCR 识别输入配置无效');
      }
      _recHeight = shape[1];
      _recBaseWidth = shape[2];
      final hpi = rec['Hpi'] as Map?;
      final backends = hpi?['backend_configs'] as Map?;
      final inference = backends?['paddle_infer'] as Map?;
      final dynamicShapes = inference?['trt_dynamic_shapes'] as Map?;
      final shapes = dynamicShapes?['x'] as List?;
      if (shapes != null && shapes.length == 3) {
        _recMaxWidth = (shapes.last as List).last as int;
      }
      final chars = (rec['PostProcess'] as Map)['character_dict'] as List;
      _characters = ['', ...chars.map((c) => c.toString()), ' '];
      final det =
          loadYaml(await File(files.detectionConfig!).readAsString()) as Map;
      _detBgr = bgr(det);
      for (final op in ((det['PreProcess'] as Map)['transform_ops'] as List)) {
        final normalize = (op as Map)['NormalizeImage'];
        if (normalize is Map) {
          _detMean = (normalize['mean'] as List)
              .map((n) => (n as num).toDouble())
              .toList();
          _detStd = (normalize['std'] as List)
              .map((n) => (n as num).toDouble())
              .toList();
        }
      }
      final post = det['PostProcess'] as Map;
      _detThreshold = (post['thresh'] as num).toDouble();
      _boxThreshold = (post['box_thresh'] as num).toDouble();
    }
    if (_characters.length < 3) throw StateError('OCR 字典为空或无效');
    _configurationLoaded = true;
  }

  Future<void> initializeDetectionOnly({int cpuThreads = 1}) async {
    if (_detSession != null) return;
    await _loadConfiguration();
    _provider =
        provider ??
        (preferHardwareAcceleration ? availableBackends().last : 'CPU');
    try {
      _detSession = await _openSession(
        files.detection,
        cpuThreads,
        _provider,
        deviceId: deviceId,
        coreMLUnits: coreMLUnits,
        gpuMemoryLimit: gpuMemoryLimit,
        conservative: conservative,
      );
    } catch (_) {
      if (_provider == 'CPU') rethrow;
      _provider = 'CPU';
      _detSession = await _openSession(
        files.detection,
        cpuThreads,
        _provider,
        conservative: conservative,
      );
    }
    activeBackend = _provider == 'CPU' ? 'CPU（$cpuThreads 线程）' : _provider;
  }

  Future<void> initialize() async {
    if (_recSession != null) return;
    await initializeDetectionOnly(cpuThreads: cpuThreads);
    try {
      _recSession = await _openSession(
        files.recognition,
        cpuThreads,
        _provider,
        deviceId: deviceId,
        coreMLUnits: coreMLUnits,
        gpuMemoryLimit: gpuMemoryLimit,
        conservative: conservative,
      );
    } catch (_) {
      await _detSession?.release();
      _detSession = null;
      if (_provider == 'CPU') rethrow;
      _provider = 'CPU';
      _detSession = await _openSession(
        files.detection,
        cpuThreads,
        _provider,
        conservative: conservative,
      );
      _recSession = await _openSession(
        files.recognition,
        cpuThreads,
        _provider,
        conservative: conservative,
      );
      activeBackend = 'CPU（$cpuThreads 线程）';
    }
    if (files.legacy) {
      // Legacy English shipped with a different alphabet from its recognizer.
      // The original converted weights carry their authoritative dictionary.
      final embedded = readOcrOnnxMetadata(_recSession!, 'character');
      if (embedded != null && embedded.isNotEmpty) {
        _characters = [
          '',
          ...const LineSplitter().convert(embedded).where((c) => c.isNotEmpty),
          ' ',
        ];
      }
    }
  }

  Future<OrtSession> _openSession(
    String path,
    int threads,
    String selected, {
    int deviceId = 0,
    String coreMLUnits = 'ALL',
    int? gpuMemoryLimit,
    bool conservative = false,
  }) async {
    if (ocrNativeProviders.containsKey(selected)) {
      // The legacy recognizer's authoritative alphabet is embedded in ONNX.
      // Keep that existing loader until a separate converted contract is tested.
      if (files.legacy || files.acceleratorContract != ocrAcceleratorContract) {
        throw StateError('当前模型继续使用原有 OCR 引擎');
      }
      final runtime = OcrNativeAccelerator.instance;
      if (runtime == null) throw StateError('OCR 硬件加速组件不可用');
      return runtime.open(path, selected, threads);
    }
    return openOcrOnnxSession(
      path,
      threads,
      selected,
      deviceId: deviceId,
      coreMLUnits: coreMLUnits,
      gpuMemoryLimit: gpuMemoryLimit,
      conservative: conservative,
    );
  }

  ({OrtValueTensor tensor, Float32List data}) _input(List<int> shape) {
    final key = shape.join('x');
    _executionShapes.add(key);
    final old = _inputs.remove(key);
    if (old != null) {
      _inputs[key] = old;
      return old;
    }
    if (_inputs.length >= 2) {
      _inputs.remove(_inputs.keys.first)!.tensor.release();
    }
    final tensor = OrtValueTensor.createTensorWithDataList(
      Float32List(shape.fold<int>(1, (n, v) => n * v)),
      shape,
    );
    final value = (tensor: tensor, data: OcrFloatTensorView(tensor).values);
    _inputs[key] = value;
    return value;
  }

  void _normalizeImage(
    im.Image image,
    Float32List data,
    int offset,
    int targetWidth,
    int targetHeight,
    List<double> mean,
    List<double> std, {
    required bool bgr,
  }) {
    final pixels = image.getBytes(
      order: bgr ? im.ChannelOrder.bgr : im.ChannelOrder.rgb,
    );
    final plane = targetWidth * targetHeight;
    var source = 0;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final i = offset + y * targetWidth + x;
        data[i] = (pixels[source++] / 255 - mean[0]) / std[0];
        data[plane + i] = (pixels[source++] / 255 - mean[1]) / std[1];
        data[plane * 2 + i] = (pixels[source++] / 255 - mean[2]) / std[2];
      }
    }
  }

  Future<OcrTextResult> recognizeFile(String path) async {
    final bytes = await File(path).readAsBytes();
    final image = im.decodeImage(bytes);
    if (image == null) return const OcrTextResult('', 0);
    return recognizeImage(image);
  }

  Future<OcrTextResult> recognizeImage(
    im.Image source, {
    OcrSubtitleGeometry? geometry,
  }) async {
    if (_detSession == null || _recSession == null) await initialize();
    lastTimingsUs.clear();
    _executionShapes.clear();
    final boxes = await detectBoxesImage(source, geometry: geometry);
    if (boxes.isEmpty) return const OcrTextResult('', 0);
    final results =
        <
          ({
            String text,
            double confidence,
            int top,
            int left,
            int right,
            int bottom,
          })
        >[];
    final crops = _timed(
      'preprocessingUs',
      () => boxes
          .map(
            (box) => im.copyCrop(
              source,
              x: box.left,
              y: box.top,
              width: math.max(1, box.right - box.left),
              height: math.max(1, box.bottom - box.top),
            ),
          )
          .toList(),
    );
    final readings = await _recognizeLines(crops);
    for (var boxIndex = 0; boxIndex < boxes.length; boxIndex++) {
      final box = boxes[boxIndex];
      final result = readings[boxIndex];
      final combinedConfidence = result.confidence * box.score;
      if (result.text.trim().isNotEmpty &&
          result.confidence >= 0.40 &&
          combinedConfidence >= 0.32) {
        results.add((
          text: result.text.trim(),
          confidence: combinedConfidence,
          top: box.top,
          left: box.left,
          right: box.right,
          bottom: box.bottom,
        ));
      }
    }
    if (results.isEmpty) return const OcrTextResult('', 0);
    // PP-OCR is deliberately sensitive and also finds watermarks and tiny UI
    // labels inside a manually selected subtitle band. Subtitle glyphs in one
    // band normally share a scale, so reject components that are both tiny in
    // the crop and clear scale outliers before assembling the text. Keep the
    // threshold relative so this remains resolution independent.
    final referenceHeight = results
        .map((item) => item.bottom - item.top)
        .reduce(math.max);
    final minimumHeight = math.max(
      4,
      math.max(
        (source.height * 0.045).round(),
        (referenceHeight * 0.55).round(),
      ),
    );
    results.removeWhere(
      (item) =>
          item.bottom - item.top < minimumHeight ||
          (item.confidence < 0.40 &&
              item.right - item.left < source.width * 0.08),
    );
    if (results.isEmpty) return const OcrTextResult('', 0);
    results.sort((a, b) {
      final dy = a.top - b.top;
      return dy.abs() > source.height * 0.08 ? dy : a.left - b.left;
    });
    final lines =
        <
          List<
            ({
              String text,
              double confidence,
              int top,
              int left,
              int right,
              int bottom,
            })
          >
        >[];
    for (final item in results) {
      if (lines.isEmpty ||
          (item.top - lines.last.first.top).abs() > source.height * 0.08) {
        lines.add([item]);
      } else {
        lines.last.add(item);
      }
    }
    final recognizedLines = lines.map((line) {
      line.sort((a, b) => a.left - b.left);
      return OcrTextLineResult(
        text: line.map((item) => item.text).join(' '),
        confidence:
            line.fold<double>(0, (value, item) => value + item.confidence) /
            line.length,
        left: line.map((item) => item.left).reduce(math.min),
        top: line.map((item) => item.top).reduce(math.min),
        right: line.map((item) => item.right).reduce(math.max),
        bottom: line.map((item) => item.bottom).reduce(math.max),
      );
    }).toList();
    final text = recognizedLines.map((line) => line.text).join('\n');
    final confidence =
        recognizedLines.fold<double>(
          0,
          (value, line) => value + line.confidence,
        ) /
        recognizedLines.length;
    return OcrTextResult(text, confidence, recognizedLines);
  }

  Future<List<OcrDetectedBox>> detectBoxesImage(
    im.Image source, {
    int maxSide = 640,
    OcrSubtitleGeometry? geometry,
  }) async {
    if (_detSession == null) await initializeDetectionOnly();
    final limit = math.max(32, maxSide);
    final scale = math.min(1.0, limit / math.max(source.width, source.height));
    final width = math.max(32, ((source.width * scale) / 32).round() * 32);
    final height = math.max(32, ((source.height * scale) / 32).round() * 32);
    final buffer = _timed('preprocessingUs', () {
      final resized = im.copyResize(source, width: width, height: height);
      final input = _input([1, 3, height, width]);
      _normalizeImage(
        resized,
        input.data,
        0,
        width,
        height,
        _detMean,
        _detStd,
        bgr: _detBgr,
      );
      return input;
    });
    final runOptions = OrtRunOptions();
    List<OrtValue?> outputs = [];
    late final Float32List flat;
    late final int mapHeight, mapWidth;
    try {
      outputs = _timed(
        'inferenceUs',
        () => _detSession!.run(runOptions, {
          _detSession!.inputNames.first: buffer.tensor,
        }),
      );
      if (outputs.isEmpty || outputs.first == null) return const [];
      final view = OcrFloatTensorView(outputs.first!);
      if (view.shape.length != 4 || view.shape[0] != 1 || view.shape[1] != 1) {
        throw StateError('OCR 检测输出尺寸无效：${view.shape}');
      }
      mapHeight = view.shape[2];
      mapWidth = view.shape[3];
      flat = Float32List.fromList(view.values);
    } finally {
      for (final output in outputs) {
        output?.release();
      }
      runOptions.release();
    }
    return _timed('detectionPostprocessingUs', () {
      final map = List.generate(
        mapHeight,
        (y) => Float32List.sublistView(flat, y * mapWidth, (y + 1) * mapWidth),
      );
      final visited = Uint8List(mapWidth * mapHeight);
      final found = <OcrDetectedBox>[];
      for (var sy = 0; sy < mapHeight; sy++) {
        for (var sx = 0; sx < mapWidth; sx++) {
          final startIndex = sy * mapWidth + sx;
          if (visited[startIndex] != 0 || map[sy][sx] < _detThreshold) continue;
          final queueX = <int>[sx];
          final queueY = <int>[sy];
          visited[startIndex] = 1;
          var cursor = 0;
          var minX = sx;
          var maxX = sx;
          var minY = sy;
          var maxY = sy;
          var score = 0.0;
          var count = 0;
          while (cursor < queueX.length) {
            final x = queueX[cursor];
            final y = queueY[cursor++];
            score += map[y][x];
            count++;
            minX = math.min(minX, x);
            maxX = math.max(maxX, x);
            minY = math.min(minY, y);
            maxY = math.max(maxY, y);
            for (final pair in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
              final nx = x + pair.$1;
              final ny = y + pair.$2;
              if (nx < 0 || ny < 0 || nx >= mapWidth || ny >= mapHeight) {
                continue;
              }
              final index = ny * mapWidth + nx;
              if (visited[index] == 0 && map[ny][nx] >= _detThreshold) {
                visited[index] = 1;
                queueX.add(nx);
                queueY.add(ny);
              }
            }
          }
          if (count < 8 || score / count < _boxThreshold) continue;
          final padX = ocrDetectionHorizontalPadding(
            maxX - minX + 1,
            maxY - minY + 1,
          );
          final padY = math.max(2, ((maxY - minY + 1) * 0.35).round());
          final left =
              (((minX - padX).clamp(0, mapWidth - 1)) * source.width / mapWidth)
                  .floor();
          final right =
              ((((maxX + padX + 1).clamp(1, mapWidth)) *
                          source.width /
                          mapWidth)
                      .ceil())
                  .clamp(left + 1, source.width);
          final top =
              (((minY - padY).clamp(0, mapHeight - 1)) *
                      source.height /
                      mapHeight)
                  .floor();
          final bottom =
              ((((maxY + padY + 1).clamp(1, mapHeight)) *
                          source.height /
                          mapHeight)
                      .ceil())
                  .clamp(top + 1, source.height);
          found.add(
            OcrDetectedBox(
              left,
              top,
              right,
              bottom,
              score / count,
              contentBounds: (
                left: (minX * source.width / mapWidth).floor(),
                top: (minY * source.height / mapHeight).floor(),
                right: ((maxX + 1) * source.width / mapWidth).ceil(),
                bottom: ((maxY + 1) * source.height / mapHeight).ceil(),
              ),
            ),
          );
        }
      }
      return prepareOcrSubtitleBoxes(found, source.height, geometry: geometry);
    });
  }

  Future<List<OcrTextResult>> _recognizeLines(List<im.Image> lines) async {
    final results = List<OcrTextResult>.filled(
      lines.length,
      const OcrTextResult('', 0),
    );
    int widthFor(im.Image line) => math
        .max(
          _recBaseWidth,
          ((line.width * _recHeight / math.max(1, line.height)).ceil() + 31) ~/
              32 *
              32,
        )
        .clamp(_recBaseWidth, _recMaxWidth);
    final indices = List.generate(lines.length, (i) => i)
      ..sort((a, b) => widthFor(lines[a]).compareTo(widthFor(lines[b])));
    var cursor = 0;
    while (cursor < indices.length) {
      final targetWidth = files.legacy
          ? _recBaseWidth
          : widthFor(lines[indices[cursor]]);
      // CTC output is much larger than its image input: bound it before batching.
      // PP-OCR CTC emits up to one step per four input pixels, not eight.
      // Underestimating this doubles the admitted output on dense/wide rows.
      final outputBytesPerLine = targetWidth ~/ 4 * _characters.length * 4;
      final outputBudget =
          (Platform.isAndroid || Platform.isIOS ? 16 : 32) * 1024 * 1024;
      final limit = files.legacy || !_batchSupported
          ? 1
          : math.min(
              batchLimit,
              math.max(1, outputBudget ~/ math.max(1, outputBytesPerLine)),
            );
      var count = 1;
      while (count < limit &&
          cursor + count < indices.length &&
          widthFor(lines[indices[cursor + count]]) == targetWidth) {
        count++;
      }
      final input = _timed('preprocessingUs', () {
        final input = _input([count, 3, _recHeight, targetWidth]);
        input.data.fillRange(0, input.data.length, files.legacy ? 1 : 0);
        for (var n = 0; n < count; n++) {
          final line = lines[indices[cursor + n]];
          final contentWidth = math.min(
            targetWidth,
            math.max(
              1,
              files.legacy
                  ? (line.width * _recHeight / math.max(1, line.height)).round()
                  : (line.width * _recHeight / math.max(1, line.height)).ceil(),
            ),
          );
          final resized = im.copyResize(
            line,
            width: contentWidth,
            height: _recHeight,
          );
          _normalizeImage(
            resized,
            input.data,
            n * 3 * _recHeight * targetWidth,
            targetWidth,
            _recHeight,
            const [0.5, 0.5, 0.5],
            bgr: _recBgr,
            const [0.5, 0.5, 0.5],
          );
        }
        return input;
      });
      final options = OrtRunOptions();
      List<OrtValue?> outputs = [];
      try {
        outputs = _timed(
          'inferenceUs',
          () => _recSession!.run(options, {
            _recSession!.inputNames.first: input.tensor,
          }),
        );
        if (outputs.isEmpty || outputs.first == null) {
          throw StateError('OCR 识别输出为空');
        }
        final view = OcrFloatTensorView(outputs.first!);
        if (view.shape.length != 3 ||
            view.shape[0] != count ||
            view.shape[2] != _characters.length) {
          throw StateError(
            'OCR 字典与模型不匹配：${view.shape} / ${_characters.length}',
          );
        }
        _timed('ctcDecodingUs', () {
          final steps = view.shape[1], classes = view.shape[2];
          for (var n = 0; n < count; n++) {
            final buffer = StringBuffer();
            var previous = -1, characters = 0;
            var confidence = 0.0;
            for (var t = 0; t < steps; t++) {
              final offset = (n * steps + t) * classes;
              var best = 0;
              var score = double.negativeInfinity;
              for (var c = 0; c < classes; c++) {
                final value = view.values[offset + c];
                if (value > score) {
                  best = c;
                  score = value;
                }
              }
              if (best != 0 && best != previous) {
                buffer.write(_characters[best]);
                confidence += score;
                characters++;
              }
              previous = best;
            }
            results[indices[cursor + n]] = OcrTextResult(
              buffer.toString(),
              characters == 0 ? 0 : confidence / characters,
            );
          }
        });
      } catch (_) {
        if (count <= 1) rethrow;
        _batchSupported = false;
        continue;
      } finally {
        for (final output in outputs) {
          output?.release();
        }
        options.release();
      }
      cursor += count;
    }
    return results;
  }

  Future<void> dispose() async {
    await _detSession?.release();
    await _recSession?.release();
    _detSession = null;
    _recSession = null;
    for (final input in _inputs.values) {
      input.tensor.release();
    }
    _inputs.clear();
  }
}
