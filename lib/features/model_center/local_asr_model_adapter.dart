import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'model_adapters.dart';

/// Configuration only: no bindings or files are opened by these builders.
/// Preserve the existing native defaults and canonical export filenames.
sherpa.OfflineRecognizerConfig localOfflineAsrConfiguration({
  required String engine,
  required String directory,
  required String language,
  required int threads,
  String hotwordsFile = '',
}) {
  final architecture = localAsrAdapter(engine).architecture;
  if (architecture == LocalAsrArchitecture.zipformerStreaming) {
    throw ArgumentError('此 Zipformer 导出必须使用流式识别器');
  }
  if (localAsrAdapter(engine).nativeWorker) {
    throw ArgumentError('此架构使用独立原生识别器，不能交给旧版 sherpa 加载');
  }
  final appliedHotwords = architecture == LocalAsrArchitecture.whisper
      ? ''
      : hotwordsFile;
  return sherpa.OfflineRecognizerConfig(
    model: sherpa.OfflineModelConfig(
      tokens: p.join(
        directory,
        architecture == LocalAsrArchitecture.whisper
            ? 'turbo-tokens.txt'
            : 'tokens.txt',
      ),
      numThreads: threads,
      provider: 'cpu',
      debug: false,
      whisper: architecture == LocalAsrArchitecture.whisper
          ? sherpa.OfflineWhisperModelConfig(
              encoder: p.join(directory, 'turbo-encoder.int8.onnx'),
              decoder: p.join(directory, 'turbo-decoder.int8.onnx'),
              language: language == 'auto' ? '' : language,
              // Turbo performs ASR here. All subtitle translation uses the
              // existing text translation pipeline, including non-English.
              task: 'transcribe',
            )
          : const sherpa.OfflineWhisperModelConfig(),
      senseVoice: architecture == LocalAsrArchitecture.senseVoice
          ? sherpa.OfflineSenseVoiceModelConfig(
              model: p.join(directory, 'model.int8.onnx'),
              language: language,
              useInverseTextNormalization: true,
            )
          : const sherpa.OfflineSenseVoiceModelConfig(),
      dolphin: architecture == LocalAsrArchitecture.dolphin
          ? sherpa.OfflineDolphinModelConfig(
              model: p.join(directory, 'model.int8.onnx'),
            )
          : const sherpa.OfflineDolphinModelConfig(),
      transducer: architecture == LocalAsrArchitecture.parakeetTdt
          ? sherpa.OfflineTransducerModelConfig(
              encoder: p.join(directory, 'encoder.int8.onnx'),
              decoder: p.join(directory, 'decoder.int8.onnx'),
              joiner: p.join(directory, 'joiner.int8.onnx'),
            )
          : const sherpa.OfflineTransducerModelConfig(),
      modelType: architecture == LocalAsrArchitecture.parakeetTdt
          ? 'nemo_transducer'
          : '',
    ),
    decodingMethod: appliedHotwords.isNotEmpty
        ? 'modified_beam_search'
        : 'greedy_search',
    hotwordsFile: appliedHotwords,
    hotwordsScore: 1.5,
  );
}

sherpa.OnlineRecognizerConfig localStreamingAsrConfiguration({
  required String engine,
  required String directory,
  required int threads,
  String hotwordsFile = '',
}) {
  if (!localAsrAdapter(engine).streaming) {
    throw ArgumentError('此模型未接入流式识别器');
  }
  return sherpa.OnlineRecognizerConfig(
    model: sherpa.OnlineModelConfig(
      tokens: p.join(directory, 'tokens.txt'),
      transducer: sherpa.OnlineTransducerModelConfig(
        encoder: p.join(directory, 'encoder.int8.onnx'),
        decoder: p.join(directory, 'decoder.int8.onnx'),
        joiner: p.join(directory, 'joiner.int8.onnx'),
      ),
      modelingUnit: 'cjkchar+bpe',
      bpeVocab: p.join(directory, 'bpe.vocab'),
      numThreads: threads,
      provider: 'cpu',
      debug: false,
    ),
    enableEndpoint: false,
    decodingMethod: hotwordsFile.isNotEmpty
        ? 'modified_beam_search'
        : 'greedy_search',
    hotwordsFile: hotwordsFile,
    hotwordsScore: 1.5,
  );
}
