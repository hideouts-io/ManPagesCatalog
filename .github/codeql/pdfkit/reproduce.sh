#!/bin/bash
set -euo pipefail

# Public github/codeql#22803 reproduction, verified against attachment SHA256
# 1e00b9184f9002b0beb26f7488a8922ced3a815aa08a66127681b6178efcefda.
# The original sources, MIT notice and six real file/PDF cases are unchanged.
# Use the job's selected Xcode; compare x86_64 Swift 5 builds like PR #3.
codeql_cli="${1:?Pass the verified CodeQL executable}"
probe_output="${2:?Pass a new absolute output directory}"
probe_root="$(cd "$(dirname "$0")" && pwd)"
mkdir "$probe_output"
mkdir "$probe_output/fixtures"
cp "$probe_root/fixtures/"*.txt "$probe_output/fixtures/"
for fixture in invalid.pdf two-pages.pdf; do
  base64 -D -i "$probe_root/fixtures/$fixture.b64" -o "$probe_output/fixtures/$fixture"
done
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
"$codeql_cli" version --format=json > "$probe_output/codeql-version.json"
jq -e '.version == "2.27.3"' "$probe_output/codeql-version.json"
{
  sw_vers
  xcodebuild -version
  xcrun swiftc --version
  xcrun --sdk macosx --show-sdk-version
} > "$probe_output/toolchain.txt"
common=(-target x86_64-apple-macos13.0 -sdk "$sdk_path" -swift-version 5 -Xfrontend -enable-cross-import-overlays)

for variant in baseline explicit-class; do
  case_dir="$probe_output/$variant"
  mkdir -p "$case_dir/src"
  cp "$probe_root/$variant/FileUtilities.swift" "$case_dir/src/FileUtilities.swift"
  xcrun swiftc "${common[@]}" "$case_dir/src/FileUtilities.swift" \
    "$probe_root/Behavior.swift" -o "$case_dir/behavior"
  "$case_dir/behavior" "$probe_output/fixtures" > "$case_dir/behavior.txt"
  printf -v compile_command '%q ' xcrun swiftc "${common[@]}" \
    -module-cache-path "$case_dir/module-cache" -emit-module \
    "$case_dir/src/FileUtilities.swift" -module-name FileUtilitiesProbe \
    -emit-module-path "$case_dir/FileUtilitiesProbe.swiftmodule"
  "$codeql_cli" database create "$case_dir/db" --language=swift \
    --source-root="$case_dir/src" --command="$compile_command" --threads=2 --ram=4096 --verbosity=progress+++
  "$codeql_cli" database analyze "$case_dir/db" \
    codeql/swift-queries:codeql-suites/swift-code-scanning.qls \
    --format=sarif-latest --output="$case_dir/swift.sarif" --threads=2 --ram=4096
  jq -e '[.runs[].invocations[].toolExecutionNotifications[] | select(.descriptor.id == "swift/diagnostics/extraction-errors") | {id: .descriptor.id, level, message}]' \
    "$case_dir/swift.sarif" > "$case_dir/extraction-errors.json"
  # Fixture-only evidence is separate from raw databases and full compiler logs.
  mkdir "$probe_output/summary-$variant"
  cp "$case_dir/behavior.txt" "$case_dir/extraction-errors.json" "$probe_output/summary-$variant/"
  bash "$probe_root/inspect-database.sh" "$codeql_cli" "$case_dir/db" "$case_dir/semantics"
  cp "$case_dir/semantics/"*.csv \
    "$case_dir/semantics/codeql-pack.lock.yml" "$probe_output/summary-$variant/"
done
cmp "$probe_output/baseline/behavior.txt" "$probe_output/explicit-class/behavior.txt"
printf '%s\n' 'Both six-case behavior controls agree. Inspect extraction-errors.json; diagnostic success is not clean application extraction.'
