#!/bin/sh
# Line coverage of src/ by the whole spec suite, measured with kcov.
#
#   scripts/coverage.sh [OUTPUT_DIR]     (default: .cache/coverage)
#
# Prints per-file coverage (scripts/coverage_report.cr) and fails if a file
# drops below its floor. The HTML report is in OUTPUT_DIR/report.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/.cache/coverage}"
kcov="${KCOV:-kcov}"

mkdir -p "$out"
crystal build $(find "$root/spec" -name '*_spec.cr' | sort) -o "$out/specs" --debug
rm -rf "$out/report"
"$kcov" --include-path="$root/src" "$out/report" "$out/specs" > "$out/specs.log"
tail -n 1 "$out/specs.log"
crystal run "$root/scripts/coverage_report.cr" -- "$out/report/specs/coverage.json"
