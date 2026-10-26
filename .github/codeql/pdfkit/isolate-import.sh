#!/bin/bash
set -euo pipefail

# Isolate SDK import-graph extraction from PDF operations using a real compiler.
codeql_cli="${1:?Pass the verified CodeQL executable}"
probe_source="${2:?Pass an import-only Swift source file}"
probe_output="${3:?Pass a new absolute output directory}"
probe_root="$(cd "$(dirname "$0")" && pwd)"
mkdir "$probe_output"
mkdir "$probe_output/src" "$probe_output/summary"
cp "$probe_source" "$probe_output/src/Probe.swift"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
"$codeql_cli" version --format=json > "$probe_output/summary/codeql-version.json"
jq -e '.version == "2.27.3"' "$probe_output/summary/codeql-version.json"
{
  xcodebuild -version
  xcrun swiftc --version
  xcrun --sdk macosx --show-sdk-version
} > "$probe_output/summary/toolchain.txt"
printf -v compile_command '%q ' xcrun swiftc -target x86_64-apple-macos13.0 \
  -sdk "$sdk_path" -swift-version 5 -Xfrontend -enable-cross-import-overlays \
  -module-cache-path "$probe_output/module-cache" -emit-module \
  "$probe_output/src/Probe.swift" -module-name ImportProbe \
  -emit-module-path "$probe_output/ImportProbe.swiftmodule"
"$codeql_cli" database create "$probe_output/db" --language=swift \
  --source-root="$probe_output/src" --command="$compile_command" --threads=2 --ram=4096
"$codeql_cli" database analyze "$probe_output/db" \
  codeql/swift-queries:codeql-suites/swift-code-scanning.qls \
  --format=sarif-latest --output="$probe_output/swift.sarif" --threads=2 --ram=4096
jq -e '[.runs[].invocations[].toolExecutionNotifications[] | select(.descriptor.id == "swift/diagnostics/extraction-errors") | {id: .descriptor.id, level, message}]' \
  "$probe_output/swift.sarif" > "$probe_output/summary/extraction-errors.json"
bash "$probe_root/inspect-database.sh" "$codeql_cli" "$probe_output/db" "$probe_output/semantics"
cp "$probe_output/semantics/"*.csv "$probe_output/summary/"
