#!/bin/zsh
set -eu

if [[ $# -ne 1 || "$1" != /* || "$1" != *.app || -e "$1" ]]; then
    print -u2 'Usage: Benchmarks/build_export_panel_reproduction.sh /absolute/new/ExportPanelReproduction.app'
    exit 64
fi

benchmark_directory=${0:A:h}
project_directory=${benchmark_directory:h}
reproduction_application=$1
mkdir -p "$reproduction_application/Contents/MacOS" "$reproduction_application/Contents/Resources"
/usr/bin/shasum -a 256 \
    "$benchmark_directory/ExportPanelReproduction.swift" \
    "$benchmark_directory/build_export_panel_reproduction.sh" \
    "$project_directory/ManPageCatalog/Store/ExportPanel.swift" \
    "$project_directory/ManPageCatalog/Store/ManualProcess.swift" \
    > "$reproduction_application/Contents/Resources/compile-inputs.sha256"
/usr/bin/swiftc --version > "$reproduction_application/Contents/Resources/compiler.txt"
/usr/bin/swiftc -O -parse-as-library \
    "$benchmark_directory/ExportPanelReproduction.swift" \
    "$project_directory/ManPageCatalog/Store/ExportPanel.swift" \
    "$project_directory/ManPageCatalog/Store/ManualProcess.swift" \
    -framework AppKit -framework UniformTypeIdentifiers \
    -o "$reproduction_application/Contents/MacOS/ExportPanelReproduction"
/bin/cat > "$reproduction_application/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.hideouts.ManPagesCatalog.ExportPanelReproduction</string>
<key>CFBundleExecutable</key><string>ExportPanelReproduction</string>
<key>CFBundleName</key><string>ExportPanelReproduction</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$reproduction_application"
