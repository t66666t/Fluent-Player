import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:video_player_app/features/model_center/model_catalog.dart';

/// Explicit native checks consume prepared weights; source checkouts contain
/// no bundled VAD. This helper never downloads files or opens application data.
String asrProbeVadPath({String? modelRoot}) {
  const configured = String.fromEnvironment('ASR_VAD_PATH');
  final candidates = configured.isNotEmpty
      ? [configured]
      : [
          if (modelRoot != null)
            p.join(modelRoot, asrVadModelId, asrVadFileName),
          p.join(
            '.artifacts/model-center/native',
            asrVadModelId,
            asrVadFileName,
          ),
          p.join('.artifacts/local-asr-repair', asrVadModelId, asrVadFileName),
        ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync() && file.lengthSync() == 643854) {
      return p.absolute(path);
    }
  }
  throw StateError(
    'Prepared VAD missing. Run python tool/download_model_smoke_assets.py '
    '--ids silero-vad-16k, or supply --dart-define=ASR_VAD_PATH=<prepared file>.',
  );
}
