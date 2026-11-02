#!/bin/bash
set -euo pipefail

# Compare full application extraction without replacing the production acceptance job.
codeql_cli="${1:?Pass the verified stock CodeQL executable}"
candidate_pack="${2:?Pass the complete patched extractor pack}"
application_output="${3:?Pass a new absolute output directory}"
test "$(uname -m)" = x86_64
[[ "$(sw_vers --productVersion)" == 26.* ]]
[[ "$(xcodebuild -version)" == Xcode\ 26.4.1$'\n'* ]]
test "$(xcrun --sdk macosx --show-sdk-version)" = 26.4
test -n "${EXTERNAL_TOOLCHAINS_DIR:?Resolve the external Metal toolchain first}"
test -n "${METAL_TOOLCHAIN_IDENTIFIER:?Resolve the Metal toolchain identifier first}"
test "${CODEQL_EXTRACTOR_SWIFT_LOG_LEVELS:?Set bounded extractor logging}" = '*:info,out:binary:no_logs,out:text:info,out:console:warning'
[[ "$application_output" == /* ]]
mkdir "$application_output"
mkdir "$application_output/summary" "$application_output/logs"
candidate_pack="$(cd "$candidate_pack" && pwd -P)"
"$codeql_cli" version --format=json > "$application_output/summary/codeql-version.json"
jq -e '.version == "2.27.3"' "$application_output/summary/codeql-version.json"
stock_pack="$("$codeql_cli" resolve extractor --language=swift --format=text)"
test -x "$stock_pack/tools/osx64/extractor.real"
shasum -a 256 "$codeql_cli" "$stock_pack/tools/osx64/extractor.real" > "$application_output/summary/stock-before.sha256"
selected_pack="$("$codeql_cli" resolve extractor --language=swift --search-path="$candidate_pack" --format=text)"
test "$(cd "$selected_pack" && pwd -P)" = "$candidate_pack"
printf '%s\n' "$selected_pack" > "$application_output/summary/selected-extractor.txt"
git rev-parse HEAD > "$application_output/summary/checkout-revision.txt"
git ls-files -- 'ManPageCatalog/*.swift' | LC_ALL=C sort > "$application_output/summary/expected-sources.txt"
test -s "$application_output/summary/expected-sources.txt"

# These are the production build settings, including real shader compilation.
printf -v compile_command '%q ' xcodebuild build \
  -project ManPageCatalog.xcodeproj -scheme ManPageCatalog \
  -configuration Debug -destination 'platform=macOS,arch=x86_64' \
  -derivedDataPath "$application_output/derived-data" \
  ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  SWIFT_COMPILATION_MODE=wholemodule COMPILATION_CACHE_ENABLE_CACHING=NO \
  SWIFT_ENABLE_COMPILE_CACHE=NO SWIFT_USE_INTEGRATED_DRIVER=NO \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  "TOOLCHAINS=$METAL_TOOLCHAIN_IDENTIFIER com.apple.dt.toolchain.XcodeDefault"
printf '%s\n' "$compile_command" > "$application_output/summary/build-command.txt"
"$codeql_cli" database create "$application_output/db" --language=swift \
  --search-path="$candidate_pack" --source-root="$PWD" --command="$compile_command" \
  --threads=2 --ram=4096 --verbosity=progress+++ > "$application_output/logs/database-create.log" 2>&1
grep -q 'CompileMetalFile ' "$application_output/logs/database-create.log"
grep -q 'MetalLink ' "$application_output/logs/database-create.log"
test -s "$application_output/derived-data/Build/Products/Debug/SwiftTerm_SwiftTerm.bundle/Contents/Resources/default.metallib"
"$codeql_cli" database analyze "$application_output/db" \
  codeql/swift-queries:codeql-suites/swift-code-scanning.qls \
  --format=sarif-latest --output="$application_output/summary/swift.sarif" \
  --threads=2 --ram=4096 > "$application_output/logs/database-analyze.log" 2>&1

# Retain the production gate's strict schema and all-level error policy.
sarif_file="$application_output/summary/swift.sarif"
test -s "$sarif_file"
error_count="$(jq -er '
  if type != "object" or (.runs | type) != "array" or (.runs | length) == 0 then
    error("Invalid Swift SARIF runs")
  elif any(.runs[]; type != "object" or (.invocations | type) != "array" or (.invocations | length) == 0) then
    error("Invalid Swift SARIF invocations")
  elif any(.runs[].invocations[]; type != "object" or (.toolExecutionNotifications | type) != "array") then
    error("Invalid Swift SARIF notifications")
  elif any(.runs[].invocations[].toolExecutionNotifications[]; type != "object" or (.descriptor | type) != "object" or (.descriptor.id | type) != "string") then
    error("Invalid Swift SARIF notification descriptor")
  else
    [.runs[].invocations[].toolExecutionNotifications[] | select(.descriptor.id == "swift/diagnostics/extraction-errors")] | length
  end
' "$sarif_file")"
jq '[.runs[].invocations[].toolExecutionNotifications[] | select(.descriptor.id == "swift/diagnostics/extraction-errors")]' \
  "$sarif_file" > "$application_output/summary/extraction-errors.json"
if [[ "$error_count" != 0 ]]; then
  printf 'Candidate application extraction reported %s compiler diagnostics; no acceptance or upload is permitted.\n' "$error_count" >&2
  exit 1
fi
jq -er '[.runs[].invocations[].toolExecutionNotifications[] |
  select(.descriptor.id == "swift/diagnostics/successfully-extracted-files") |
  .locations[].physicalLocation.artifactLocation.uri |
  select(startswith("ManPageCatalog/"))] | unique | .[]' \
  "$sarif_file" | LC_ALL=C sort > "$application_output/summary/extracted-sources.txt"
cmp "$application_output/summary/expected-sources.txt" "$application_output/summary/extracted-sources.txt"
shasum -a 256 "$codeql_cli" "$stock_pack/tools/osx64/extractor.real" > "$application_output/summary/stock-after.sha256"
cmp "$application_output/summary/stock-before.sha256" "$application_output/summary/stock-after.sha256"
printf 'Complete application extraction passed: zero compiler diagnostics, every application Swift source extracted, real Metal compilation and linking, unchanged stock CLI/extractor.\n' \
  | tee "$application_output/summary/acceptance.txt"
