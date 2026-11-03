// Developer-only validation. Never scan weights or add work to app startup.
import 'package:video_player_app/features/model_center/model_adapters.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/services/ocr_model_catalog.dart';

void validateModelIntegration(
  List<ModelArtifact> models,
  List<OcrModelPreset> presets,
) {
  final byId = <String, ModelArtifact>{};
  final directoryIds = <String>{};
  for (final model in models) {
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$').hasMatch(model.id) ||
        !directoryIds.add(model.id.toLowerCase())) {
      throw FormatException('模型 ID 无效或重复：${model.id}');
    }
    byId[model.id] = model;
    if (!RegExp(r'^(?:[a-f0-9]{40}|[a-f0-9]{64})$').hasMatch(model.revision)) {
      throw FormatException('${model.id}：请固定完整模型版本');
    }
    final names = model.files.map((f) => f.name).toSet();
    if (names.isEmpty ||
        names.length != model.files.length ||
        names.map((n) => n.toLowerCase()).toSet().length != names.length) {
      throw FormatException('${model.id}：文件名为空或重复');
    }
    final List<String> required;
    switch (model.purpose) {
      case ModelPurpose.transcription:
        required = localAsrAdapter(model.engine).files;
        if (localAsrAdapter(model.engine).sharedCpuGpuWeights &&
            (names.length != 1 || !qwenAsrWeightFiles.contains(names.single))) {
          throw FormatException('${model.id}：需要一份已适配的 Qwen 音频 GGUF');
        }
      case ModelPurpose.translation:
        if (!localTranslationAdapters.containsKey(model.engine) ||
            !model.files.first.name.endsWith('.gguf') ||
            names.where((n) => n.endsWith('.gguf')).length != 1) {
          throw FormatException('${model.id}：未接入的翻译引擎或 GGUF 文件约定');
        }
        required = const [];
      case ModelPurpose.enhancement:
        required = switch (model.engine) {
          'denoiser' => const ['model.onnx'],
          'punctuation' => const ['model.int8.onnx'],
          'ctc-alignment-en' || 'ctc-alignment-zh' => const [
            'model.int8.onnx',
            'vocab.json',
            'preprocessor_config.json',
          ],
          'qwen3-alignment' => const ['qwen3-forced-aligner-0.6b-f16.gguf'],
          'ecapa-language-id' => const ['ecapa-lid-107-f16.gguf'],
          _ => throw FormatException('${model.id}：未接入的增强引擎'),
        };
      case ModelPurpose.acceleration:
        required = localAsrAdapter(model.engine).gpuFiles;
        if (required.isEmpty) {
          throw FormatException('${model.id}：原生加速器尚未接入此引擎');
        }
      case ModelPurpose.ocr:
        required = switch (model.engine) {
          'ppocr' => const ['inference.onnx', 'inference.yml'],
          'ppocr-legacy' => const [],
          _ => throw FormatException('${model.id}：未接入的 OCR 引擎'),
        };
    }
    if (!names.containsAll(required)) {
      throw FormatException(
        '${model.id}：缺少适配器所需文件 ${required.toSet().difference(names)}',
      );
    }
  }
  for (final model in models.where(
    (m) => m.purpose == ModelPurpose.acceleration,
  )) {
    final primaryId = model.id.endsWith('-gpu')
        ? model.id.substring(0, model.id.length - 4)
        : '';
    final primary = byId[primaryId];
    if (primary?.purpose != ModelPurpose.transcription ||
        primary?.engine != model.engine) {
      throw FormatException('${model.id}：加速包必须匹配独立主模型 ID 和引擎');
    }
  }
  final presetIds = <String>{};
  for (final preset in presets) {
    if (!presetIds.add(preset.id)) {
      throw FormatException('OCR 组合 ID 重复：${preset.id}');
    }
    for (final id in preset.componentIds) {
      if (byId[id]?.purpose != ModelPurpose.ocr) {
        throw FormatException('${preset.id}：OCR 组件不存在或用途不匹配：$id');
      }
    }
  }
}
