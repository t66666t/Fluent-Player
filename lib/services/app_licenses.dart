import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Adds bundled native/font notices to Flutter's package license registry.
void registerAppLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final entry in const <String, String>{
      'Fluent Player (GPL-3.0-or-later)': 'assets/licenses/GPL-3.0.txt',
      'Fluent Player and third-party notices': 'NOTICE',
      'B-cut ASR reference (MIT)': 'assets/licenses/bcut-asr-MIT.txt',
      'Historical Douyin reference (MIT)':
          'assets/licenses/douyin-downloader-MIT.txt',
      'Unicode CJK tables': 'assets/licenses/Unicode-3.0.txt',
      'Lyricify adapters': 'assets/licenses/Lyricify-NOTICE.txt',
      'Apache-2.0 components': 'assets/licenses/Apache-2.0.txt',
      'sherpa-onnx': 'assets/licenses/sherpa-onnx-LICENSE.txt',
      'ASR native dependencies':
          'assets/licenses/ASR-Windows-ThirdPartyNotices.txt',
      'Optional UnRAR tool': 'assets/licenses/UnRAR-License.txt',
      'ASR helper': 'assets/licenses/ASR-Helper-MIT.txt',
      'Qwen audio runtime, Lindera and dictionaries':
          'assets/licenses/Qwen-ASR-ThirdPartyNotices.txt',
      'Japanese ASR models, runtimes and speech probe':
          'assets/licenses/Japanese-ASR-ThirdPartyNotices.txt',
      'Creative Commons Attribution 4.0': 'assets/licenses/CC-BY-4.0.txt',
      'Subtitle extraction helper':
          'assets/licenses/SubtitleArchiveHelper-MIT.txt',
      'FFmpegKit wrapper (LGPL)': 'assets/licenses/LGPL-3.0.txt',
      'libmpv': 'assets/licenses/mpv-Copyright.txt',
      'GPL-2.0 components': 'assets/licenses/GPL-2.0.txt',
      'LGPL-2.1 components': 'assets/licenses/LGPL-2.1.txt',
      'ONNX Runtime': 'assets/licenses/ONNX-Runtime-MIT.txt',
      'llamadart': 'assets/licenses/llamadart-MIT.txt',
      'Noto Sans CJK': 'assets/fonts/licenses/NotoSans-OFL.txt',
      'Inter': 'assets/fonts/licenses/Inter-OFL.txt',
      'Roboto Condensed': 'assets/fonts/licenses/RobotoCondensed-OFL.txt',
      'Brawler': 'assets/fonts/licenses/Brawler-OFL.txt',
      'Comic Relief': 'assets/fonts/licenses/ComicRelief-OFL.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        entry.key,
      ], await rootBundle.loadString(entry.value));
    }
  });
}
