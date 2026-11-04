import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_model_guide.dart';

void main() {
  test(
    'newer chat models come before older ones, and specialized models last',
    () {
      final presented = presentModels(
        const [
          AiModelInfo(id: 'text-embedding-3-large'),
          AiModelInfo(id: 'gpt-3.5-turbo', releasedAt: null),
          AiModelInfo(id: 'gpt-4o', contextWindow: 128000),
          AiModelInfo(id: 'o3-mini'),
          AiModelInfo(id: 'gpt-5.4', description: '当前旗舰'),
        ].map((model) {
          if (model.id == 'gpt-3.5-turbo') {
            return AiModelInfo(
              id: model.id,
              releasedAt: DateTime.utc(2023, 3, 1),
            );
          }
          if (model.id == 'gpt-4o') {
            return AiModelInfo(
              id: model.id,
              contextWindow: 128000,
              releasedAt: DateTime.utc(2024, 5, 13),
            );
          }
          if (model.id == 'gpt-5.4') {
            return AiModelInfo(
              id: model.id,
              description: '当前旗舰',
              releasedAt: DateTime.utc(2026, 3, 1),
            );
          }
          return model;
        }).toList(),
      );

      expect(presented.map((item) => item.model.id), [
        'gpt-5.4',
        'o3-mini',
        'gpt-4o',
        'gpt-3.5-turbo',
        'text-embedding-3-large',
      ]);
      expect(presented[0].age, AiModelAge.latest);
      expect(presented[0].role, AiModelRole.chat);
      expect(presented[0].headline, '对话');
      expect(presented[0].releasedLabel, '2026-03');
      expect(presented[1].role, AiModelRole.reasoning);
      expect(presented[1].age, AiModelAge.previous);
      expect(presented[2].role, AiModelRole.vision);
      expect(presented[2].displayContext, 128000);
      expect(presented[2].contextIsEstimate, isFalse);
      expect(presented[3].age, AiModelAge.older);
      expect(presented[3].contextIsEstimate, isTrue);
      expect(presented[3].displayContext, 16385);
      expect(presented[4].specialized, isTrue);
      expect(presented[4].role, AiModelRole.embedding);
      expect(presented[4].groupTitle, '专用模型');
    },
  );

  test('an id date outranks a family guess and is shown as a real month', () {
    final presented = presentModels(const [
      AiModelInfo(id: 'qwen3.6-plus-2026-04-02'),
      AiModelInfo(id: 'deepseek-v3'),
      AiModelInfo(id: 'deepseek-v4-pro'),
    ]);
    expect(presented.first.model.id, 'qwen3.6-plus-2026-04-02');
    expect(presented.first.releasedLabel, '2026-04');
    expect(presented.first.age, AiModelAge.latest);
    final deepseek = presented
        .where((item) => item.model.id.startsWith('deepseek'))
        .toList();
    expect(deepseek.map((item) => item.model.id), [
      'deepseek-v4-pro',
      'deepseek-v3',
    ]);
    expect(deepseek.first.headline, '旗舰对话');
    expect(deepseek.last.age, AiModelAge.previous);
  });

  test('provider modality metadata marks a vision model', () {
    final info = AiModelInfo.fromJson({
      'id': 'vendor/custom-vision',
      'created': 1704067200,
      'architecture': {
        'modality': 'text+image->text',
        'input_modalities': ['text', 'image'],
        'output_modalities': ['text'],
      },
    });
    final presented = presentModels([info]).single;
    expect(info.releasedAt, DateTime.utc(2024, 1, 1));
    expect(presented.role, AiModelRole.vision);
    expect(info.inputModalities, ['text', 'image']);
  });
}
