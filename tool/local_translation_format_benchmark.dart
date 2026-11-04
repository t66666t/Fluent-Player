// Compare output framing without changing weights, backend or batch contents.
// dart run tool/local_translation_format_benchmark.dart <worker> <weights> <report>
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:video_player_app/features/model_center/local_translation_batch.dart';
import 'package:video_player_app/features/model_center/translation_inference.dart';

const _texts = [
  'Good morning, everyone.',
  'Today we are going to explore how this machine works.',
  'First, make sure the power is turned off.',
  'Do not touch the red wire.',
  'Can you pass me the small screwdriver?',
  'There should be three screws on the back.',
  'Be careful. This part is very fragile.',
  'I think we found the problem.',
  'The connection was loose the whole time.',
  'Let us try it again.',
  'It works! I cannot believe it.',
  'Thank you for your help.',
  'How long will the battery last?',
  'About six hours under normal conditions.',
  'You can change the brightness in the settings.',
  'The next train leaves at half past seven.',
  'We need to leave now if we want to catch it.',
  'Wait, I forgot my keys.',
  'They are on the table next to the window.',
  'Would you like some tea before we go?',
  'No, thanks. I have already had two cups.',
  'All right, see you tomorrow.',
  'Take care and have a safe journey.',
  'Good night.',
];

Future<void> main(List<String> args) async {
  if (args.length != 3) throw ArgumentError('worker, weights, report required');
  final results = <Map<String, Object?>>[];
  for (final entry in {
    'hy-mt2-1.8b-q4': 'Hy-MT2-1.8B-Q4_K_M.gguf',
    'qwen3-4b-q4': 'Qwen3-4B-Q4_K_M.gguf',
  }.entries) {
    final worker = await ProcessTranslationInference.load(
      executable: p.absolute(args[0]),
      modelPath: p.absolute(args[1], entry.key, entry.value),
      threads: 6,
    );
    try {
      // Warm the native backend before recording either format.
      await worker.generate(
        'Translate into Chinese: Hello.',
        reusePromptPrefix: false,
      );
      for (final compact in [false, true, true, false]) {
        final watch = Stopwatch()..start();
        var tokens = 0, validRows = 0;
        final responses = <String>[];
        for (var at = 0; at < _texts.length; at += 8) {
          final rows = {for (var n = at; n < at + 8; n++) n: _texts[n]};
          final context = _texts
              .skip((at - 2).clamp(0, at))
              .take(at.clamp(0, 2))
              .join('\n');
          final english = entry.key.startsWith('qwen');
          final prompt = compact
              ? (english
                        ? 'Translate the subtitle after | in each line into Simplified Chinese. '
                              'Return one id|translation line per input. Keep each numeric ID. '
                              'No JSON, quotes, explanations or extra lines.\n'
                              '${context.isEmpty ? '' : 'Context (do not translate): ${jsonEncode(context)}\n'}'
                              'Subtitles:\n'
                        : '将每行竖线后的字幕翻译成简体中文。每行只输出 编号|译文，保留每个原编号。'
                              '不要JSON、引号、解释或多余的行。\n'
                              '${context.isEmpty ? '' : '背景（不要翻译）：${jsonEncode(context)}\n'}'
                              '字幕：\n') +
                    rows.entries.map((e) => '${e.key}|${e.value}').join('\n')
              : localTranslationBatchPrompt(
                  texts: rows,
                  target: english ? 'Simplified Chinese' : '简体中文',
                  english: english,
                  context: context,
                );
          final reply = await worker.generate(
            prompt,
            structured: true,
            reusePromptPrefix: false,
          );
          tokens += reply.generatedTokens;
          if (compact) {
            final ids = <int>{};
            for (final line in const LineSplitter().convert(reply.text)) {
              final match = RegExp(
                r'^\s*(\d+)\s*[|｜]\s*(.+)$',
              ).firstMatch(line);
              final id = match == null ? null : int.tryParse(match[1]!);
              if (id != null &&
                  rows.containsKey(id) &&
                  RegExp(r'[\u3400-\u9fff]').hasMatch(match![2]!)) {
                ids.add(id);
              }
            }
            validRows += ids.length;
          } else {
            validRows += parseLocalTranslationBatch(
              reply.text,
              rows.keys.toSet(),
            ).length;
          }
          responses.add(reply.text);
        }
        final record = {
          'model': entry.key,
          'compact': compact,
          'elapsedMs': watch.elapsedMilliseconds,
          'generatedTokens': tokens,
          'validRows': validRows,
          'responses': responses,
        };
        results.add(record);
        await File(
          args[2],
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(results));
        stdout.writeln(
          '${entry.key}: compact=$compact, ${watch.elapsedMilliseconds} ms, $tokens tokens, $validRows rows',
        );
      }
    } finally {
      await worker.dispose();
    }
  }
}
