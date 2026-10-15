#!/bin/zsh
set -eu

if [[ $# -ne 1 || "$1" != /* ]]; then
    print -u2 'Usage: Benchmarks/build_synthetic_tree.sh /absolute/path/to/synthetic-tree'
    exit 64
fi

benchmark_directory=${0:A:h}
mkdir -p "${1:A:h}"
/usr/bin/swiftc -O -parse-as-library \
    "$benchmark_directory/SyntheticModels.swift" \
    "$benchmark_directory/SyntheticFixtures.swift" \
    "$benchmark_directory/SyntheticVerification.swift" \
    "$benchmark_directory/SyntheticTree.swift" -o "$1"
