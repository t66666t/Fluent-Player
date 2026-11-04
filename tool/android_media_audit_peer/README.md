# Isolated Android media-control peer

This is a test-only, debug-signed SDK APK, never part of Fluent Player's release.
It has no permission declarations, networking, audio player, foreground service,
global media-key/keyboard dispatch, clipboard, application-kill, installation or
data-cleaning code. Its separate text-input instrumentation performs only the
explicitly requested, narrowly guarded ACTION_SET_TEXT described below.
The builder uses a separate generated debug key and does not read production keys.

Build on the development computer:

```text
python tool/build_android_media_audit_peer.py
```

The builder compiles Java, runs offline policy checks, creates DEX/resources,
aligns/signs the APK and verifies identity, manifest and signature. It never
contacts a device. Root owns any later installation and device operation. Because
the APK is testOnly, any separately authorized adb install needs its test option.

Package: `com.fluentplayer.audit.controls`, minSdk 24, targetSdk 36.
The build receipt and APK are in
`build/android-release-audit-20261031/evidence/media-control-peer/`.

## Explicit media-button Activity

Component:
`com.fluentplayer.audit.controls/.AuditMediaButtonActivity`

Required string extra `command`: `play`, `pause`, `next`, `previous`, `play_pause`.
It sends one DOWN/UP `ACTION_MEDIA_BUTTON` + `EXTRA_KEY_EVENT` pair, with repeat
count zero, only to the hard-coded component:

`com.example.video_player_app.sidebar_profile/com.ryanheise.audioservice.MediaButtonReceiver`

Optional string extras `target`, `target_package` and `target_receiver` are only
negative-test assertions. If present they must exactly match the fixed component,
package and receiver respectively. Any different target or unsupported command is
rejected before sending. There is no raw key-code or arbitrary-target option.

For root's separately authorized explicit activity launch, the operation arguments
are `-n com.fluentplayer.audit.controls/.AuditMediaButtonActivity --es command pause`
(replace pause with one of the five permitted commands). No global media key is
sent. The Activity remains visible to keep the player backgrounded; it must not
automatically finish and make a failed background play look successful only after
the player returns to foreground. A Close button finishes only this peer Activity.
Repeated explicit launches while it is top send the next intent once. Recreation
does not replay a command.

Receipts report `broadcast-dispatched-unacknowledged`, not receiver success.
These are raw KeyEvent names, not explicit transport-method calls: audio_service
0.18.19 Android intentionally maps both KEYCODE_MEDIA_PLAY and
KEYCODE_MEDIA_PAUSE to its media-button toggle for hardware compatibility.
Therefore `play` and `pause` can both toggle the current state; this helper cannot
prove idempotent play/pause behavior. The product/vendor Android behavior is not
changed by this fixture. Runtime receipts include that semantic limitation.
This cannot substitute for physical headphones, Bluetooth AVRCP delivery and
deduplication, the system choosing the intended session, lock-screen reachability,
unplug/becomingNoisy, routing changes or actual audible playback. The peer becoming
foreground is itself a lifecycle change; root must capture target/FGS/focus state.

## Silent foreground audio-focus Activity

Component: `com.fluentplayer.audit.controls/.AuditFocusActivity`

String extra `mode`: `transient` (default, AUDIOFOCUS_GAIN_TRANSIENT) or `gain`
(AUDIOFOCUS_GAIN). Integer extra `hold_seconds`: 1–30, default 5.

Request arguments for root's separately authorized launch are, for example:
`-n com.fluentplayer.audit.controls/.AuditFocusActivity --es mode transient --ei hold_seconds 5`.

The peer waits for its actual window focus, requests focus with a main-thread
listener (AudioFocusRequest on API 26+, legacy API on 24/25), records the return
value, and abandons after the bounded hold before finishing itself. A denied
request is recorded and abandoned immediately. Stopping/destroying the Activity
early abandons and records an early-exit reason. Additional intents during a hold
are recorded and ignored, without extending it. The peer does not play sound,
reclaim lost focus, launch another app, hold a wake lock or start an FGS.

Focus requests participate in the system focus stack and cannot be addressed only
to one app. Root must first establish the intended isolated playing session. This
tests real focus callbacks and owned continuation, but does not emulate a phone
call, Bluetooth route, assistant audio, audible duck/fade, screen-off endurance or
OEM battery restrictions. Permanent GAIN and temporary GAIN_TRANSIENT have
different expected resume behavior and must not share one assertion.
When testing ordinary external permanent loss, first let the player's existing
1.2-second OEM self-focus startup grace expire (wait at least two seconds); record
events inside that grace as a separate scenario.

## Evidence

Each operation writes a bounded private JSON receipt under
`files/media-audit-peer/receipts/peer-<uuid>.json`, and emits snapshots with log tag
`FluentMediaAuditPeer`. Events have wall and monotonic elapsed timestamps. At most
128 known receipt files are retained; no external or target files are accessed.
The build records public certificate fingerprint, APK/source hashes, SDK identity,
tool commands and all limitations. No device test is claimed by a successful build.

## Immediate read-only UI snapshot

Instrumentation: `com.fluentplayer.audit.controls/.UiDumpInstrumentation`.
Its manifest targetPackage is fixed to the helper itself, never the production or
profile player. It calls UiAutomation.getRootInActiveWindow once and traverses
that snapshot immediately, without waitForIdle, actions, taps, input injection,
screen changes or Activity/app launch. Existing accessibility services are not
suppressed. The XML uses UIAutomator hierarchy/node attributes, including text,
content-desc, package, bounds and control states.

Root can use the separately authorized command suffix:

```text
shell am instrument -w -r com.fluentplayer.audit.controls/.UiDumpInstrumentation
shell run-as com.fluentplayer.audit.controls cat files/ui/latest.xml
```

The default output is helper-private `files/ui/latest.xml`. Optional `-e filename
Page1.xml` accepts only 1–64 ASCII letters/digits followed by `.xml`; paths,
separators, spaces, extra dots and other extensions are rejected. Writes also
verify canonical private-directory boundaries. The result reports status, path,
node count, truncation, size and elapsed time, rather than claiming a fresh dump
when the root is unavailable or the operation fails.

Traversal has a five-second/10,000-node/80-level budget, but an individual Android
framework Binder call cannot be preempted. It can capture a transient tree during
playback; no idle guarantee is claimed. `am instrument` can recreate this helper's
own process as part of framework instrumentation startup, so root must not run
the dump while the same helper is intentionally holding audio focus. It does not
target/restart either player package. A successful SDK build is not device proof.

## Explicit Unicode / URL text input (write action)

This is a separate opt-in write entry point:
`com.fluentplayer.audit.controls/.TextInputInstrumentation`.
UiDumpInstrumentation remains read-only and never delegates to this class.
Both instrumentations' manifest targetPackage remains the helper itself.

Root may explicitly invoke the suffix:

```text
shell am instrument -w -r -e text 'requested Unicode / URL text' com.fluentplayer.audit.controls/.TextInputInstrumentation
```

`-e text` is required and may contain Unicode, URLs and actual newlines; an empty
string explicitly clears the field. The UTF-8 limit is 65,536 bytes (64KiB), with
multibyte characters counted by their encoded size. Oversized/missing text is
rejected before any node action. There is no package override or selection option.

The active root package must exactly equal
`com.example.video_player_app.sidebar_profile`; production, system and other
packages are rejected. Two immediate complete scans must find the same **one**
editable `android.widget.EditText`. Zero/multiple matches, truncated scans, changed
targets, inactive windows, disabled/invisible fields or another node package cause
rejection. It then performs **one ACTION_SET_TEXT only**, without focus/selection,
taps, global keyboard events, clipboard, app launch, permissions or retry/fallback
actions. No waitForIdle is used. After an accepted action it keeps the automation
connection alive for a fixed 500ms propagation window before finishing, allowing
an asynchronously queued semantic action time to reach the application. It does
not retry or infer success from that delay.

The result and helper-private audit receipt record byte count/hash, target
identity, matching-node count and whether the accessibility provider accepted the
action. The accepted result is `action-accepted-not-verified`, explicitly reports
`appValueVerified=false`, and records the propagation hold. They do not log the
supplied raw text or claim that Flutter, the rendered field or the business
operation adopted it. Root must separately inspect the screenshot and actual
operation output; a semantics snapshot alone can precede application state.
As with the dump, am instrument may recreate the helper's own process; do not run
it during an intentional focus hold by the same helper.
# Expand the one known model-task notification

`ExpandModelNotificationInstrumentation` is a separate, explicit SystemUI write
entry point. Open the notification shade manually first. It searches only for
the fixed exact title `Fluent Player 模型中心`; it rejects missing/duplicate titles,
changing windows/geometry, grouped cards, incomplete structural scans, and rows
containing more than one title or notification-content container. It traverses
SystemUI metadata with strict node/depth/time limits and compares title-field
values in RAM against the fixed known title. Nonmatching title text is never
retained, logged or saved; body text and descriptions are not read. Its instrumentation
target remains this helper, never the player or SystemUI package.

The helper first uses `ACTION_EXPAND` if the validated notification row advertises
it. An advertised action returning false stops without a gesture. Otherwise it
injects exactly one two-finger downward drag, with both initial contacts inside
the fresh own-row bounds, maximum distance 360px (strictly below 500), and all
points inside the active SystemUI window. The movement can extend below the
original compact row. Partial injection attempts `ACTION_CANCEL` rather than
finishing as a tap; acceptance of this cancellation requires actual device
validation. Individual system Binder calls cannot be preempted by the helper's
deadline. It never opens the shade, retries, clicks `暂停任务`, invokes an app service,
or relaunches the app. An accepted action/injected gesture still needs visual
verification; it does not prove expansion or interruption.

Host-only SDK build (no device operation):

```text
python tool/build_android_media_audit_peer.py --sdk <ANDROID_SDK_PATH>
```

The root device operator can upgrade the existing debug-signed helper and run:

```text
adb -s <ANDROID_SERIAL> install -r -t build/android-release-audit-20261031/evidence/media-control-peer/fluent-media-audit-peer.apk
adb -s <ANDROID_SERIAL> shell am instrument -w -r -e inspect_only true com.fluentplayer.audit.controls/.ExpandModelNotificationInstrumentation
adb -s <ANDROID_SERIAL> shell am instrument -w -r com.fluentplayer.audit.controls/.ExpandModelNotificationInstrumentation
```

`inspect_only=true` returns row bounds, selection method, advertised action IDs
in its private receipt, and `advertisedExpand`; it performs no action/injection.
The normal invocation performs one attempt, records only the fixed known title,
own-row geometry, action IDs, planned coordinates and result, then exits. No
caller-supplied target/title/coordinates are accepted. The existing UI snapshot
and text-input entries retain their separate behavior. Do not invoke any of these
instrumentations while this same helper is deliberately holding audio focus.

Rejected attempts now return a fixed `stage` and `reasonCode`, plus
`numericMetadata` (capture number, refresh success flags, fixed-title match
counts, ancestor depth, own-card structural counts, visibility flags and capture
age). For example, `ROOT_REFRESH/ROOT_REFRESH_FAILED` distinguishes an unavailable
fresh accessibility root from `ROW_ANCESTORS/ROW_BOUNDARY_UNRECOGNIZED` or
`ROW_COUNTS/ROW_NOT_SINGLE_CARD`. These diagnostics do not relax the action policy
and do not include framework exception messages, notification text, arbitrary
resource names or saved notification text. `FRAMEWORK_EXCEPTION` preserves
only the stage and exception class, without its message.

HyperOS can return zero from `findAccessibilityNodeInfosByText` even while the
title exists in the accessibility tree. That query is now numeric diagnostics
only. Selection uses the shared `NotificationTitleSearch` traversal (10,000 nodes,
depth 80, 400ms maximum; the whole capture still must satisfy the existing 500ms
freshness guard). A truncated scan, unavailable child or title refresh failure
rejects the attempt. The same traversal is exercised by offline host tests for
exact/duplicate/substr matches, private-body nonreading, nonmatching-title
nonretention, node/depth/time cutoffs, missing nodes and exception cleanup.

