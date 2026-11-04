#!/bin/bash
set -euo pipefail
root="$(cd "${SRCROOT}/.." && pwd)"
arch="${NATIVE_ARCH_ACTUAL:-arm64}"
[[ "${arch}" == "x86_64" ]] && arch=x64
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -z "${identity}" ]] && identity=-
for component in cohere_asr parakeet_ja; do
  source_dir="${root}/native/${component}/prebuilt/macos-${arch}"
  destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/${component}"
  if [[ ! -f "${source_dir}/manifest.json" ]]; then
    rm -f "${destination}/${component}_worker"
    echo "${component} is not built for this Mac; existing models retained."
    continue
  fi
  verifier="verify_${component}_artifact.py"
  [[ "${component}" == "cohere_asr" ]] && verifier=verify_cohere_artifact.py
  python3 "${root}/tool/${verifier}" "${source_dir}" --platform macos --arch "${arch}"
  for slice in ${ARCHS:-${NATIVE_ARCH_ACTUAL:-arm64}}; do
    /usr/bin/lipo -verify_arch "${slice}" "${source_dir}/${component}_worker"
  done
  mkdir -p "${destination}"
  cp -R "${source_dir}/." "${destination}/"
  for library in "${destination}"/*.dylib; do
    [[ -f "${library}" ]] || continue
    /usr/bin/codesign --force --options runtime --sign "${identity}" "${library}"
  done
  /usr/bin/codesign --force --options runtime --sign "${identity}" \
    --entitlements "${root}/native/asr/helper.entitlements" "${destination}/${component}_worker"
done
