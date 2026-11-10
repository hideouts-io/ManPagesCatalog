#!/bin/bash
set -euo pipefail

# Inspect imported types and source calls without changing extraction acceptance.
codeql_cli="${1:?Pass the CodeQL executable}"
database="${2:?Pass the finalized Swift database}"
probe_output="${3:?Pass a new output directory}"
probe_root="$(cd "$(dirname "$0")" && pwd)"
test -f "$database/codeql-database.yml"
mkdir "$probe_output"
(
  cd "$probe_root/queries"
  "$codeql_cli" pack install
)
cp "$probe_root/queries/codeql-pack.lock.yml" "$probe_output/codeql-pack.lock.yml"
for query in candidates inheritance calls expressions; do
  "$codeql_cli" query run "$probe_root/queries/$query.ql" \
    --database="$database" --output="$probe_output/$query.bqrs" --threads=2 --ram=4096
  "$codeql_cli" bqrs decode "$probe_output/$query.bqrs" \
    --format=csv --output="$probe_output/$query.csv"
done
