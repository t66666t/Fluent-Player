# Local Windows WebView fixes

Based on `flutter_inappwebview_windows` 0.6.0 (upstream LICENSE included).
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

Generic media discovery now observes `WebResourceResponseReceived` without
deferring requests or reading response bodies. The internal capability query
`Fluent.getNetworkObserverCapabilities` lets Dart use this passive path instead
of sending every image/script request through CDP. Request COM identity and URL
keep responses scoped to their originating page; duplicate range windows and
explicit transport segments are filtered before the bridge. Media MIME,
response filename, total size and exact request headers remain available.
Responses received before listener registration are buffered and replayed.

The Windows Dart controller installs its callback before native registration so
replayed responses cannot beat the callback map. Older plugin/runtime pairs
continue with the CDP fallback. Generic real-WebView fixtures are in
`integration_test/web_media_generic_capture_test.dart`; optional runtime
validation accepts an address externally and exports counts/timings only.
