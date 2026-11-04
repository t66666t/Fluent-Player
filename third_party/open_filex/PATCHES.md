# Android activity reattachment

This is open_filex 4.7.0, vendored from the published package. The upstream
LICENSE, Dart API, native package names, file-opening intent behavior, and other
platform implementations are retained. No runtime or dependency version is
upgraded.

Upstream clears the `open_file` method channel when an activity detaches, but
only creates it when the plugin first attaches to an engine. A cached Flutter
engine can subsequently attach another activity without repeating engine
attachment. Configuration-change reattachment has the same gap. Dart then gets
`MissingPluginException` although the plugin still belongs to that engine.

`onAttachedToActivity` now calls the existing `setup()` only when its channel is
null. This also covers `onReattachedToActivityForConfigChanges`, which already
delegates to that callback. Initial attachment keeps its existing channel, and
the existing engine-detach cleanup still prevents a channel being revived on a
detached engine.

Run `python tool/test_open_filex_lifecycle.py --output build/open-filex-lifecycle`
from the application repository. It compiles the actual plugin sources and uses
the current SDK's real Flutter binding, method channel, and codec with a fake
host messenger/activity binding. It verifies initial attachment, repeated
configuration changes, a replacement activity on the same cached engine, and
engine replacement/detachment. It does not launch an Android intent or replace
the separate on-device export/open verification.
