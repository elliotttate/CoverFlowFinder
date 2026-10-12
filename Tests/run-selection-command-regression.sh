#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
selection_test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/flowfinder-selection-tests.XXXXXX")
trap 'rm -rf "$selection_test_build_dir"' EXIT
source Tests/compile-regression.sh
compile_regression Tests/SelectionCommandRegression.swift "$selection_test_build_dir/selection-regression" "$selection_test_build_dir"
"$selection_test_build_dir/selection-regression"
