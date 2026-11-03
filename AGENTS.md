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


## Independent community edition

This is a standalone GPL community project, not the proprietary edition.
- Preserve local playback, library, subtitles, models and learning workflows.
- Do not reintroduce website media downloading, yt-dlp/Python downloader runtimes,
  Douyin extraction, media sniffing, AES-key extraction or online media export.
- Disabled compatibility APIs must fail closed; they are not extension points.
- Model/resource downloads and normal streaming buffers are outside this restriction.
- Do not reference an absolute path, symlink or hardlink to the private project.
- Keep application identity and data roots separate; never adopt full-edition data.
- Never add build caches, weights, signing keys, downloader executables or user data.
- Run python tool/verify_community_project.py and relevant Flutter checks.
- Do not publish or push automatically.
- External contributions to this GPL project must not be copied automatically
  into a proprietary project; review their license/permission separately.
