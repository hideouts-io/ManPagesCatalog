#!/bin/bash
set -euo pipefail

# Preserve a real invalid-input compiler exit while requiring its specific diagnostic.
result_directory="${1:?Pass a new owned result directory}"
shift
mkdir "$result_directory"
if "$@" > "$result_directory/compiler.log" 2>&1; then
  compiler_status=0
else
  compiler_status=$?
fi
jq -n --argjson status "$compiler_status" '{compiler_exit_status:$status}' > "$result_directory/status.json"
if [[ "$compiler_status" != "1" ]]; then
  printf 'The negative alias control expected native compiler exit 1; observed %s.\n' "$compiler_status" >&2
  exit 1
fi
if ! grep -F "error: cannot find 'ValidationFunctionAlias' in scope" "$result_directory/compiler.log"; then
  printf 'The negative alias control did not emit its required compiler diagnostic.\n' >&2
  exit 1
fi
