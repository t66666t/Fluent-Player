# Local Windows WebView fixes

Based on `flutter_inappwebview_windows` 0.6.0 (upstream LICENSE included), with
Dart interface compatibility for the pinned 1.4.0-beta.3 platform interface.
Only the runtime sources needed by this app are vendored.

The dependency download target is named `inappwebview_deps` to keep MSBuild's
generated tracking-log paths below MAX_PATH in nested release checkouts.
The upstream target name could build once but fail on the next incremental
build while reading its `.lastbuildstate` file (MSB3501).

The JavaScript bridge accepts null method-channel replies safely. Upstream
`CallJsHandlerCallback` converted `Success(nullptr)` into an engaged optional
containing a null pointer; its response callback then dereferenced that pointer.
This occurs when a retained page sends messages after its route removes a
JavaScript handler (also possible for built-in resource callbacks).

Windows crash dumps from 2026-10-15 show `0xc0000005`, reading address `0x40`,
at plugin RVA `0x6f493` in the unpatched Release binary. The instruction reads
the EncodableValue variant tag through a null response pointer (`R8 = 0`).

Both decoding and use of the response are guarded. Revisit these changes before
upgrading the upstream package. `integration_test/web_media_browser_retention_test.dart`
exercises bridge calls with missing handlers and page exit/re-entry.

Verification on Windows (2026-10-15): the integration fixture crashes the
unmodified 0.6.0 plugin with an access violation. With these two native changes,
it passes missing and built-in null replies, messages arriving after route
disposal, and six exit/re-entry cycles while preserving page state and history.
The browser route also uses the app's normal transition without snapshots;
native attachment waits for entrance completion and fades in when created.

The community build removes the old passive response observer, its media/header
classification and replay buffers. Network/Fetch CDP commands and events reject
before native dispatch; the old capability query returns false. Ordinary
JavaScript and document navigation remain available for in-app player controls.
Request interception is used only when explicitly enabled by a caller, including
the application's own YouTube host document; there is no passive media capture.
Its native filter now covers documents only and passes no request headers or
cookies into Dart. Media and other subresources never enter that callback.

The Dart compatibility changes accept both legacy argument-list and new typed
JavaScript callbacks. New callbacks receive the main-frame URL reported by
WebView2's message event, not an inferred current page. Print-job callback setup,
nullable enum values and web-message serialization follow the new interface.
The native shutdown, null-response and shortened dependency-target fixes remain.

When `useOnDownloadStart` is enabled, WebView2 `DownloadStarting` is cancelled
synchronously. Cancel/Handled flags are read back before a metadata-free
notification; Dart callbacks cannot resume a download. Missing guard support
blocks navigation. A weak lifetime token cancels late events without touching
the retired owner, and the handler is unregistered at destructor entry.
