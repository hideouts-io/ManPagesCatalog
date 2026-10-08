#!/bin/zsh
set -eu

if [[ $# -ne 1 || "$1" != /* ]]; then
    print -u2 'Usage: Benchmarks/build_library_benchmark.sh /absolute/path/to/library-benchmark'
    exit 64
fi

benchmark_directory=${0:A:h}
project_directory=${benchmark_directory:h}
mkdir -p "${1:A:h}"
/usr/bin/swiftc -O -parse-as-library -enable-bare-slash-regex \
    "$benchmark_directory/LibraryBenchmark.swift" \
    "$project_directory/ManPageCatalog/Reader/InteractionDiagnostics.swift" \
    "$project_directory/ManPageCatalog/Library/LibraryStore.swift" \
    "$project_directory/ManPageCatalog/Library/ManualSearch.swift" \
    "$project_directory/ManPageCatalog/Library/DiscoveryCheckpoint.swift" \
    "$project_directory/ManPageCatalog/Library/DiscoveryPlan.swift" \
    "$project_directory/ManPageCatalog/Library/ManualDiscovery.swift" \
    "$project_directory/ManPageCatalog/Library/ManualPage.swift" \
    "$project_directory/ManPageCatalog/Library/ManualSearchIndex.swift" \
    "$project_directory/ManPageCatalog/Library/ScanPerformance.swift" \
    "$project_directory/ManPageCatalog/Terminal/CommandExecutable.swift" \
    "$project_directory/ManPageCatalog/Store/ManualCatalog.swift" \
    "$project_directory/ManPageCatalog/Store/ManualProcess.swift" \
    "$project_directory/ManPageCatalog/Store/CatalogStore.swift" \
    "$project_directory/ManPageCatalog/Models/CatalogEntry.swift" \
    -framework PDFKit -framework Combine -lsqlite3 -o "$1"
