# Performance

cryaml is faster than the libyaml binding on every workload and operation
measured, on all four platforms: `YAML.parse_all` 1.75x-4.41x, the bare event
walk 2.41x-10.36x, `YAML::Nodes.parse_all` 1.19x-5.62x and `to_yaml`
1.33x-3.93x. It runs fewer instructions on every row, between 15% and 71% of
libyaml's. The cost is compile time: release builds of a program that uses
YAML take about 1-1.3 s longer (see the end of this page).

## Method

- **Wall clock**: `crystal run bench/run.cr` builds `bench/bench.cr` twice
  with `--release` (stdlib `require "yaml"` on libyaml 0.2.5, and cryaml) and
  runs each operation for at least 0.5 s after a warm-up. Numbers below come
  from the [Bench workflow](../.github/workflows/bench.yml) on GitHub's hosted
  runners, 2026-10-11, Crystal 1.21.0. Hosted runners are shared machines;
  expect some noise.
- **Instructions**: `scripts/instructions.sh` runs every operation once under
  callgrind on release builds of both sides, counting only the measured call,
  with the GC disabled inside it. Deterministic, so it is what every
  optimization was judged by.

| Workload | Size | What it is |
| --- | ---: | --- |
| small config | 1 KB | shard.yml / docker-compose style config |
| helm values | 50 KB | `samples/helm-nginx-values.yaml` (real file, comment heavy) |
| manifests | 100 KB, 1 MB | Kubernetes multi-document manifests with anchors, merge keys, flow maps, folded scalars |
| deep nesting | 1.25 MB | 20 trees of alternating block mappings and sequences, about 300 collections deep |
| flow heavy | 200 KB | JSON-like flow sequence of flow mappings |

Operations: `parse` = `YAML.parse_all`; `pull` = walk every `PullParser`
event (tokenizer and parser alone); `nodes` = `YAML::Nodes.parse_all`;
`dump` = `to_yaml` of the parsed value (emitter). The deep document exceeds
`Builder#max_nesting` (99) in both implementations, so it has no `dump` row.

## Throughput, cryaml / stdlib (higher means cryaml is faster)

| Workload | Operation | Linux x86_64 | Linux aarch64 | macOS arm64 | macOS x86_64 |
| --- | --- | ---: | ---: | ---: | ---: |
| small config (1 KB) | parse | 1.91x | 1.87x | 1.95x | 3.27x |
| small config (1 KB) | pull | 3.54x | 3.29x | 10.36x | 5.46x |
| small config (1 KB) | nodes | 2.18x | 2.01x | 2.99x | 5.62x |
| small config (1 KB) | dump | 1.38x | 1.44x | 1.47x | 3.93x |
| helm values (50 KB, real) | parse | 2.36x | 2.61x | 2.63x | 3.71x |
| helm values (50 KB, real) | pull | 3.25x | 3.65x | 3.95x | 4.22x |
| helm values (50 KB, real) | nodes | 2.69x | 2.86x | 2.92x | 4.51x |
| helm values (50 KB, real) | dump | 1.59x | 1.56x | 2.30x | 2.60x |
| manifests (100 KB) | parse | 1.82x | 1.81x | 2.42x | 2.73x |
| manifests (100 KB) | pull | 3.18x | 2.89x | 3.62x | 2.80x |
| manifests (100 KB) | nodes | 2.17x | 1.94x | 2.32x | 1.19x |
| manifests (100 KB) | dump | 1.42x | 1.44x | 1.91x | 1.35x |
| manifests (1 MB) | parse | 1.84x | 1.80x | 2.10x | 4.41x |
| manifests (1 MB) | pull | 3.18x | 2.91x | 3.40x | 4.38x |
| manifests (1 MB) | nodes | 2.13x | 1.95x | 2.37x | 2.38x |
| manifests (1 MB) | dump | 1.33x | 1.41x | 1.60x | 1.81x |
| deep nesting (300 levels) | parse | 3.37x | 3.73x | 4.54x | 3.22x |
| deep nesting (300 levels) | pull | 5.75x | 6.81x | 7.44x | 4.96x |
| deep nesting (300 levels) | nodes | 4.14x | 4.44x | 5.44x | 3.16x |
| flow heavy (200 KB) | parse | 1.87x | 1.89x | 1.80x | 1.75x |
| flow heavy (200 KB) | pull | 3.29x | 3.43x | 3.30x | 2.41x |
| flow heavy (200 KB) | nodes | 2.28x | 2.14x | 2.44x | 1.98x |
| flow heavy (200 KB) | dump | 1.40x | 1.33x | 1.41x | 1.38x |

The macOS x86_64 runner is the noisiest (compare its two manifests rows);
the Linux columns are the most stable.

`parse` and `nodes` include the stdlib's own `YAML::Any`/`Nodes` building,
which is the same code on both sides; the difference comes from what sits
under `PullParser` and `Builder`: the engine, or libyaml plus the binding.

## Instructions (callgrind, Linux x86_64, lower is better)

| Workload | Operation | libyaml | cryaml | cryaml/libyaml |
| --- | --- | ---: | ---: | ---: |
| small config (1 KB) | parse | 0.24M | 0.13M | 0.542 |
| small config (1 KB) | pull | 0.17M | 0.07M | 0.400 |
| small config (1 KB) | nodes | 0.21M | 0.11M | 0.510 |
| small config (1 KB) | dump | 0.19M | 0.12M | 0.663 |
| helm values (50 KB, real) | parse | 4.43M | 1.70M | 0.384 |
| helm values (50 KB, real) | pull | 3.85M | 1.20M | 0.313 |
| helm values (50 KB, real) | nodes | 4.11M | 1.44M | 0.351 |
| helm values (50 KB, real) | dump | 1.25M | 0.73M | 0.580 |
| manifests (100 KB) | parse | 28.37M | 15.36M | 0.541 |
| manifests (100 KB) | pull | 19.32M | 7.24M | 0.375 |
| manifests (100 KB) | nodes | 24.08M | 11.68M | 0.485 |
| manifests (100 KB) | dump | 21.05M | 13.76M | 0.654 |
| manifests (1 MB) | parse | 281.31M | 151.91M | 0.540 |
| manifests (1 MB) | pull | 191.96M | 71.71M | 0.374 |
| manifests (1 MB) | nodes | 238.83M | 115.55M | 0.484 |
| manifests (1 MB) | dump | 209.91M | 136.83M | 0.652 |
| deep nesting (300 levels) | parse | 82.00M | 19.15M | 0.233 |
| deep nesting (300 levels) | pull | 73.53M | 11.37M | 0.155 |
| deep nesting (300 levels) | nodes | 78.24M | 15.81M | 0.202 |
| flow heavy (200 KB) | parse | 106.35M | 60.62M | 0.570 |
| flow heavy (200 KB) | pull | 68.85M | 25.99M | 0.377 |
| flow heavy (200 KB) | nodes | 86.74M | 42.68M | 0.492 |
| flow heavy (200 KB) | dump | 70.87M | 50.14M | 0.707 |

How the engine got there is in
[ARCHITECTURE.md](ARCHITECTURE.md#performance-techniques). The plain port,
before any of it, ran up to 22% more instructions than libyaml (the
`review/plain-port` branch keeps that version for review).

## Memory

Peak RSS of a fresh process running `YAML.parse_all` five times is the same
within GC timing (Linux x86_64, MB). It is bimodal on both sides: the 1 MB
manifests peak at about 31 or 49 MB depending on when the heap grows (five
local runs each of the stdlib, cryaml 0.2.0 and this version all showed
both).

| Workload | stdlib (libyaml) | cryaml |
| --- | ---: | ---: |
| small config (1 KB) | 11.3 | 10.9 |
| helm values (50 KB, real) | 11.6 | 11.6 |
| manifests (100 KB) | 14.4 | 14.2 |
| manifests (1 MB) | 30.2 | 47.9 |
| deep nesting (300 levels) | 20.0 | 18.6 |
| flow heavy (200 KB) | 23.1 | 23.2 |

Crystal heap allocated per operation (Linux x86_64, KB). libyaml's own state
and buffers are malloc'ed outside the GC and not counted on the stdlib side;
cryaml's are ordinary GC memory:

| Workload | Operation | stdlib | cryaml |
| --- | --- | ---: | ---: |
| small config (1 KB) | parse | 9.0 | 9.8 |
| small config (1 KB) | pull | 0.9 | 1.9 |
| small config (1 KB) | nodes | 10.3 | 11.0 |
| small config (1 KB) | dump | 11.5 | 12.8 |
| helm values (50 KB, real) | parse | 78.7 | 79.2 |
| helm values (50 KB, real) | pull | 0.9 | 1.5 |
| helm values (50 KB, real) | nodes | 70.7 | 71.2 |
| helm values (50 KB, real) | dump | 73.1 | 90.5 |
| manifests (100 KB) | parse | 1013.0 | 1014.1 |
| manifests (100 KB) | pull | 10.6 | 19.5 |
| manifests (100 KB) | nodes | 1051.4 | 1052.4 |
| manifests (100 KB) | dump | 1318.3 | 1335.8 |
| manifests (1 MB) | parse | 9979.4 | 9980.6 |
| manifests (1 MB) | pull | 95.1 | 174.5 |
| manifests (1 MB) | nodes | 10391.3 | 10392.0 |
| manifests (1 MB) | dump | 14460.2 | 14478.0 |
| deep nesting (300 levels) | parse | 1850.9 | 1873.3 |
| deep nesting (300 levels) | pull | 0.9 | 23.2 |
| deep nesting (300 levels) | nodes | 1130.8 | 1153.2 |
| flow heavy (200 KB) | parse | 3948.9 | 3958.9 |
| flow heavy (200 KB) | pull | 0.9 | 11.0 |
| flow heavy (200 KB) | nodes | 3929.3 | 3939.1 |
| flow heavy (200 KB) | dump | 4937.3 | 4954.5 |

- `parse` and `nodes` are within 0.1% on the large inputs. What's left is
  about 1 KB of scanner and parser state per parser (libyaml mallocs its
  own) and, for the deep document, the stacks that grow to its 300 levels.
  A `String` in UTF-8 is validated in place, so no decode buffer is
  allocated for it.
- `pull` walks the events without reading values. For `String` input, an
  ASCII scalar that needs no folding or escapes stays in the input until
  `PullParser#value` asks for it, like the binding, which builds every value
  only then. Once a program reads a value, the scanner goes back to building
  strings as it scans (building them later cost `parse` and `nodes`
  0.5-1.3%), so programs that read values pay nothing for this. Folded or
  escaped scalars and `IO` input are built as they are scanned.
- `dump`: the emitter's output buffer is GC memory here and malloc'ed by
  libyaml. It starts at 1 KB and grows to libyaml's 16 KB only when that
  fills up (flushes still happen exactly where libyaml's would), so small
  outputs allocate about 1.3 KB more than the binding and larger ones about
  17 KB more.

## Compile time and binary size

The engine is Crystal code compiled into every program that uses it, where
the binding links a prebuilt C library, so such a program takes longer to
build. A program that only `require`s cryaml compiles exactly like one that
only `require`s `yaml`: Crystal compiles only what is called.

`scripts/compile_cost.sh` measures three programs on both sides:
`serializable` (`bench/compile/serializable.cr`: `YAML::Serializable`,
`YAML.parse` and `to_yaml`), `parse` (`bench/compile/parse.cr`: only
`YAML.parse` of a `String`) and `bench` (`bench/bench.cr`). Almost all of
the extra release time is LLVM optimizing the engine, so compile-time
changes are judged by a deterministic count of that work: the instructions
(cachegrind) that `opt -O3` and `llc -O3` execute on the program's
unoptimized bitcode, which is what `--release` hands to LLVM
(`crystal build --release --emit llvm-bc` writes the module before it is
optimized). Debug builds run no IR pass (not even the always-inliner), only
codegen, which `llc -O0` on the debug build's bitcode
(`--single-module --emit llvm-bc`) counts. The script also reports the IR
size (all functions and `YAML::` ones, which include the stdlib's YAML code
both sides share), CPU times of cold release and debug builds and of a
debug rebuild after an edit of the program, and binary sizes.

Linux x86_64, Crystal 1.21.0 (LLVM 20), counts from LLVM 21's `opt` and
`llc`, CPU time (user + sys) of `crystal build` with an empty cache, median
of 3:

| Program | | stdlib (libyaml) | cryaml |
| --- | --- | ---: | ---: |
| serializable | LLVM work, release | 52.4G | 60.2G |
| serializable | LLVM work, debug | 9.8G | 11.5G |
| serializable | release build | 9.0 s | 10.4 s |
| serializable | debug build | 9.2 s | 9.8 s |
| serializable | debug rebuild after an edit | 1.4 s | 1.4 s |
| serializable | release binary, stripped | 799 KB + libyaml.so 133 KB | 891 KB |
| parse | LLVM work, release | 41.7G | 46.8G |
| parse | LLVM work, debug | 8.7G | 9.9G |
| parse | release build | 7.4 s | 8.0 s |
| bench | LLVM work, release | 58.9G | 66.5G |
| bench | LLVM work, debug | 11.6G | 13.3G |
| bench | release build | 9.5 s | 10.8 s |

cryaml's extra release LLVM work for `serializable` was +11.6G in 0.2.0 and
is +7.8G now (+14.8% over the binding), while parse, pull and nodes got
faster still and dump stayed within 0.3%. What remains is mostly the engine
itself: compiling all of libyaml's C with `gcc -O2` takes about 1.7 s of CPU
here, a cost the binding's users pay once when libyaml is built. Removing
every `@[AlwaysInline]` would save another 1.1G but make parsing 6-59%
slower.

Wall and CPU times vary by several percent between runs on a busy machine;
the LLVM count of a given program doesn't (±0.02%). Any edit of the engine,
even one that removes code, moves LLVM's inlining decisions elsewhere, so
a change shows its effect only beyond about ±0.05G.

What makes that work: LLVM inlines `@[AlwaysInline]` methods (and the
methods it chooses to inline) at every call, so a primitive called from
fifty places is optimized fifty times, and a big function called once
costs less than a small one called often. Crystal compiles a method once
per combination of argument types and of keyword arguments, which costs
debug builds most (`Event` and `Token` construction is positional for
that reason). Merging calls of a state function into one call with a
runtime flag, or leaving a primitive to LLVM's own inliner, has made both
compilation and the parser slower in experiments: what LLVM inlines and
constant-folds there is what keeps the parser fast.

LLVM also optimizes a function before it inlines it into its callers, and
then each caller with the inlined code: a method with one caller is
optimized once on its own and once more in every caller it ends up in, one
level after the other (the plain scalar scanner was optimized four times).
The scanner's fetch and scan methods, the reader's decoding steps and the
emitter's scalar writers are therefore `@[AlwaysInline]` ("one caller"),
which inlines them before anything is optimized (-0.96G). The event
parser's states are not: inlined that early into one big function, the
calls they make land in branches LLVM deems cold, where it doesn't inline
them, and parsing got 3-6% slower. For the same reason the scanner builds
its strings with `String.new` written out rather than called. A call that
omits a default argument compiles to a method of its own without the
`@[AlwaysInline]`, so the always-inlined methods with an optional argument
are pairs of overloads instead.

## Reproduce

```sh
scripts/instructions.sh           # callgrind table (needs valgrind and libyaml 0.2.5)
scripts/compile_cost.sh           # compile cost tables (needs valgrind, LLVM tools and libyaml)
crystal run bench/run.cr          # wall clock, both implementations, Markdown tables
bin/bench-cryaml                  # one implementation, human-readable
bin/bench-cryaml --rss "manifests (1 MB)" parse
```

Set `CRYAML_LIBYAML_PREFIX` to link a specific libyaml build on the stdlib
side (Crystal's macOS tarball bundles an older libyaml).
