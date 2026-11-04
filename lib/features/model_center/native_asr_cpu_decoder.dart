import 'dart:io';
import 'dart:typed_data';

import 'asr_accelerator_transport.dart';

/// CPU owner for architectures/platform paths requiring the private worker.
/// Reuses the existing private native worker, PCM transport and cancellation.
class NativeAsrCpuDecoder {
  NativeAsrCpuDecoder({
    required this.configuration,
    required this.onLoad,
    this.onReady,
    Future<AsrAcceleratorTransport> Function()? openTransport,
  }) : _open =
           openTransport ??
           (() => AsrAcceleratorTransport.open(
             executable: configuration['workerExecutable'] as String?,
           ));

  final Map<String, dynamic> configuration;
  final void Function() onLoad;
  final void Function()? onReady;
  final Future<AsrAcceleratorTransport> Function() _open;
  AsrAcceleratorTransport? _transport;
  Directory? _directory;
  bool _loaded = false, _closed = false;
  Future<void>? _releasing;
  int _generation = 0;
  bool get hasLoadedModel => _loaded;

  Future<Map<String, dynamic>> decode(
    Float32List audio,
    void Function() check,
  ) async {
    await _releasing;
    final generation = _generation;
    void valid() {
      check();
      if (_closed || generation != _generation) throw StateError('转录已取消');
    }

    valid();
    Directory? pcm;
    try {
      if (_transport == null) {
        final opened = await _open();
        if (_closed || generation != _generation) {
          await opened.close();
          valid();
        }
        _transport = opened;
      }
      final root = Directory(configuration['runtimeDirectory'] as String);
      await root.create(recursive: true);
      valid();
      _directory ??= await root.createTemp('asr-cpu-run-');
      valid();
      if (!_loaded) {
        onLoad();
        await _transport!.request({
          ...configuration,
          'op': 'load',
          'backend': 'cpu',
          'floatWeights': false,
          'profileRoot': _directory!.path,
        });
        valid();
        _loaded = true;
        onReady?.call();
      }
      // Android's private service can only open its own cache files.
      final audioRoot = Platform.isAndroid || Platform.isIOS
          ? Directory.systemTemp
          : root;
      pcm = await audioRoot.createTemp('asr-cpu-pcm-');
      valid();
      final file = File('${pcm.path}${Platform.pathSeparator}samples.f32');
      await file.writeAsBytes(
        audio.buffer.asUint8List(audio.offsetInBytes, audio.lengthInBytes),
      );
      valid();
      final response = await _transport!.request({
        'op': 'decode',
        'path': file.path,
      });
      valid();
      final result = Map<String, dynamic>.from(response['result'] as Map);
      if (result['text'] is! String ||
          result['tokens'] is! List ||
          (result['tokens'] as List).any((token) => token is! String) ||
          result['timestamps'] is! List ||
          !((configuration['engine'] == 'whisper') &&
                  (result['timestamps'] as List).isEmpty) &&
              (result['tokens'] as List).length !=
                  (result['timestamps'] as List).length) {
        throw StateError('原生 CPU 返回的识别结果或时间戳无效');
      }
      final starts = result['timestamps'] as List;
      for (var i = 0; i < starts.length; i++) {
        final value = starts[i];
        if (value is! num ||
            !value.isFinite ||
            value < 0 ||
            i > 0 && value < (starts[i - 1] as num)) {
          throw StateError('原生 CPU 返回的时间戳无效');
        }
      }
      return {
        ...result,
        '_backend': 'CPU',
        '_weights': configuration['identity'] ?? '',
      };
    } catch (_) {
      await release();
      rethrow;
    } finally {
      if (pcm != null && await pcm.exists()) await pcm.delete(recursive: true);
    }
  }

  Future<void> release() => _releasing ??= _releaseOwned().whenComplete(() {
    _releasing = null;
  });

  Future<void> _releaseOwned() async {
    _generation++;
    _loaded = false;
    final transport = _transport;
    final directory = _directory;
    _transport = null;
    _directory = null;
    try {
      await transport?.close();
    } finally {
      if (directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    await release();
  }
}
