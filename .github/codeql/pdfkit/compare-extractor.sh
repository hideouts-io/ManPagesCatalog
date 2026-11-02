#!/bin/bash
set -euo pipefail

# Test a matching-compiler extractor with current analysis and query data.
# Both official bundles have the same Swift schema; no missing-type upgrade is allowed.
extractor_cli="${1:?Pass the verified CodeQL 2.25.5 executable}"
analysis_cli="${2:?Pass the verified CodeQL 2.27.3 executable}"
probe_output="${3:?Pass a new absolute output directory}"
probe_root="$(cd "$(dirname "$0")" && pwd)"
mkdir "$probe_output" "$probe_output/summary" "$probe_output/src" "$probe_output/fixtures"
"$extractor_cli" version --format=json > "$probe_output/summary/extractor-version.json"
"$analysis_cli" version --format=json > "$probe_output/summary/analysis-version.json"
jq -e '.version == "2.25.5"' "$probe_output/summary/extractor-version.json"
jq -e '.version == "2.27.3"' "$probe_output/summary/analysis-version.json"
old_schema="$(dirname "$extractor_cli")/swift/swift.dbscheme"
new_schema="$(dirname "$analysis_cli")/swift/swift.dbscheme"
cmp "$old_schema" "$new_schema"
cp "$probe_root/baseline/FileUtilities.swift" "$probe_output/src/FileUtilities.swift"
cp "$probe_root/fixtures/"*.txt "$probe_output/fixtures/"
for fixture in invalid.pdf two-pages.pdf; do
  base64 -D -i "$probe_root/fixtures/$fixture.b64" -o "$probe_output/fixtures/$fixture"
done
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
native_swift="$(xcrun swiftc --version)"
if [[ "$native_swift" != *"Apple Swift version 6.3.1 ("* ]]; then
  printf 'Matching-compiler control requires Apple Swift 6.3.1 from Xcode 26.4.1.\n' >&2
  exit 1
fi
{
  xcodebuild -version
  printf '%s\n' "$native_swift"
  xcrun --sdk macosx --show-sdk-version
} > "$probe_output/summary/toolchain.txt"
common=(-target x86_64-apple-macos13.0 -sdk "$sdk_path" -swift-version 5 -Xfrontend -enable-cross-import-overlays)
xcrun swiftc "${common[@]}" "$probe_output/src/FileUtilities.swift" \
  "$probe_root/Behavior.swift" -o "$probe_output/behavior"
"$probe_output/behavior" "$probe_output/fixtures" > "$probe_output/summary/behavior.txt"
behavior_digest="$(shasum -a 256 "$probe_output/summary/behavior.txt")"
if [[ "${behavior_digest%% *}" != "46668bfa093cbbbb35dd864350e992e0f8bcba65985833195bf455fac47d4735" ]]; then
  printf 'Matching-compiler reproduction output differs from its verified six-case baseline: %s\n' "${behavior_digest%% *}" >&2
  exit 1
fi
printf -v compile_command '%q ' xcrun swiftc "${common[@]}" \
  -module-cache-path "$probe_output/module-cache" -emit-module \
  "$probe_output/src/FileUtilities.swift" -module-name FileUtilitiesProbe \
  -emit-module-path "$probe_output/FileUtilitiesProbe.swiftmodule"
"$extractor_cli" database create "$probe_output/db" --language=swift \
  --source-root="$probe_output/src" --command="$compile_command" --threads=2 --ram=4096
"$analysis_cli" resolve database "$probe_output/db" --format=json > "$probe_output/database-metadata.json"
dataset_dir="$(jq -er '.datasetFolder | select(type == "string" and length > 0)' "$probe_output/database-metadata.json")"
case "$dataset_dir" in
  "$probe_output/db/"*) ;;
  *) printf 'Matching-compiler database reports a dataset outside its owned directory.\n' >&2; exit 1 ;;
esac
schemas=("$dataset_dir/"*.dbscheme)
if [[ "${#schemas[@]}" != "1" || ! -f "${schemas[0]}" ]]; then
  printf 'Matching-compiler dataset must contain exactly one schema file.\n' >&2
  exit 1
fi
cmp "${schemas[0]}" "$new_schema"
schema_digest="$(shasum -a 256 "${schemas[0]}")"
printf '%s\n' "${schema_digest%% *}" > "$probe_output/summary/schema-sha256.txt"
"$analysis_cli" database analyze "$probe_output/db" \
  codeql/swift-queries@1.3.13:codeql-suites/swift-code-scanning.qls \
  --format=sarif-latest --output="$probe_output/swift.sarif" --threads=2 --ram=4096
jq -e '[.runs[].invocations[].toolExecutionNotifications[] | select(.descriptor.id == "swift/diagnostics/extraction-errors") | {id: .descriptor.id, level, message}]' \
  "$probe_output/swift.sarif" > "$probe_output/summary/extraction-errors.json"
bash "$probe_root/inspect-database.sh" "$analysis_cli" "$probe_output/db" "$probe_output/semantics"
cp "$probe_output/semantics/"*.csv "$probe_output/summary/"
