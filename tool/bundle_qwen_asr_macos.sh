#!/bin/bash
set -euo pipefail
root="$(cd "${SRCROOT}/.." && pwd)"
destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/qwen_asr"
arch="${NATIVE_ARCH_ACTUAL:-arm64}"
[[ "${arch}" == "x86_64" ]] && arch=x64
source_dir="${root}/native/qwen_asr/prebuilt/macos-${arch}"
if [[ ! -f "${source_dir}/manifest.json" ]]; then
  rm -f "${destination}/qwen_asr_worker"
  echo "Qwen audio component has not been built for this Mac; existing ASR retained."
  exit 0
fi
python3 "${root}/tool/verify_qwen_artifact.py" "${source_dir}" --platform macos --arch "${arch}"
for slice in ${ARCHS:-${NATIVE_ARCH_ACTUAL:-arm64}}; do
  /usr/bin/lipo -verify_arch "${slice}" "${source_dir}/qwen_asr_worker"
done
python3 "${root}/tool/stage_qwen_asr.py" --platform macos --arch "${arch}" --destination "${destination}"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -z "${identity}" ]] && identity=-
for library in "${destination}"/*.dylib; do
  [[ -f "${library}" ]] || continue
  /usr/bin/codesign --force --options runtime --sign "${identity}" "${library}"
done
/usr/bin/codesign --force --options runtime --sign "${identity}" \
  --entitlements "${root}/native/asr/helper.entitlements" "${destination}/qwen_asr_worker"
