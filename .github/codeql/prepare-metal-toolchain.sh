#!/bin/bash
set -euo pipefail

metal_temporary="${1:?Pass an existing absolute temporary directory}"
metal_output="${2:?Pass the absolute workflow output file}"
[[ "$metal_temporary" == /* && -d "$metal_temporary" ]]
[[ "$metal_output" == /* && -f "$metal_output" ]]
metal_evidence="$metal_temporary/metal-evidence"
mkdir "$metal_evidence"
metal_phase=host-identity
trap 'metal_exit=$?; printf "Metal preparation failed during %s (exit %s).\n" "$metal_phase" "$metal_exit" >&2; printf "{\"phase\":\"%s\",\"exit_status\":%s}\n" "$metal_phase" "$metal_exit" > "$metal_evidence/status.json"; exit "$metal_exit"' ERR
printf 'Metal preparation phase: %s\n' "$metal_phase"
test "$DEVELOPER_DIR" = /Applications/Xcode_26.4.1.app/Contents/Developer
printf '%s\n' "$DEVELOPER_DIR" > "$metal_evidence/developer-dir.txt"
xcodebuild -version > "$metal_temporary/metal-xcode-version.txt"
xcrun --sdk macosx --show-sdk-version > "$metal_temporary/metal-sdk-version.txt"
uname -m > "$metal_temporary/metal-architecture.txt"
for metadata_name in xcode-version sdk-version architecture; do
  test "$(wc -c < "$metal_temporary/metal-$metadata_name.txt")" -le 1024
  cp "$metal_temporary/metal-$metadata_name.txt" "$metal_evidence/$metadata_name.txt"
done
metal_phase=download
printf 'Metal preparation phase: %s\n' "$metal_phase"
xcodebuild -downloadComponent MetalToolchain
metal_phase=show-component
printf 'Metal preparation phase: %s\n' "$metal_phase"
if xcodebuild -showComponent MetalToolchain -json > "$metal_temporary/metal-toolchain.json"; then
  show_status=0
else
  show_status=$?
fi
metal_phase=validate-component-paths
printf 'Metal preparation phase: %s\n' "$metal_phase"
python3 .github/codeql/validate-metal-toolchain.py \
  "$metal_temporary/metal-toolchain.json" "$metal_evidence" "$show_status" \
  > "$metal_temporary/metal-resolution.json"
identifier=$(jq -er '.identifier | select(type == "string" and length > 0 and length <= 1024)' "$metal_temporary/metal-resolution.json")
search_path=$(jq -er '.search_path | select(type == "string" and length > 0 and length <= 1024)' "$metal_temporary/metal-resolution.json")
metal_phase=verify-executables
printf 'Metal preparation phase: %s\n' "$metal_phase"
test -x "$search_path/Metal.xctoolchain/usr/bin/metal"
test -x "$search_path/Metal.xctoolchain/usr/bin/metallib"
metal_phase=verify-tool-identities
printf 'Metal preparation phase: %s\n' "$metal_phase"
resolved_metal=$(EXTERNAL_TOOLCHAINS_DIR="$search_path" xcrun --toolchain "$identifier" --sdk macosx --find metal)
resolved_metallib=$(EXTERNAL_TOOLCHAINS_DIR="$search_path" xcrun --toolchain "$identifier" --sdk macosx --find metallib)
for resolved_tool in "$resolved_metal" "$resolved_metallib"; do
  [[ ${#resolved_tool} -le 1024 && "$resolved_tool" != *$'\n'* && "$resolved_tool" != *$'\r'* ]]
done
printf '%s\n' "$resolved_metal" > "$metal_evidence/xcrun-metal-path.txt"
printf '%s\n' "$resolved_metallib" > "$metal_evidence/xcrun-metallib-path.txt"
test "$resolved_metal" -ef "$search_path/Metal.xctoolchain/usr/bin/metal"
test "$resolved_metallib" -ef "$search_path/Metal.xctoolchain/usr/bin/metallib"
metal_phase=compiler-version
printf 'Metal preparation phase: %s\n' "$metal_phase"
"$search_path/Metal.xctoolchain/usr/bin/metal" -v
printf 'identifier=%s\nsearch-path=%s\n' "$identifier" "$search_path" >> "$metal_output"
printf '{"phase":"complete","exit_status":0}\n' > "$metal_evidence/status.json"
