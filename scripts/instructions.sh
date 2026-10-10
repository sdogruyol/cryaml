#!/bin/sh
# Instruction counts (callgrind) of every benchmark workload and operation,
# stdlib (libyaml) vs cryaml, as a Markdown table. Deterministic, unlike wall
# clock, so it is what performance changes are judged by.
#
#   scripts/instructions.sh [WORKLOAD_FILTER]   (default: all workloads)
#
# Needs valgrind and libyaml (for the stdlib side). Release builds go to
# .cache/instructions.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/.cache/instructions"
filter="${1:-}"
mkdir -p "$out"
crystal build --release --no-debug "$root/bench/bench.cr" -o "$out/bench-cryaml"
crystal build --release --no-debug -Dstdlib_yaml "$root/bench/bench.cr" -o "$out/bench-stdlib"
[ "$("$out/bench-stdlib" --libyaml-version)" = "0.2.5" ] || {
  echo "the stdlib side must link libyaml 0.2.5" >&2
  exit 1
}

count() { # binary, workload, operation
  valgrind --tool=callgrind --callgrind-out-file=/dev/null --toggle-collect='*measured_operation*' \
    "$1" --measure "$2" "$3" 2>&1 | sed -n 's/.*Collected : \([0-9]*\).*/\1/p'
}

workloads="$("$out/bench-cryaml" --workloads)"
echo "| Workload | Operation | libyaml | cryaml | cryaml/libyaml |"
echo "| --- | --- | ---: | ---: | ---: |"
echo "$workloads" | while IFS= read -r workload; do
  case "$workload" in *"$filter"*) ;; *) continue ;; esac
  for operation in parse pull nodes dump; do
    # The deep document exceeds Builder#max_nesting, so it can't be dumped.
    [ "$operation" = dump ] && [ "${workload#deep}" != "$workload" ] && continue
    lib="$(count "$out/bench-stdlib" "$workload" "$operation")"
    cry="$(count "$out/bench-cryaml" "$workload" "$operation")"
    awk -v w="$workload" -v o="$operation" -v l="$lib" -v c="$cry" \
      'BEGIN { printf "| %s | %s | %.2fM | %.2fM | %.3f |\n", w, o, l / 1e6, c / 1e6, c / l }'
  done
done
