# Local changes to desktop_drop 0.7.1

Upstream: https://github.com/MixinNetwork/flutter-plugins/tree/main/packages/desktop_drop

Copyright 2021 Mixin. Apache-2.0; the upstream LICENSE is retained.

2026-10-25:

- Receive Unicode text and browser URLs on Windows, macOS and Linux through
  the existing native drop receiver, separately from file events.
- Text drops always copy. Native coordinates and text/URL representations are
  delivered together; the application selects an editable field by hit testing.
- Linux negotiates text and URI targets with GTK, including same-application
  sources; local file URI drops retain the existing file import path.
- Keep Android/web and macOS file promises/security-scoped bookmarks unchanged.
