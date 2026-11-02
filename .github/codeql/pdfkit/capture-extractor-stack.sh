#!/bin/bash
set -euo pipefail

# A fixture-only RUN_UNDER hook; the caller owns the output directory and job timeout.
extractor="${1:?Pass the CodeQL extractor wrapper}"
shift
probe_output="${PROBE_DEBUG_OUTPUT:?Pass an existing absolute diagnostic output directory}"
extractor_root="${CODEQL_EXTRACTOR_SWIFT_ROOT:?CodeQL must supply its Swift extractor root}"
probe_root="$(cd "$(dirname "$0")" && pwd)"
if [[ "$probe_root" == *[[:space:]]* ]]; then
  printf 'The RUN_UNDER wrapper must have a path without whitespace.\n' >&2
  exit 125
fi
if [[ "$probe_output" != /* || ! -d "$probe_output" ]]; then
  printf 'Extractor stack capture requires an existing absolute diagnostic output directory.\n' >&2
  exit 125
fi
if [[ "$extractor_root" != /* || "$extractor" != "$extractor_root/tools/osx64/extractor" ]]; then
  printf 'Extractor stack capture requires the wrapper from the verified CodeQL Swift extractor root.\n' >&2
  exit 125
fi
extractor_real="$extractor.real"
if [[ ! -f "$extractor_real" || ! -x "$extractor_real" ]]; then
  printf 'The CodeQL native extractor is missing or not executable.\n' >&2
  exit 125
fi

invocation="$probe_output/$$"
mkdir -m 700 "$invocation"
export PROBE_DEBUG_INVOCATION="$invocation"
# Restricted launcher binaries can strip DYLD variables. Reproduce only the official launcher value.
export PROBE_DEBUG_LIBRARY_PATH="${extractor%/*}"
extractor_digest="$(shasum -a 256 "$extractor_real")"
wrapper_digest="$(shasum -a 256 "$probe_root/capture-extractor-stack.sh")"
commands_digest="$(shasum -a 256 "$probe_root/capture-extractor-stack.lldb")"
jq -n --argjson wrapper_pid "$$" --arg extractor "$extractor_real" \
  --arg extractor_sha256 "${extractor_digest%% *}" --arg wrapper_sha256 "${wrapper_digest%% *}" \
  --arg commands_sha256 "${commands_digest%% *}" \
  '{wrapper_pid:$wrapper_pid, extractor:$extractor, extractor_sha256:$extractor_sha256,
    wrapper_sha256:$wrapper_sha256, commands_sha256:$commands_sha256}' > "$invocation/invocation.json"
printf '%q ' "$extractor_real" "$@" > "$invocation/command.sh"
printf '\n' >> "$invocation/command.sh"

if xcrun lldb --no-lldbinit --batch --source "$probe_root/capture-extractor-stack.lldb" \
  -- "$extractor_real" "$@" > "$invocation/lldb.log" 2>&1; then
  debugger_status=0
else
  debugger_status=$?
fi
jq -n --argjson status "$debugger_status" '{debugger_exit_status:$status}' > "$invocation/debugger-exit.json"
if [[ ! -s "$invocation/status.json" ]]; then
  jq -n --argjson status "$debugger_status" \
    '{process_state:null, child_exit_status:null, breakpoint_locations:null,
      breakpoint_resolved_locations:null, breakpoint_hits:null, capture_verified:false, capture_exit_status:125,
      debugger_exit_status:$status, failure:"missing_debugger_status"}' > "$invocation/status.json"
  printf 'Extractor stack capture did not produce a process status; inspect its diagnostic log.\n' >&2
  exit 125
fi
if ! capture_status="$(jq -er '.capture_exit_status | select(type == "number" and . == floor and . >= 0 and . <= 255)' "$invocation/status.json")"; then
  printf 'Extractor stack capture produced an invalid process status; inspect status.json.\n' >&2
  exit 125
fi
if [[ "$debugger_status" != "$capture_status" ]]; then
  printf 'Extractor stack capture debugger exit differs from its recorded process status; inspect the diagnostic evidence.\n' >&2
  exit 125
fi
exit "$capture_status"
