#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_temp="$(mktemp -d)"
task_pids=()
cleanup() { for pid in "${task_pids[@]}"; do kill "$pid" 2>/dev/null || true; done; rm -rf "$task_temp"; }
trap cleanup EXIT
cd "$task_root"
mkdir -p ci-artifacts/interop
swift build --disable-sandbox --product LANConformanceHost
swift_bin="$(swift build --disable-sandbox --show-bin-path)"
dotnet build cross/NegiPlayer.Conformance -c Release
dotnet cross/NegiPlayer.Conformance/bin/Release/net10.0/NegiPlayer.Conformance.dll --serve --ready "$task_temp/csharp.json" --seconds 180 > "$task_temp/csharp.log" 2>&1 &
task_pids+=("$!")
for i in {1..100}; do test -f "$task_temp/csharp.json" && break; sleep 0.1; done
"$swift_bin/LANConformanceHost" --peer "$task_temp/csharp.json" --report ci-artifacts/interop/swift-client-csharp-host.json
"$swift_bin/LANConformanceHost" --ready "$task_temp/swift.json" --seconds 180 > "$task_temp/swift.log" 2>&1 &
task_pids+=("$!")
for i in {1..100}; do test -f "$task_temp/swift.json" && break; sleep 0.1; done
dotnet cross/NegiPlayer.Conformance/bin/Release/net10.0/NegiPlayer.Conformance.dll --peer "$task_temp/swift.json" --report ci-artifacts/interop/csharp-client-swift-host.json
echo 'PASS: both Swift/C# LAN directions; source fixtures only, no audio hardware playback.'
