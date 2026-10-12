#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
archive_test_scratch=$(mktemp -d "${TMPDIR:-/tmp}/flowfinder-archive-tests.XXXXXX")
trap 'rm -rf "$archive_test_scratch"' EXIT
source Tests/compile-regression.sh
python3 Tests/generate-archive-fixtures.py "$archive_test_scratch/fixtures"
compile_regression Tests/ArchiveRegression.swift "$archive_test_scratch/archive-regression" "$archive_test_scratch"
"$archive_test_scratch/archive-regression" "$archive_test_scratch/fixtures"
