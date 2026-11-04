import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player_app/features/model_center/model_background_tasks.dart';

import '../test/support/local_asr_smoke.dart';

/// Supply a maintainer-owned fixture server with the pinned, prepared weights.
/// Every download and checkpoint stays in disposable test storage.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const base = String.fromEnvironment('LOCAL_ASR_FIXTURE_BASE');
  testWidgets(
    'local transcription prepares missing models and recovers',
    (tester) async {
      // Regression for a real Android crash: a short download can finish before
      // onStartCommand, then immediately hand over to inference (or cancel).
      for (var i = 0; i < 8; i++) {
        ModelBackgroundTasks.downloads(1);
        await ModelBackgroundTasks.settleForTesting();
        ModelBackgroundTasks.downloads(0);
        ModelBackgroundTasks.inference(1);
        await ModelBackgroundTasks.settleForTesting();
        ModelBackgroundTasks.inference(-1);
        await ModelBackgroundTasks.settleForTesting();
      }
      await Future<void>.delayed(const Duration(seconds: 6));
      final report = await runLocalAsrSmoke(fixtureBase: base);
      report['foregroundHandoffs'] = 8;
      binding.reportData = report;
      // Also emitted for CI/device logs; contains only the public test sentence.
      // ignore: avoid_print
      print('LOCAL_ASR_SMOKE_RESULT ${jsonEncode(report)}');
    },
    skip: base.isEmpty,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
