#!/bin/sh
# What it costs to compile a program that uses YAML, stdlib (libyaml binding)
# vs cryaml, as Markdown tables.
#
#   scripts/compile_cost.sh [-n RUNS] [-o DIR] [-r] [PROGRAM...]
#
# PROGRAM is `serializable` (bench/compile/serializable.cr: Serializable,
# YAML.parse, to_yaml), `parse` (bench/compile/parse.cr: YAML.parse of a
# String) or `bench` (bench/bench.cr); default: all three.
#
# Deterministic measures (what compile-time changes are judged by):
#
# - LLVM work: instructions (cachegrind) that `opt -O3` and `llc -O3` execute
#   on the program's unoptimized bitcode, which is what `--release` hands to
#   LLVM (`--release --emit llvm-bc` writes the module before optimizing it);
#   and `llc -O0` on the bitcode of a debug build (`--single-module --emit
#   llvm-bc`, debug info included: Crystal runs no IR pass at -O0, not even
#   the always-inliner, so codegen is all LLVM does there). The opt/llc
#   binaries (OPT, LLC; default opt-21, llc-21) needn't be the LLVM Crystal
#   links: the counts are a proxy, compared between builds of one machine.
# - IR size: instructions in the unoptimized module, in all functions and in
#   functions named `YAML::...` (the engine, plus the stdlib's YAML code that
#   both sides share), also after `always-inline` and after `-O3`.
#
# Timings (RUNS alternating rounds, default 3, `-n 0` skips them; min and
# median): CPU time (user + sys, children included) of `crystal build
# --release --no-debug` and of a debug `crystal build`, both with an empty
# cache, and of a debug rebuild after editing the program's main file (a
# string literal in a wrapper that requires it, so only the main module's
# code changes). Plus the stripped size of the release binary.
#
# Work files (bitcode, per-function IR sizes in *.ir.tsv) go to DIR (default
# .cache/compile_cost); `-r` reports from the ones there instead of measuring
# again. Needs valgrind, llvm-dis and libyaml.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/.cache/compile_cost"
runs=3
reuse=false
while getopts n:o:r opt; do
  case "$opt" in
  n) runs="$OPTARG" ;;
  r) reuse=true ;;
  o) out="$OPTARG" ;;
  *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -gt 0 ] || set -- serializable parse bench
OPT="${OPT:-opt-21}"
LLC="${LLC:-llc-21}"
LLVM_DIS="${LLVM_DIS:-llvm-dis-21}"
mkdir -p "$out"
cache="$out/crystal-cache"

source_of() {
  case "$1" in
  bench) echo "$root/bench/bench.cr" ;;
  *) echo "$root/bench/compile/$1.cr" ;;
  esac
}

flags_of() { # side
  [ "$1" = stdlib ] && echo -Dstdlib_yaml || true
}

# Instructions executed by a command, under cachegrind.
instructions() {
  valgrind --tool=cachegrind --cache-sim=no --cachegrind-out-file=/dev/null "$@" 2>&1 >/dev/null |
    sed -n 's/.*I *refs: *//p' | tr -d ,
}

# Per-function instruction counts of a bitcode file (count TAB name).
ir_sizes() {
  "$LLVM_DIS" "$1" -o - | awk '
    /^define / {
      if (match($0, /@("[^"]*"|[-a-zA-Z$._0-9]+)/)) { name = substr($0, RSTART + 1, RLENGTH - 1); gsub(/"/, "", name) }
      inside = 1; next
    }
    inside && /^}/ { inside = 0; next }
    inside && /^  [^ ;]/ { n[name]++ }
    END { for (f in n) print n[f] "\t" f }' | sort -rn
}

# "all yaml" instruction totals of a *.ir.tsv file.
ir_totals() {
  awk -F '\t' '{ all += $1 } $2 ~ /YAML::/ { yaml += $1 } END { print all + 0, yaml + 0 }' "$1"
}

# CPU seconds (user + sys, children included) of a command.
cpu_time() {
  /usr/bin/time -f '%U %S' -o "$out/time" "$@" >/dev/null 2>&1
  awk '{ printf "%.2f\n", $1 + $2 }' "$out/time"
}

# "min median" of the numbers in a file.
min_median() {
  sort -n "$1" | awk '{ v[NR] = $1 } END { printf "%.2f %.2f\n", v[1], NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}

measure() { # program side
  p="$1"
  side="$2"
  base="$out/$p-$side"
  src="$(source_of "$p")"
  flags="$(flags_of "$side")"
  rm -rf "$cache"
  # shellcheck disable=SC2086
  CRYSTAL_CACHE_DIR="$cache" crystal build --release --no-debug --emit llvm-bc $flags "$src" -o "$base"
  rm -rf "$cache"
  # shellcheck disable=SC2086
  CRYSTAL_CACHE_DIR="$cache" crystal build --single-module --emit llvm-bc $flags "$src" -o "$base-debug"
  strip -o "$base.stripped" "$base"
  "$OPT" -O3 "$base.bc" -o "$base.opt.bc"
  "$OPT" -passes=always-inline "$base.bc" -o "$base.inl.bc"
  ir_sizes "$base.bc" >"$base.ir.tsv"
  ir_sizes "$base.inl.bc" >"$base.inl.ir.tsv"
  ir_sizes "$base.opt.bc" >"$base.opt.ir.tsv"
  instructions "$OPT" -O3 "$base.bc" -o /dev/null >"$base.opt.count" &
  instructions "$LLC" -O3 -filetype=obj "$base.opt.bc" -o /dev/null >"$base.llc.count" &
  instructions "$LLC" -O0 -filetype=obj "$base-debug.bc" -o /dev/null >"$base.llc0.count" &
  wait
}

timings() { # program
  p="$1"
  src="$(source_of "$p")"
  for side in stdlib cryaml; do
    : >"$out/$p-$side.release.times"
    : >"$out/$p-$side.debug.times"
    : >"$out/$p-$side.rebuild.times"
  done
  wrapper="$out/edit/$p.cr"
  mkdir -p "$out/edit"
  # Crystal requires files by relative path (or from CRYSTAL_PATH).
  rel="$(realpath --relative-to="$out/edit" "$src")"
  case "$rel" in ../*) ;; *) rel="./$rel" ;; esac
  i=0
  while [ "$i" -lt "$runs" ]; do
    i=$((i + 1))
    for side in stdlib cryaml; do
      base="$out/$p-$side"
      flags="$(flags_of "$side")"
      rm -rf "$cache"
      # shellcheck disable=SC2086
      CRYSTAL_CACHE_DIR="$cache" cpu_time crystal build --release --no-debug $flags "$src" -o "$base.timed" >>"$base.release.times"
      rm -rf "$cache"
      printf 'require "%s"\nputs "edit 1"\n' "$rel" >"$wrapper"
      # shellcheck disable=SC2086
      CRYSTAL_CACHE_DIR="$cache" cpu_time crystal build $flags "$wrapper" -o "$base.timed" >>"$base.debug.times"
      printf 'require "%s"\nputs "edit 2"\n' "$rel" >"$wrapper"
      # shellcheck disable=SC2086
      CRYSTAL_CACHE_DIR="$cache" cpu_time crystal build $flags "$wrapper" -o "$base.timed" >>"$base.rebuild.times"
    done
  done
}

row() { # label stdlib cryaml format(G|K|s|KB)
  awk -v l="$1" -v s="$2" -v c="$3" -v f="$4" 'BEGIN {
    if (f == "G") printf "| %s | %.2fG | %.2fG | %+.2fG (%+.1f%%) |\n", l, s / 1e9, c / 1e9, (c - s) / 1e9, (c - s) * 100 / s
    else if (f == "K") printf "| %s | %.1fK | %.1fK | %+.1fK |\n", l, s / 1e3, c / 1e3, (c - s) / 1e3
    else if (f == "KB") printf "| %s | %d KB | %d KB | %+d KB |\n", l, s / 1024, c / 1024, (c - s) / 1024
    else printf "| %s | %s | %s | %+.2f s |\n", l, s, c, c - s
  }'
}

for p in "$@"; do
  if ! $reuse; then
    measure "$p" stdlib
    measure "$p" cryaml
    [ "$runs" -eq 0 ] || timings "$p"
  fi

  s="$out/$p-stdlib"
  c="$out/$p-cryaml"
  echo "### $p"
  echo
  echo "| | stdlib | cryaml | difference |"
  echo "| --- | ---: | ---: | ---: |"
  so=$(cat "$s.opt.count") sl=$(cat "$s.llc.count") co=$(cat "$c.opt.count") cl=$(cat "$c.llc.count")
  row "LLVM, release (opt + llc -O3)" $((so + sl)) $((co + cl)) G
  row "- opt -O3" "$so" "$co" G
  row "- llc -O3" "$sl" "$cl" G
  row "LLVM, debug (llc -O0)" "$(cat "$s.llc0.count")" "$(cat "$c.llc0.count")" G
  for stage in ir inl.ir opt.ir; do
    case "$stage" in
    ir) label="unoptimized" ;;
    inl.ir) label="after always-inline" ;;
    opt.ir) label="after -O3" ;;
    esac
    set -- $(ir_totals "$s.$stage.tsv") $(ir_totals "$c.$stage.tsv")
    row "IR instructions, $label: all" "$1" "$3" K
    row "IR instructions, $label: YAML::" "$2" "$4" K
  done
  if [ "$runs" -gt 0 ]; then
    for kind in release debug rebuild; do
      case "$kind" in
      release) label="release build, CPU s" ;;
      debug) label="debug build, CPU s" ;;
      rebuild) label="debug rebuild after edit, CPU s" ;;
      esac
      set -- $(min_median "$s.$kind.times") $(min_median "$c.$kind.times")
      row "$label, min" "$1" "$3" s
      row "$label, median of $runs" "$2" "$4" s
    done
  fi
  row "release binary, stripped" "$(wc -c <"$s.stripped")" "$(wc -c <"$c.stripped")" KB
  echo
done
