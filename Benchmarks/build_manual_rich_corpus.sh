#!/bin/zsh
set -eu

if [[ $# -ne 1 || "$1" != /* ]]; then
    print -u2 'Usage: Benchmarks/build_manual_rich_corpus.sh /absolute/path/to/manual-rich-corpus'
    exit 64
fi

benchmark_directory=${0:A:h}
mkdir -p "${1:A:h}"
/usr/bin/swiftc -O -parse-as-library \
    "$benchmark_directory/ManualRichModels.swift" \
    "$benchmark_directory/ManualRichGeneration.swift" \
    "$benchmark_directory/ManualRichVerification.swift" \
    "$benchmark_directory/ManualRichCorpus.swift" -lsqlite3 -o "$1"
