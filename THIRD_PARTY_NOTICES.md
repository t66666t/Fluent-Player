# Third-party components

Fluent Player's own application code is GPL-3.0-or-later. The separately
licensed application-owned helpers in native/asr/ and native/subtitle_archive/
use MIT; their third-party libraries retain the licenses listed below. This file does not
relicense the components below. Preserve this file, NOTICE, LICENSE and the
bundled license texts when distributing the application.

| Component | License and records | Original source |
| --- | --- | --- |
| FFmpegKit (Full GPL variant) | GPLv3, including its native codec libraries; assets/licenses/GPL-3.0.txt | https://github.com/sk3llo/ffmpeg_kit_flutter and https://github.com/sk3llo/ffmpeg-kit |
| Windows FFmpeg / FFprobe 8.0.1 | GPLv3; matching pair and publisher build configuration in assets/licenses/FFmpeg-Windows-build.txt | https://github.com/GyanD/codexffmpeg/releases/tag/8.0.1 and https://github.com/FFmpeg/FFmpeg/commit/894da5ca7d |
| media_kit / libmpv | Dart wrapper MIT; the native playback libraries retain their separate GPL/LGPL and dependency notices | https://github.com/media-kit/media-kit and https://github.com/media-kit/libmpv-win32-video-build/tree/2023-09-24 |
| audio_service 0.18.19 (Darwin Now Playing visibility patch) | MIT; original LICENSE and PATCHES.md in third_party/audio_service | https://github.com/ryanheise/audio_service |
| ONNX Runtime / DirectML | ONNX Runtime MIT; DirectML redistributable uses Microsoft Software License Terms, with separately MIT-licensed sample code; the prebuilt ASR notices are bundled in assets/licenses/ | https://github.com/microsoft/onnxruntime and https://github.com/microsoft/DirectML |
| sherpa-onnx | Apache-2.0; assets/licenses/sherpa-onnx-LICENSE.txt and ASR-Windows-ThirdPartyNotices.txt | https://github.com/k2-fsa/sherpa-onnx/tree/v1.12.12 |
| llama.cpp / llamadart | MIT; package license registry and native notices | https://github.com/ggml-org/llama.cpp and https://github.com/leehack/llamadart |
| Lyricify request adapters | Apache-2.0; third_party/lyricify/NOTICE records the adapted revision and local changes | https://github.com/WXRIW/Lyricify-Lyrics-Helper |
| flutter_markdown_plus | BSD; original LICENSE and PATCHES.md retained | https://github.com/foresightmobile/flutter_markdown_plus |
| flutter_inappwebview_windows (inactive historical source; not built) | Apache-2.0; original LICENSE and LOCAL_CHANGES.md retained | https://github.com/pichillilorenzo/flutter_inappwebview |
| desktop_drop 0.7.1 (local text/URL support) | Apache-2.0; original LICENSE and LOCAL_CHANGES.md retained | https://github.com/MixinNetwork/flutter-plugins/tree/main/packages/desktop_drop |
| Unicode-derived CJK tables | Unicode License v3; assets/licenses/Unicode-3.0.txt | https://www.unicode.org/Public/16.0.0/ucd/ |
| Optional UnRAR extraction tool | UnRAR license; assets/licenses/UnRAR-License.txt; original restrictions are retained in the tool source. This is a separate extraction process and is not GPL-licensed | https://www.rarlab.com/rar_add.htm |
| MiSans (historical releases only) | Xiaomi MiSans Font Intellectual Property License Agreement; assets/fonts/licenses/MiSans-License.txt and assets/licenses/MiSans-License.pdf | https://hyperos.mi.com/font/zh/ |
| Other bundled fonts | SIL OFL 1.1, with copyright and individual files in assets/fonts/licenses/ | Refer to subtitle-lab-fonts.json and the font library |
| Noto Color Emoji preview artwork | Apache-2.0; assets/fonts/licenses/NotoEmoji-Artwork-Apache-2.0.txt | Three resized official PNG glyphs from googlefonts/noto-emoji v2.051; assets/fonts/previews/NOTICE.txt |
| Language identifier data | MIT and ISO 639-3 terms in assets/language_id/ | Refer to the bundled license files |
| Downloadable OCR / ASR / translation models | Each model's own license, including Apache-2.0, FunASR Model License and CC-BY-4.0 | assets/models/catalog.json and ocr_catalog.json |

Flutter generates a license registry for resolved Dart packages. The application
also exposes the additional font/native notices under Settings → Open-source
licenses. Community runtime inputs are pinned in tool/release_assets.lock.json.

## Release sources

Distribute the complete matching application source and the corresponding
third-party sources/build inputs alongside every binary release. An arbitrary
upstream homepage is not a substitute for the corresponding version. The
release preparation tool records exact versions and checksums. The source
archive and release verification steps are documented in docs/releasing.md.

Optional model downloads are not part of the application binary. Mirrors and
ONNX conversions do not replace the original authors' model licenses. Users'
own media, subtitles and imported fonts are not granted any new rights by the
application license.

Qwen audio runtime: pinned CrispASR / ggml (MIT), nlohmann/json (MIT),
Lindera 6.2.0 (MIT), IPADIC (NAIST / ICOT), ko-dic (Apache-2.0).
Qwen3-ASR, Qwen3-ForcedAligner and ECAPA VoxLingua107 weights: Apache-2.0.
Complete additional notices: assets/licenses/Qwen-ASR-ThirdPartyNotices.txt.
Dictionary sources and artifact receipts: native/qwen_asr/runtime.lock.json.

Japanese ASR: NVIDIA Parakeet Japanese / cstr GGUF (CC BY 4.0),
Cohere Transcribe (Apache-2.0), CrispASR / transcribe.cpp / ggml / json (MIT).
FLEURS Japanese speech probe: Google and contributing authors (CC BY 4.0).
Attribution, changes and licenses: assets/licenses/Japanese-ASR-ThirdPartyNotices.txt.


## Community edition reference projects

- B-cut ASR adapter reference: SocialSisterYi/bcut-asr, MIT, Copyright (c) 2022 社会易姐QwQ.
  Source: https://github.com/SocialSisterYi/bcut-asr . Full notice: assets/licenses/bcut-asr-MIT.txt .
  This code license does not grant permission to use the remote ASR service.
- Historical Douyin implementation reference: jiji262/douyin-downloader, MIT, Copyright (c) 2026 jiji262.
  Source: https://github.com/jiji262/douyin-downloader . Full notice: assets/licenses/douyin-downloader-MIT.txt .
  The community edition removes the extraction implementation and retains only disabled compatibility/data definitions.

The community fork does not bundle yt-dlp, CPython or QuickJS-NG.
Bilibili/YouTube/website players, embedded browser engines, cloud-drive media
and podcast network features are retired from this edition. Inactive historical
adapter source retains its licenses; a source license does not authorize remote
service access or redistribution of third-party media.
