#!/bin/sh
# Memory-safety check of the engine with valgrind's memcheck. Everything is
# built with -Dgc_none (plain malloc, so out-of-bounds reads and writes are
# visible) and run twice:
#
# 1. the whole spec suite;
# 2. the cryaml dump server on FUZZ_CASES (default 5000) fuzzer-generated
#    inputs and Builder scripts.
#
# Fails on any valgrind error not covered by scripts/memcheck.supp (known
# stdlib bugs, each pinned to its stdlib frames), and when either run doesn't
# complete.
#
#   scripts/memcheck.sh [OUTPUT_DIR]     (default: .cache/memcheck)
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/.cache/memcheck}"
cases="${FUZZ_CASES:-5000}"
mkdir -p "$out"
failed=0

run_valgrind() { # log, command...
  log="$1"
  shift
  valgrind --error-limit=no --num-callers=24 --suppressions="$root/scripts/memcheck.supp" \
    --log-file="$log" "$@"
}

errors() { # label, log
  summary="$(grep 'ERROR SUMMARY' "$2" | tail -n 1)"
  echo "$1: ${summary#*== }"
  case "$summary" in
  *"ERROR SUMMARY: 0 errors"*) ;;
  *)
    echo "$1: unsuppressed valgrind errors, see $2" >&2
    failed=1
    ;;
  esac
}

# 1. Spec suite. One spec fails by design: nothing is finalized under gc_none.
crystal build $(find "$root/spec" -name '*_spec.cr' | sort) -o "$out/specs" -Dgc_none --debug
run_valgrind "$out/specs.valgrind.txt" "$out/specs" > "$out/specs.txt" 2>&1 || true
summary="$(grep -E '^[0-9]+ examples, ' "$out/specs.txt" || true)"
echo "spec suite: ${summary:-no summary}"
failures="$(grep -E '^crystal spec ' "$out/specs.txt" || true)"
case "$summary" in
*" examples, 1 failures, 0 errors, "*) ;;
*) failed=1 ;;
esac
case "$failures" in
*"YAML::Serializable calls #finalize") ;;
*)
  echo "spec suite didn't complete with only the #finalize failure, see $out/specs.txt" >&2
  failed=1
  ;;
esac
errors "spec suite" "$out/specs.valgrind.txt"

# 2. Fuzzer-generated inputs through the cryaml dump server.
crystal build "$root/spec/support/oracle.cr" -o "$out/server" -Dcryaml -Dgc_none --debug
crystal run "$root/fuzz/fuzz.cr" -- --bundle "$out/fuzz.json" --batch "$cases" --seed "${FUZZ_SEED:-1}"
if ! run_valgrind "$out/fuzz.valgrind.txt" "$out/server" "$out/fuzz.json" > "$out/fuzz.out.json"; then
  echo "dump server failed, see $out/fuzz.valgrind.txt" >&2
  failed=1
fi
expected=$(($(jq length "$out/fuzz.json") + 2)) # plus __libyaml_version__ and __engine__
dumped="$(jq length "$out/fuzz.out.json" 2>/dev/null || echo 0)"
echo "$cases fuzz cases: $dumped of $expected results"
[ "$dumped" = "$expected" ] || failed=1
errors "$cases fuzz cases" "$out/fuzz.valgrind.txt"

exit $failed
