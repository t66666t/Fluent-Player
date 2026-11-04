# Local Windows lifetime patch

Based on the resolved `ffmpeg_kit_flutter_new` 4.6.2 package. Original licenses,
platform implementations and the existing native-library version are retained.
No generated binaries or build output are stored in this override.

The Windows plugin owns and reaps its execution threads. Its asynchronous Dart
methods still return immediately and publish the same completion events, but use
the synchronous native entry points on these owned threads instead of detaching
work inside the native DLL. During disposal it cancels outstanding work and
allows up to two seconds for
execution threads to finish. It stops and joins the native log consumer and
disconnects all UI callbacks. Normal jobs are joined before the library unloads.
An unresponsive job retains its module in a separate reaper that holds no plugin
or UI pointers; that reaper joins the actual threads before releasing the module.
It never unloads executing code or blocks window close indefinitely. This prevents
code or MinGW
thread state from being unloaded while a worker is still running.

The native unload regression is reproduced independently in the release-fix
evidence. Windows argument quoting has a separate native verification entry:
`tool/verify_windows_process_arguments.ps1`.


Native exit validation uses scripts/windows_exit_validation.dart with the existing
isolated startup fixture. test/native/ffmpeg_lifetime_fixture.cpp can be built by
tool/build_ffmpeg_lifetime_fixture.ps1 and substituted only in a separate test
runtime to exercise completion, cancellation and ignored-cancellation boundaries.
This fixture is not a codec/inference validation and must never be packaged.


