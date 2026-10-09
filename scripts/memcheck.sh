#!/bin/sh
# Memory-safety check of the engine with valgrind's memcheck. Everything is
# built with -Dgc_none (plain malloc, so out-of-bounds reads and writes are
# visible) and run twice:
#
# 1. the whole spec suite;
# 2. the cryaml dump server on FUZZ_CASES (default 5000) fuzzer-generated
#    inputs and Builder scripts.
#
# Fails if any valgrind error has an engine method (YAML::Reader, Scanner,
# EventParser, Emitter, ByteBuffer, Queue, Stack, Chars, PullParser,
# Builder) among its top frames. Errors entirely inside the stdlib are
# counted separately: some stdlib code isn't valgrind-clean under gc_none.
#
#   scripts/memcheck.sh [OUTPUT_DIR]     (default: .cache/memcheck)
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/.cache/memcheck}"
cases="${FUZZ_CASES:-5000}"
mkdir -p "$out"

check() {
  awk -v label="$2" '
    /^==[0-9]+== (Invalid|Conditional|Use of|Source and|Mismatched)/ { n = 0; engine = 0; total++; next }
    /^==[0-9]+==    (at|by)/ {
      n++
      if (n <= 4 && $0 ~ /YAML::(Reader|Scanner|EventParser|Emitter|ByteBuffer|Queue|Stack|Chars|PullParser|Builder)/) engine = 1
      if (n == 4 && engine) bad++
    }
    END {
      printf "%s: %d valgrind error contexts, %d in engine code\n", label, total, bad
      exit bad > 0
    }
  ' "$1"
}

# 1. Spec suite. One spec fails by design: nothing is finalized under gc_none.
crystal build $(find "$root/spec" -name '*_spec.cr' | sort) -o "$out/specs" -Dgc_none --debug
valgrind --error-limit=no --num-callers=12 --log-file="$out/specs.valgrind.txt" \
  "$out/specs" > "$out/specs.txt" 2>&1 || true
tail -n 1 "$out/specs.txt"
specs_ok=0
check "$out/specs.valgrind.txt" "spec suite" || specs_ok=1

# 2. Fuzzer-generated inputs through the cryaml dump server.
crystal build "$root/spec/support/oracle.cr" -o "$out/server" -Dcryaml -Dgc_none --debug
crystal run "$root/fuzz/fuzz.cr" -- --bundle "$out/fuzz.json" --batch "$cases" --seed "${FUZZ_SEED:-1}"
valgrind --error-limit=no --num-callers=12 --log-file="$out/fuzz.valgrind.txt" \
  "$out/server" "$out/fuzz.json" > /dev/null 2>&1 || true
fuzz_ok=0
check "$out/fuzz.valgrind.txt" "$cases fuzz cases" || fuzz_ok=1

exit $((specs_ok + fuzz_ok))
