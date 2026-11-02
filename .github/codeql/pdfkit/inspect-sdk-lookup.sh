#!/bin/bash
set -euo pipefail

# Compare SDK import, macro lookup and public module enumeration; retain each real diagnostic.
probe_output="${1:?Pass a new absolute output directory}"
probe_root="$(cd "$(dirname "$0")" && pwd)"
mkdir "$probe_output"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
{
  xcodebuild -version
  xcrun swiftc --version
  xcrun --sdk macosx --show-sdk-version
} > "$probe_output/toolchain.txt"
pdf_header="$sdk_path/System/Library/Frameworks/PDFKit.framework/Headers/PDFKitPlatform.h"
appkit_headers="$sdk_path/System/Library/Frameworks/AppKit.framework/Headers"
{
  grep -E '^#define PDFKitPlatformAccessibilityElement[[:space:]]+NSAccessibilityElement' "$pdf_header"
  grep -E '^@interface NSAccessibilityElement[[:space:]]*:' "$appkit_headers/NSAccessibilityElement.h"
  grep -E '^@protocol NSAccessibilityElement[[:space:]]*<' "$appkit_headers/NSAccessibilityProtocols.h"
} > "$probe_output/sdk-declarations.txt"
common=(-target x86_64-apple-macos13.0 -sdk "$sdk_path" -swift-version 5 -Xfrontend -enable-cross-import-overlays)
xcrun swiftc "${common[@]}" -module-cache-path "$probe_output/import-cache" \
  -typecheck "$probe_root/import-controls/pdfkit/Probe.swift" > "$probe_output/import-only.log" 2>&1
if xcrun swiftc "${common[@]}" -module-cache-path "$probe_output/macro-cache" \
  -typecheck "$probe_root/import-controls/pdfkit-macro/Probe.swift" > "$probe_output/macro-reference.log" 2>&1; then
  macro_status=0
else
  macro_status=$?
fi
mkdir "$probe_output/symbolgraph"
if xcrun swift-symbolgraph-extract -target x86_64-apple-macos13.0 -sdk "$sdk_path" \
  -swift-version 5 -module-cache-path "$probe_output/symbolgraph-cache" \
  -module-name PDFKit -output-dir "$probe_output/symbolgraph" > "$probe_output/symbolgraph.log" 2>&1; then
  symbolgraph_status=0
else
  symbolgraph_status=$?
fi
symbolgraph_errors="$(awk '/ error:/ { count++ } END { print count + 0 }' "$probe_output/symbolgraph.log")"
jq -n --argjson macro_status "$macro_status" --argjson symbolgraph_status "$symbolgraph_status" \
  --argjson symbolgraph_errors "$symbolgraph_errors" \
  '{import_only_exit: 0, macro_reference_exit: $macro_status, symbolgraph_exit: $symbolgraph_status,
    symbolgraph_error_line_count: $symbolgraph_errors}' > "$probe_output/exit-status.json"
printf 'Native import-only exit: 0; macro-reference exit: %s; symbol-graph exit: %s; symbol-graph compiler error lines: %s. Inspect the retained diagnostics.\n' \
  "$macro_status" "$symbolgraph_status" "$symbolgraph_errors"
if [[ "$symbolgraph_status" != "0" ]]; then
  printf 'PDFKit symbol-graph enumeration failed; inspect symbolgraph.log.\n' >&2
  exit "$symbolgraph_status"
fi
