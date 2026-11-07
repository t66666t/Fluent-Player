# Repository instructions

## Local model integration

For adding, replacing, upgrading or retiring OCR, transcription, enhancement or
local translation models, read [docs/model-integration.md](docs/model-integration.md)
before editing. It documents the actual catalog, adapters and validation entry.

- Preserve existing models, defaults, queued tasks, checkpoints, subtitle output
  and playback/resource behavior. Add a new model/version with a distinct ID;
  retain existing IDs, revisions and files unless retirement is explicitly in scope.
- Reuse the existing transcription and transcription-with-translation workflows.
  Register compatible exports centrally; implement and test a loader for a new
  architecture rather than inferring compatibility from ONNX/GGUF extensions.
- Do not add startup hashing, automatic downloads/benchmarks, runtime upgrades,
  new UI flows or broader queue/storage rewrites as incidental integration work.
- Run `python tool/verify_model_integration.py`. Where prepared weights and the
  platform runtime are available, also run the documented native checks. Report
  tested platforms and limitations accurately; compilation alone is not inference.
- Keep `test/fixtures/local_model_compatibility.json` as the pre-change baseline.
  Do not regenerate it just to make a regression pass. Intentional retirement or
  contract changes need targeted migrations and tests explaining the change.

The workspace may contain unrelated uncommitted changes. Preserve them and keep
edits limited to the requested work.

Do not change the application version or build number unless the user explicitly
requests it. Branding, icon changes, features and fixes do not authorize a bump.


## Independent community edition

This is a standalone GPL community project, not the proprietary edition.
- This edition focuses on local media and publisher-provided RSS/Atom podcasts. Preserve local playback, library,
  subtitles, batch media/subtitle import, notes, learning, models, composition,
  export, sharing, open-location and device synchronization.
- Do not add Bilibili/YouTube/website players, browser/WebView surfaces,
  cloud-drive browsing/playback, website clipboard recognition or media link bookmarks to the community UI.
- Do not reintroduce website media downloading, yt-dlp/Python downloader runtimes,
  Douyin extraction, media sniffing, AES-key extraction or non-podcast online media export.
- Allow podcast overview/channel/search/import/player/settings pages, RSS/Atom
  subscription updates, enclosure streaming/offline downloads, transcripts,
  learning, OPML/JSON/FluentPack backup and user-enabled background refresh.
  Podcast media must come from parsed publisher feeds; do not extract audio from
  webpage metadata, embedded JSON, paywalls or authenticated platform players.
- Block other remote media at playback, materialization, processing, queue and
  restored task entry points. Old compatibility APIs must fail closed, never act as
  extension points or redirect old media automatically to a browser.
- Keep old persisted identities/provenance and user files; locally downloaded
  files remain usable as ordinary local media. Do not delete user data merely
  because its original source integration has been retired.
- Model/font/resource downloads, explicitly configured authorized AI/translation/
  ASR services, update checks and user-enabled local device sync remain allowed.
  Ordinary help/reference links may open only following the user's explicit
  action; they must never become media acquisition or playback fallbacks.
- Allow the public ASR preset for local media when explicitly selected by the
  user. Preserve local-model defaults, selected profiles, saved task IDs and
  bounded query/retry behavior; document audio uploads and network behavior.
- Prioritize Android and Windows local playback; preserve iOS, macOS and Linux
  code paths. Compilation is not real-device playback or inference validation.
- Do not reference an absolute path, symlink or hardlink to the private project.
- Keep application identity and data roots separate; never adopt full-edition data.
- Never add build caches, weights, signing keys, downloader executables or user data.
- Run python tool/verify_community_project.py and relevant Flutter checks.
- Do not publish or push automatically.
- Before binary distribution, supply the actual FFmpeg/libmpv/native build's
  corresponding license, sources, patches and build configuration. A source-only
  boundary check is not evidence that binary distribution obligations are complete.
- External contributions to this GPL project must not be copied automatically
  into a proprietary project; review their license/permission separately.
