#!/bin/sh
set -eu
SOURCE_ROOT="$(CDPATH= cd -- "$PROJECT_DIR/.." && pwd)"
DART="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
case "$(uname -m)" in
  arm64) WORKER_ARCH=arm64 ;;
  x86_64) WORKER_ARCH=x64 ;;
  *) echo 'warning: Translation helper unavailable on this architecture; CPU retained'; exit 0 ;;
esac
BUILD="$SOURCE_ROOT/.dart_tool/model-workers/translation/$WORKER_ARCH"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/translation/$WORKER_ARCH"
mkdir -p "$BUILD" "$DEST"
cd "$SOURCE_ROOT"
set --
if [ -n "${FLUENT_RELEASE_SYMBOL_DIR:-}" ]; then
  mkdir -p "$FLUENT_RELEASE_SYMBOL_DIR/translation-worker"
  set -- "--save-debugging-info=$FLUENT_RELEASE_SYMBOL_DIR/translation-worker/debug-info" \
    "--extra-gen-snapshot-options=--obfuscate,--strip,--dwarf-stack-traces,--save-obfuscation-map=$FLUENT_RELEASE_SYMBOL_DIR/translation-worker/obfuscation-map.json"
fi
if ! "$DART" compile exe "$@" tool/translation_worker.dart -o "$BUILD/translation_worker"; then
  rm -f "$DEST/translation_worker"
  echo 'warning: Translation helper could not be built; CPU retained'
  exit 0
fi
cp -f "$BUILD/translation_worker" "$DEST/translation_worker"
if [ -d "$BUILD/lib" ]; then
  cp -R "$BUILD/lib" "$DEST/"
  # The explicit private loader directory and Dart's relative native-assets
  # map both resolve the same pinned Apple runtime, with no player replacement.
  find "$BUILD/lib" -type f -name '*.dylib' -exec cp -f '{}' "$DEST/" \;
fi
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
  IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  [ -n "$IDENTITY" ] || IDENTITY=-
  find "$DEST" -type f -name '*.dylib' -exec codesign --force --sign "$IDENTITY" '{}' \;
  codesign --force --options runtime --sign "$IDENTITY" \
    --entitlements "$SOURCE_ROOT/native/asr/helper.entitlements" "$DEST/translation_worker"
fi
