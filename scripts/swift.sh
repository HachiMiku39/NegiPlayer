#!/bin/zsh
set -euo pipefail
LMP_PROJECT="${0:A:h:h}"
LMP_WORK="${LMP_WORK_DIR:-${TMPDIR:-/private/tmp}/NegiPlayer-build}"
mkdir -p "$LMP_WORK"
export CLANG_MODULE_CACHE_PATH="$LMP_WORK/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$LMP_WORK/swift-module-cache"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-27.1-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-27.1-beta.app/Contents/Developer
fi
LMP_ACTION="${1:-build}"
if [[ $# -gt 0 ]]; then shift; fi
cd "$LMP_PROJECT"
exec xcrun swift "$LMP_ACTION" --disable-sandbox --cache-path "$LMP_WORK/swift-cache" --config-path "$LMP_WORK/swift-config" --security-path "$LMP_WORK/swift-security" --scratch-path "$LMP_WORK/negi-build" "$@"
