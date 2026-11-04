#!/bin/sh
# A native-architecture helper; other architectures retain CPU compatibility.
set -eu
SOURCE_ROOT="$(CDPATH= cd -- "$PROJECT_DIR/.." && pwd)"
DART="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
case "$(uname -m)" in
  arm64) OCR_ARCH=arm64 ;;
  x86_64) OCR_ARCH=x64 ;;
  *) echo 'warning: OCR helper is unavailable on this host; using CPU compatibility mode'; exit 0 ;;
esac
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ocr/$OCR_ARCH"
mkdir -p "$DEST"
cd "$SOURCE_ROOT"
set --
if [ -n "${FLUENT_RELEASE_SYMBOL_DIR:-}" ]; then
  mkdir -p "$FLUENT_RELEASE_SYMBOL_DIR/ocr-worker"
  set -- "--save-debugging-info=$FLUENT_RELEASE_SYMBOL_DIR/ocr-worker/debug-info" \
    "--extra-gen-snapshot-options=--obfuscate,--strip,--dwarf-stack-traces,--save-obfuscation-map=$FLUENT_RELEASE_SYMBOL_DIR/ocr-worker/obfuscation-map.json"
fi
# Do not download a runtime or resolve a different dependency version.
if ! "$DART" compile exe "$@" tool/ocr_worker.dart -o "$DEST/ocr_worker"; then
  rm -f "$DEST/ocr_worker"
  echo 'warning: OCR helper could not be built; CPU compatibility mode remains available'
  exit 0
fi
RUNTIME=$(find "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH" "$PROJECT_DIR/Pods" \
  -name libonnxruntime.1.21.0.dylib -type f -print -quit 2>/dev/null || true)
if [ -z "$RUNTIME" ]; then
  rm -f "$DEST/ocr_worker"
  echo 'warning: The pinned OCR runtime is missing; CPU compatibility mode remains available'
  exit 0
fi
cp -f "$RUNTIME" "$DEST/libonnxruntime.1.21.0.dylib"
ACCEL="$SOURCE_ROOT/native/ocr/prebuilt/macos/$OCR_ARCH"
if [ -f "$ACCEL/manifest.json" ]; then
  python3 "$SOURCE_ROOT/tool/verify_ocr_artifact.py" "$ACCEL" --platform macos --arch "$OCR_ARCH"
  cp -f "$ACCEL/libfluent_ocr_accel.dylib" "$DEST/"
  cp -R "$ACCEL/ThirdPartyLicenses" "$DEST/"
  for NOTICE in "$ACCEL/"*-LICENSE; do
    [ ! -f "$NOTICE" ] || cp -f "$NOTICE" "$DEST/"
  done
fi
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
  IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  [ -n "$IDENTITY" ] || IDENTITY=-
  codesign --force --sign "$IDENTITY" "$DEST/libonnxruntime.1.21.0.dylib"
  if [ -f "$DEST/libfluent_ocr_accel.dylib" ]; then
    codesign --force --sign "$IDENTITY" "$DEST/libfluent_ocr_accel.dylib"
  fi
  codesign --force --options runtime --sign "$IDENTITY" "$DEST/ocr_worker"
fi
