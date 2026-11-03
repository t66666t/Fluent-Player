#!/bin/bash
set -euo pipefail
root="$(cd "${SRCROOT}/.." && pwd)"
destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/asr"
source_dir="${root}/native/asr/prebuilt/macos-universal2"
if [[ ! -f "${source_dir}/asr_worker" ]]; then
  arch="${NATIVE_ARCH_ACTUAL:-arm64}"
  [[ "${arch}" == "x86_64" ]] && arch=x64
  source_dir="${root}/native/asr/prebuilt/macos-${arch}"
fi
if [[ ! -f "${source_dir}/asr_worker" ]]; then
  # Only our own stale entry point is removed. CPU ASR remains in the player.
  rm -f "${destination}/asr_worker"
  echo "ASR CoreML helper is not staged; keeping CPU transcription."
  exit 0
fi
if ! command -v python3 >/dev/null || ! python3 "${root}/tool/verify_asr_artifact.py" "${source_dir}" --platform macos; then
  rm -f "${destination}/asr_worker"
  echo "ASR helper is stale or invalid; keeping CPU transcription."
  exit 0
fi
for arch in ${ARCHS:-${NATIVE_ARCH_ACTUAL:-arm64}}; do
  if ! /usr/bin/lipo -verify_arch "${arch}" "${source_dir}/asr_worker"; then
    rm -f "${destination}/asr_worker"
    echo "ASR helper has no ${arch} slice; keeping CPU transcription."
    exit 0
  fi
done
mkdir -p "${destination}"
/usr/bin/rsync -a "${source_dir}/" "${destination}/"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -z "${identity}" ]] && identity=-
for library in "${destination}"/*.dylib; do
  [[ -f "${library}" ]] || continue
  /usr/bin/codesign --force --options runtime --sign "${identity}" "${library}"
done
/usr/bin/codesign --force --options runtime --sign "${identity}" \
  --entitlements "${root}/native/asr/helper.entitlements" "${destination}/asr_worker"
