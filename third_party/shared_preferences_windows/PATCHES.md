# Local Windows persistence fix

Based on Flutter `shared_preferences_windows` 2.4.1 (see LICENSE).

The upstream Windows implementation JSON-encodes and synchronously rewrites the
entire preference file on the UI isolate for every key. A multi-setting trial
can therefore freeze a window when unrelated history/task preferences are large.

- Production JSON decoding, encoding, UTF-8 conversion and file I/O run in a
  worker isolate. The existing file path and preference format are unchanged.
- Local writes flush a temporary file and replace the destination only after
  completion. Failed writes leave the previous file and committed cache intact.
- The legacy backend serializes mutations, including clear, and exposes
  `setValues` for one atomic batch. Concurrent unrelated saves join the same
  mutation queue and cannot be lost to a stale batch snapshot.
- Injected non-local test file systems still use their own I/O, with JSON work
  in an isolate. The async backend shares the background file writer.

The app's trial uses the existing standard `flutter.` prefix for its batch,
reloads the public SharedPreferences cache, and verifies every scoped key.
Existing trial journal keys and backups remain readable.
