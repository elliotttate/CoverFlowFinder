#!/bin/bash
# Shared by the command-routing and archive regressions. Source this from the repository root.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
archive_test_derived_data=${CFF_ARCHIVE_BUILD_DIR:-${TMPDIR:-/tmp}/flowfinder-archive-regression-build}
archive_test_products="$archive_test_derived_data/Build/Products/Debug"
mkdir -p "$archive_test_derived_data"
if ! xcodebuild -project Vendor/SevenZip/Mac/SevenZip.xcodeproj -scheme SevenZipKit \
    -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$archive_test_derived_data" CODE_SIGNING_ALLOWED=NO build \
    > "$archive_test_derived_data/regression-engine-build.log" 2>&1; then
    tail -n 80 "$archive_test_derived_data/regression-engine-build.log"
    exit 1
fi
compile_regression() {
    local harness=$1 output=$2 scratch=$3
    sed 's/\r$//' FlowFinder/FlowFinderApp.swift | awk '
        /^import Sparkle/ { next }
        /^@main/ { skipping = 1; next }
        skipping && /^}/ { skipping = 0; next }
        !skipping { print }
    ' > "$scratch/FlowFinderApp-testable.swift"
    local sources=()
    while IFS= read -r source; do sources+=("$source"); done \
        < <(rg --files FlowFinder -g '*.swift' -g '!FlowFinderApp.swift' -g '!CheckForUpdates*.swift')
    xcrun swiftc -swift-version 5 -parse-as-library -Onone \
        -F "$archive_test_products" -framework SevenZipKit \
        -Xlinker -rpath -Xlinker "$archive_test_products" \
        "${sources[@]}" "$scratch/FlowFinderApp-testable.swift" "$harness" -o "$output"
}
