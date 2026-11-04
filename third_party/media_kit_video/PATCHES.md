# Playback recovery patch

Base: the complete published `media_kit_video` **1.3.1** package, copied from
the existing Pub cache. Published archive SHA-256 recorded by the original
application lockfile:

`813858c3fe84eb46679eb698695f60665e2bfbef757766fac4d2e683f926e15a`

The upstream MIT license and copyright headers are retained. Android Java,
JNI/C++, platform build files, native libraries, codec defaults, hardware
decoding defaults, and the upstream package version are unchanged.

The application selects this copy through a path override. Modified upstream
files are limited to:

- `platform_video_controller.dart`: optional observable output state and rebind.
- `android_video_controller/real.dart`: serialize Surface binding, invalidate
  availability on cleanup, remove unconditional absolute zero seek, guard
  asynchronous creation/callbacks/disposal, configure native properties before
  creating the output.
- `video_controller.dart`: cancel pending post-frame creation so native player
  disposal does not wait for a Flutter frame that cannot run in the background.
- `native_video_controller/real.dart`: reject creation after player disposal,
  ignore late size callbacks and unblock a cancelled first-texture wait.

Added files:

- `video_output_state.dart`: current binding generation and availability.
- `android_video_controller/surface_lifecycle.dart`: binding operation ownership.

`available` acknowledges the current native binding. It is not proof of the
pixels currently displayed. Application readiness additionally checks native
track selection, dimensions, seek state, position and the binding generation;
the integration test checks actual rendered pixels.

A paused, loaded video is redrawn with `seek 0 relative+exact`, using its native
position when the command executes. Cleanup, playing audio/video and `vid=no`
do not request this redraw. The helper never calls play or writes pause.

Regression entries in the application:

- `test/android_surface_lifecycle_test.dart`
- `test/video_output_creation_cancellation_test.dart`
- `test/online_media_startup_test.dart`
- `integration_test/playback_recovery_native_test.dart`

See `docs/playback-recovery-validation.md` in the application for device evidence
and outstanding Android/overnight acceptance. Do not remove this override during
a package upgrade without comparing the Surface and cancellation behavior.
