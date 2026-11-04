# Linux playback notes (soft video / silent host)

## Blue / solid-color video mitigation

On Linux the media_kit `VideoController` is created with:

- `enableHardwareAcceleration: false` (always)
- `hwdec: no` (always via `decoderOptionFor`, even if the settings toggle prefers HW)

Helpers (unit-tested):

- `NativeVideoPlayerMediaKit.shouldEnableHardwareVideoOutput` → `false` on Linux
- `NativeVideoPlayerMediaKit.linuxHasDriDevices` (optional `/dev/dri` probe; Linux already forces software)

Root cause context: hosts without working CUDA (`Cannot load libcuda.so.1`) plus
media_kit HW rendering on Impeller OpenGLES often show a solid/blue frame while
`PlaybackState.playing`. System `mpv` with software VO works; this change mirrors
that path inside the app.

## Startup and renderer checks

The GTK runner computes an initial size from the monitor work area before
mapping the window. Dart does not maximize or resize it again during startup.
Each native object has a relative RUNPATH, and both media_kit FFI and its video
plugin use the packaged mpv ABI. Do not substitute a different mpv SONAME.

For a VM or a broken hardware GL stack, try the provided launcher with Mesa
software rendering:

```bash
FLUENT_PLAYER_SOFTWARE_RENDERING=1 ./fluent-player.sh
```

This still requires working software OpenGL libraries. Passing Flutter tool
engine flags after the release executable only supplies Dart entrypoint
arguments and does not disable Impeller. The prepared CI tests cover X11/Xvfb;
Wayland, real graphics drivers and sound hardware still need target testing.
These source changes have not replaced the existing v1.0.0 Release assets.

## No sound card UX

`LinuxAudioDevice.hasLinuxAudioOutput` reads `/proc/asound/cards`. When empty /
missing / no usable card lines, `maybeShowNoAudioDeviceHint` shows a once-per-
session toast:

> 本机未检测到音频设备，画面可播但无声音（环境限制）

Hooked from player screen open and first `MediaPlaybackService.play`.

## Empty ASR messages

- No audio stream: `媒体无音轨，无法生成字幕`
- Empty ASR after success: `识别结果为空，无法生成字幕（可能为无声或静音）`
- Linux + no ALSA: `本机无音频设备，抽音频/识别可能失败`

## Residual risks

GPU-less VMs may still be limited (CPU decode cost, Impeller residual, missing
ALSA → silent audio by design after L3 degrade).

## Library covers / seek thumbnails

`video_thumbnail` has **no Linux implementation** (`MissingPluginException` on
`plugins.justsoft.xyz/video_thumbnail`). On Linux (and whenever
`FFmpegUtils.preferSystemFfmpeg`):

- Library covers (`LibraryService._generateThumbnail`) skip the plugin and use
  system `ffmpeg` via the Process path (`_generateThumbnailWindows`).
- Seek/scrub previews (`VideoPreviewService`) prefer system ffmpeg first
  (accurate + simple `-ss` extract) so logs are not flooded with MissingPlugin.
- OCR preview frames already used native thumbnail only on Android/iOS and
  system ffmpeg on desktop.

The package supplies `bin/ffmpeg` and `bin/ffprobe`; source runs can fall back to
system commands on `PATH`. Linux builds no longer load FFmpegKit's foreign
distribution binaries. Chrome/Chromium and a user-session keyring remain
external desktop services, as described in the package README.
