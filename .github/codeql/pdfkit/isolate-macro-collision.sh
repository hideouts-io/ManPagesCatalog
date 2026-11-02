#!/bin/bash
set -euo pipefail

# Compare real import-only compilation and extraction; these controls do not establish application acceptance.
codeql_cli="${1:?Pass the verified CodeQL executable}"
probe_case="${2:?Pass a macro-controls case directory}"
probe_output="${3:?Pass a new absolute output directory}"
candidate_revision="${4:?Pass the candidate source revision}"
probe_root="$(cd "$(dirname "$0")" && pwd)"
[[ "$probe_output" = /* ]]
[[ "$candidate_revision" =~ ^[0-9a-f]{40}$ ]]
test -f "$probe_case/Probe.h"
mkdir "$probe_output"
mkdir "$probe_output/src" "$probe_output/summary" "$probe_output/commands" "$probe_output/logs"
cp "$probe_case/Probe.h" "$probe_root/macro-controls/Probe.swift" \
  "$probe_root/macro-controls/module.modulemap" "$probe_output/src/"

# The workflow bounds this script; preserve each exact command, log and real exit status.
run_probe_command() {
  local probe_name="$1"
  local probe_status
  shift
  printf '%q ' "$@" > "$probe_output/commands/$probe_name.sh"
  printf '\n' >> "$probe_output/commands/$probe_name.sh"
  if "$@" > "$probe_output/logs/$probe_name.log" 2>&1; then
    probe_status=0
  else
    probe_status=$?
  fi
  jq -n --argjson status "$probe_status" '{exit_status:$status}' > "$probe_output/summary/$probe_name-exit.json"
  return "$probe_status"
}

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
"$codeql_cli" version --format=json > "$probe_output/summary/codeql-version.json"
jq -e '.version == "2.27.3"' "$probe_output/summary/codeql-version.json"
{
  sw_vers
  xcodebuild -version
  xcrun swiftc --version
  xcrun --sdk macosx --show-sdk-version
} > "$probe_output/summary/toolchain.txt"
jq -n --arg checkout "$(git rev-parse HEAD)" --arg candidate "$candidate_revision" \
  '{checkout_revision:$checkout, candidate_revision:$candidate}' > "$probe_output/summary/revisions.json"
(
  cd "$probe_output/src"
  shasum -a 256 Probe.swift Probe.h module.modulemap
) > "$probe_output/summary/source-sha256.txt"
common=(-target x86_64-apple-macos13.0 -sdk "$sdk_path" -swift-version 5 \
  -Xfrontend -enable-cross-import-overlays -I "$probe_output/src")
run_probe_command native-compile xcrun swiftc "${common[@]}" \
  -module-cache-path "$probe_output/native-module-cache" -emit-module \
  "$probe_output/src/Probe.swift" -module-name ImportProbe \
  -emit-module-path "$probe_output/native-ImportProbe.swiftmodule"
mkdir "$probe_output/native-symbolgraph"
run_probe_command native-symbolgraph xcrun swift-symbolgraph-extract \
  -target x86_64-apple-macos13.0 -sdk "$sdk_path" -swift-version 5 -I "$probe_output/src" \
  -module-cache-path "$probe_output/symbolgraph-module-cache" \
  -module-name NamespaceProbe -output-dir "$probe_output/native-symbolgraph"
# Symbol-graph enumeration can emit errors with exit zero; retain these separately from compile success.
symbolgraph_error_lines="$(awk '/ error:/ { count++ } END { print count + 0 }' "$probe_output/logs/native-symbolgraph.log")"
jq -n --argjson errors "$symbolgraph_error_lines" '{compiler_error_line_count:$errors}' \
  > "$probe_output/summary/native-symbolgraph-diagnostics.json"

compile_arguments=(xcrun swiftc "${common[@]}" \
  -module-cache-path "$probe_output/extraction-module-cache" -emit-module \
  "$probe_output/src/Probe.swift" -module-name ImportProbe \
  -emit-module-path "$probe_output/extracted-ImportProbe.swiftmodule")
printf -v compile_command '%q ' "${compile_arguments[@]}"
printf '%s\n' "$compile_command" > "$probe_output/commands/extracted-compile.sh"
run_probe_command database-create "$codeql_cli" database create "$probe_output/db" \
  --language=swift --source-root="$probe_output/src" --command="$compile_command" \
  --threads=2 --ram=4096 --verbosity=progress+++
run_probe_command database-analyze "$codeql_cli" database analyze "$probe_output/db" \
  codeql/swift-queries:codeql-suites/swift-code-scanning.qls \
  --format=sarif-latest --output="$probe_output/swift.sarif" --threads=2 --ram=4096 \
  --timeout=300 --verbosity=progress+++
jq -e '
  if type != "object" or (.runs | type) != "array" or (.runs | length) == 0
    or any(.runs[]; type != "object" or (.invocations | type) != "array" or (.invocations | length) == 0)
    or any(.runs[].invocations[]; type != "object" or (.toolExecutionNotifications | type) != "array")
    or any(.runs[].invocations[].toolExecutionNotifications[];
      type != "object" or (.descriptor | type) != "object" or (.descriptor.id | type) != "string") then
    error("Swift SARIF is missing extraction notification evidence")
  else [.runs[].invocations[].toolExecutionNotifications[] | select(.descriptor.id == "swift/diagnostics/extraction-errors")]
  end' \
  "$probe_output/swift.sarif" > "$probe_output/summary/extraction-errors.json"
jq -n --argjson diagnostics "$(jq 'length' "$probe_output/summary/extraction-errors.json")" \
  '{native_compile_exit:0, extraction_notification_count:$diagnostics, application_acceptance:false}' \
  > "$probe_output/summary/comparison.json"
printf 'Native compilation passed. Swift extraction notifications: %s. This fixture comparison does not establish clean application extraction.\n' \
  "$(jq -r '.extraction_notification_count' "$probe_output/summary/comparison.json")"
