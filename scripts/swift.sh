#!/bin/zsh
set -euo pipefail
LMP_PROJECT="${0:A:h:h}"
LMP_DEFAULT_WORK="$LMP_PROJECT/.build-local"
if [[ -f "$LMP_PROJECT/.build-work-directory" ]]; then
  IFS= read -r LMP_DEFAULT_WORK < "$LMP_PROJECT/.build-work-directory"
fi
LMP_WORK="${LMP_WORK_DIR:-$LMP_DEFAULT_WORK}"
if [[ -z "${LMP_WORK_DIR:-}" && -f "$LMP_PROJECT/.build-volume-image" ]]; then
  IFS= read -r LMP_BUILD_IMAGE < "$LMP_PROJECT/.build-volume-image"
  if [[ ! -f "${LMP_WORK:h}/.negiplayer-build-volume" ]]; then
    hdiutil attach -nobrowse "$LMP_BUILD_IMAGE" >/dev/null
  fi
fi
mkdir -p "$LMP_WORK"
mkdir -p "$LMP_WORK/tmp"
export TMPDIR="$LMP_WORK/tmp"
export COPYFILE_DISABLE=1
export CLANG_MODULE_CACHE_PATH="$LMP_WORK/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$LMP_WORK/swift-module-cache"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-27.1-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-27.1-beta.app/Contents/Developer
fi
LMP_ACTION="${1:-build}"
if [[ $# -gt 0 ]]; then shift; fi
cd "$LMP_PROJECT"
exec xcrun swift "$LMP_ACTION" --disable-sandbox --cache-path "$LMP_WORK/swift-cache" --config-path "$LMP_WORK/swift-config" --security-path "$LMP_WORK/swift-security" --scratch-path "$LMP_WORK/negi-build" "$@"
