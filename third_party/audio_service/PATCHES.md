# Local patch to audio_service 0.18.19

The complete upstream 0.18.19 package and its LICENSE are retained. There is no
version upgrade and no Android, Dart plugin, web or macOS-specific file change.
The shared Darwin implementation retains its default visible behavior unless
Fluent Player explicitly uses the new method below. macOS does not use it.

`darwin/audio_service/Sources/audio_service/AudioServicePlugin.m` adds
`setNowPlayingVisible` on the existing `com.ryanheise.audio_service.handler.methods`
channel, with the strictly typed argument `{visible: bool}` and boolean success.

- The initial process policy is visible. Engine registration and stopService do
  not reset a policy already selected by the application.
- Hiding clears MPNowPlayingInfoCenter and suppresses later metadata, artwork,
  position, rate and play/pause writes at their sole publication point. The
  internal truthful playback/metadata cache, audio session and remote controls
  are retained.
- Showing allows the next real setState/setMediaItem to republish, including
  unchanged fields. Restoration waits for non-idle state and metadata; the show
  method itself does not publish an old cached item.
- Invalid arguments return a FlutterError. Unknown methods now return
  FlutterMethodNotImplemented instead of leaving a result pending.

Fluent Player's SystemMediaNotificationGate selects this policy for iOS before
hidden publications. Full suppression also keeps the existing AppDelegate remote
command disabling behavior. Android's notification gate is unchanged.

Upstream file SHA-256 receipts are in the release audit artifacts. Dart channel
regressions run on Windows; Apple compilation and actual lock-screen/headphone
validation must be reported separately and are not implied by those tests.
