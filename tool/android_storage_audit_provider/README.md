# Android storage audit fixture

Test code only. The build script never installs an APK or reads production app
data/signing files. It generates its own debug key and local synthetic media.
This source directory and its APK must never become release assets.

Build from the repository root:

```powershell
python tool/build_android_storage_audit_provider.py
```

Default output:
`build/android-release-audit-20261031/evidence/provider/fluent-storage-audit-provider.apk`.
`provider-build-result.json` records its identity, source/fixture hashes and tool
commands. No Gradle/Flutter is used. `--sdk`, `--java-home`, `--build-tools`,
`--ffmpeg` and `--output` override local tool/output locations only.
To rebuild the receiver while preserving existing device fixture hashes, use
`--reuse-fixtures-from-apk PATH_TO_SAVED_AUDIT_APK`. This copies and checks the
four fixture assets and their metadata byte for byte, skips FFmpeg generation,
and requires the same output directory's existing fixture debug key. Its signer
must match the saved APK. Keep the saved APK and receipt before rebuilding.

Package and authority: `com.fluentplayer.audit.documents`.
Classes: `.FixtureDocumentsProvider`, `.AuditShareActivity`, `.AuditReceiveActivity`.
The provider requires the system's `MANAGE_DOCUMENTS` permission and allows
temporary read URI grants. It has no writable documents or network permission.
On an authorized test install, its root appears as **Fluent audit fixtures** in
the system's Open Document picker. That path exercises the app's real SAF result
handling; a Share intent is a separate entry path and cannot replace a SAF test.

| Document ID | Display/behavior |
| --- | --- |
| `video` | 12-second generated H.264/AAC MP4 |
| `audio` | 60-second generated MP3 |
| `subtitles` | UTF-8 SRT |
| `duplicate-a`, `duplicate-b` | Both named `同名视频.mp4`, different content/hashes |
| `denied` | Metadata is readable; open deliberately throws SecurityException |
| `truncated` | Video stream declares 4096 more bytes than it returns |
| `error` | Reliable pipe reports an error after 32 bytes |
| `slow` | Complete video via a reliable pipe in about seven seconds |

Every `_data` query is rejected. Standard document name, MIME and size metadata
remain available. All content is synthetic, listed in `fixture-metadata.json`.
Provider document URIs have the form
`content://com.fluentplayer.audit.documents/document/video`.

After root separately authorizes installing/testing on the chosen device, these
are the explicit share entry examples (not run by the build script):

```powershell
adb -s SERIAL shell am start -n com.fluentplayer.audit.documents/.AuditShareActivity --es mode send --es docs video
adb -s SERIAL shell am start -n com.fluentplayer.audit.documents/.AuditShareActivity --es mode multiple --es docs duplicate-a,duplicate-b
adb -s SERIAL shell am start -n com.fluentplayer.audit.documents/.AuditShareActivity --es mode view --es docs audio
```

The target component is compiled in:
`com.example.video_player_app.sidebar_profile/com.example.video_player_app.MainActivity`.
There is no target-package override. All outgoing URIs are fixture-owned,
whitelisted documents, carried in ClipData with a read grant. The activity never
targets `com.example.video_player_app`. `files/share-last.json` records dispatch
or failure; dispatch alone is not proof that the target consumed the content.

For outbound app-file validation, choose **Fluent Storage Audit** from the
isolated app's Share sheet or **Open With** dialog. The receiver accepts
SEND/SEND_MULTIPLE/VIEW and content
URIs from the exact isolated package's provider namespace or this fixture's
authority. VIEW reads Intent.data and deduplicates ClipData; its manifest filter
is restricted to the two known isolated app FileProvider authorities and this
fixture's authority. It rejects file URIs and the original production application's
authority. It reads and hashes every byte before finishing, publishing files in
its own `files/received/<receipt-id>/` and JSON in `files/receipts/`. Read
`files/receive-last.json` with the fixture's debug `run-as` access to find the
latest receipt. Success requires `status=complete`, each `complete=true`, size
and SHA matching the expected export. Failed batches discard their copied files
and retain an error receipt. Each batch is limited to 64 MiB and all retained
received files to 256 MiB; operations are serialized. At 128 receipts, further
attempts produce a quota error rather than delete prior evidence. Fixture media,
APK and retained data stay comfortably below the 512 MiB device budget.

Picker cancellation creates no provider-side copy. To simulate access loss use
`denied`; `error` and `truncated` exercise cleanup after a stream has begun.
External URI grant/revocation and DocumentsUI presentation still need actual
device validation. A successful SDK compilation is not that validation.
