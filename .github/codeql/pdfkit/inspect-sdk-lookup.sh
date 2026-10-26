#!/bin/bash
set -euo pipefail

# Compare ordinary SDK import with an explicit macro lookup; retain each real diagnostic.
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
jq -n --argjson macro_status "$macro_status" \
  '{import_only_exit: 0, macro_reference_exit: $macro_status}' > "$probe_output/exit-status.json"
printf 'Native import-only exit: 0; native macro-reference exit: %s. Inspect the retained diagnostics.\n' "$macro_status"
