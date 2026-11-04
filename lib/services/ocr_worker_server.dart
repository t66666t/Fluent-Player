import '../models/ocr_model_files.dart';
import '../models/ocr_compute_preferences.dart';
import 'ocr_device_probe.dart';
import 'ocr_processing_worker.dart';

/// Shared implementation for the desktop executable and Android's private
/// process. Only metadata crosses IPC; frame buffers stay in bounded files.
class OcrWorkerServer {
  OcrWorkerServer(this.checkAllocation);
  final Future<void> Function(int bytes) checkAllocation;
  OcrProcessingWorker? _worker;
  Future<Map<String, Object?>> request(Map<String, dynamic> message) async {
    switch (message['op']) {
      case 'capabilities':
        return probeOcrDevices(
          isolated: true,
          probeNativeHardware: message['probeNativeHardware'] != false,
          onlyProvider: message['onlyProvider'] as String?,
        ).toJson();
      case 'start':
        if (_worker != null) throw StateError('OCR worker already initialized');
        final expected = message['deviceKey'];
        final expectedProvider = expected is String
            ? ocrProviderNames
                  .where((p) => expected.startsWith('$p:'))
                  .firstOrNull
            : null;
        if (expected is String &&
            !probeOcrDevices(
              isolated: true,
              onlyProvider: expectedProvider,
            ).devices.any((d) => d.key == expected)) {
          throw StateError('加速设备已发生变化，请重新检测');
        }
        _worker = await OcrProcessingWorker.start(
          OcrModelFiles.fromMessage(message['files'] as Map),
          tracks: {
            for (final e in (message['tracks'] as Map).entries)
              int.parse(e.key.toString()): OcrModelFiles.fromMessage(
                e.value as Map,
              ),
          },
          cpuThreads: message['threads'] as int,
          batchLimit: message['batchLimit'] as int,
          checkAllocation: checkAllocation,
          conservative: message['conservative'] == true,
        );
        return {
          'runtimeVersion': _worker!.runtimeVersion,
          'backends': _worker!.availableBackends,
        };
      case 'frame':
        return (await _worker!.analyzeCommand(
          Map<String, Object?>.from(message['command'] as Map),
        )).toMessage();
      case 'restore':
        await _worker!.restoreFrameHistory({
          for (final e in (message['states'] as Map).entries)
            int.parse(e.key.toString()): Map<String, dynamic>.from(
              e.value as Map,
            ),
        });
      case 'reset':
        await _worker!.resetFrameHistory();
      case 'closeFrames':
        await _worker!.closeFrameFiles();
      case 'releaseModels':
        await _worker!.releaseIdleModels();
      case 'close':
        await close();
      default:
        throw StateError('Unsupported OCR operation');
    }
    return const {};
  }

  Future<void> close() async {
    await _worker?.close();
    _worker = null;
  }
}
