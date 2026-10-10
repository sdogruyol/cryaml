# Performance

cryaml is faster than the libyaml binding on every workload and operation
measured, on all four platforms: `YAML.parse_all` 1.16x-3.81x, the bare event
walk 1.81x-6.02x, `YAML::Nodes.parse_all` 1.65x-4.77x and `to_yaml`
1.29x-1.87x. It runs fewer instructions on every row, between 17% and 71% of
libyaml's.

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
| small config (1 KB) | parse | 1.85x | 1.83x | 1.90x | 2.31x |
| small config (1 KB) | pull | 3.07x | 2.69x | 4.24x | 3.81x |
| small config (1 KB) | nodes | 2.08x | 1.90x | 2.14x | 2.26x |
| small config (1 KB) | dump | 1.43x | 1.42x | 1.87x | 1.78x |
| helm values (50 KB, real) | parse | 2.33x | 2.59x | 2.88x | 2.53x |
| helm values (50 KB, real) | pull | 3.12x | 3.29x | 3.51x | 3.20x |
| helm values (50 KB, real) | nodes | 2.66x | 2.82x | 2.33x | 2.63x |
| helm values (50 KB, real) | dump | 1.67x | 1.59x | 1.54x | 1.29x |
| manifests (100 KB) | parse | 1.81x | 1.81x | 1.69x | 1.16x |
| manifests (100 KB) | pull | 2.74x | 2.37x | 1.96x | 2.05x |
| manifests (100 KB) | nodes | 2.13x | 1.93x | 2.25x | 2.05x |
| manifests (100 KB) | dump | 1.51x | 1.48x | 1.68x | 1.55x |
| manifests (1 MB) | parse | 1.79x | 1.78x | 1.77x | 1.61x |
| manifests (1 MB) | pull | 2.63x | 2.36x | 2.06x | 2.56x |
| manifests (1 MB) | nodes | 2.13x | 1.87x | 2.08x | 2.07x |
| manifests (1 MB) | dump | 1.54x | 1.42x | 1.69x | 1.30x |
| deep nesting (300 levels) | parse | 3.36x | 3.74x | 3.81x | 3.10x |
| deep nesting (300 levels) | pull | 5.83x | 6.02x | 6.01x | 4.56x |
| deep nesting (300 levels) | nodes | 4.26x | 4.40x | 4.77x | 2.81x |
| flow heavy (200 KB) | parse | 1.81x | 1.90x | 1.30x | 1.90x |
| flow heavy (200 KB) | pull | 2.78x | 2.73x | 1.81x | 2.75x |
| flow heavy (200 KB) | nodes | 2.29x | 2.17x | 1.65x | 2.24x |
| flow heavy (200 KB) | dump | 1.46x | 1.38x | 1.63x | 1.59x |

`parse` and `nodes` include the stdlib's own `YAML::Any`/`Nodes` building,
which is the same code on both sides; the difference comes from what sits
under `PullParser` and `Builder`: the engine, or libyaml plus the binding.

## Instructions (callgrind, Linux x86_64, lower is better)

| Workload | Operation | libyaml | cryaml | cryaml/libyaml |
| --- | --- | ---: | ---: | ---: |
| small config (1 KB) | parse | 0.24M | 0.13M | 0.553 |
| small config (1 KB) | pull | 0.17M | 0.08M | 0.463 |
| small config (1 KB) | nodes | 0.21M | 0.11M | 0.528 |
| small config (1 KB) | dump | 0.19M | 0.13M | 0.683 |
| helm values (50 KB, real) | parse | 4.43M | 1.76M | 0.397 |
| helm values (50 KB, real) | pull | 3.85M | 1.31M | 0.340 |
| helm values (50 KB, real) | nodes | 4.11M | 1.50M | 0.365 |
| helm values (50 KB, real) | dump | 1.25M | 0.73M | 0.585 |
| manifests (100 KB) | parse | 28.37M | 15.77M | 0.556 |
| manifests (100 KB) | pull | 19.32M | 8.42M | 0.436 |
| manifests (100 KB) | nodes | 24.08M | 12.10M | 0.503 |
| manifests (100 KB) | dump | 21.07M | 13.72M | 0.651 |
| manifests (1 MB) | parse | 281.31M | 155.94M | 0.554 |
| manifests (1 MB) | pull | 191.96M | 83.88M | 0.437 |
| manifests (1 MB) | nodes | 238.83M | 119.70M | 0.501 |
| manifests (1 MB) | dump | 209.91M | 136.36M | 0.650 |
| deep nesting (300 levels) | parse | 82.00M | 20.06M | 0.245 |
| deep nesting (300 levels) | pull | 73.53M | 12.79M | 0.174 |
| deep nesting (300 levels) | nodes | 78.24M | 16.74M | 0.214 |
| flow heavy (200 KB) | parse | 106.35M | 62.25M | 0.585 |
| flow heavy (200 KB) | pull | 68.85M | 31.33M | 0.455 |
| flow heavy (200 KB) | nodes | 86.74M | 44.36M | 0.511 |
| flow heavy (200 KB) | dump | 70.76M | 50.02M | 0.707 |

How the engine got there is in
[ARCHITECTURE.md](ARCHITECTURE.md#performance-techniques). The plain port,
before any of it, ran up to 22% more instructions than libyaml (the
`review/plain-port` branch keeps that version for review).

## Memory

Peak RSS of a fresh process running `YAML.parse_all` five times is the same
within GC timing (Linux x86_64, MB):

| Workload | stdlib (libyaml) | cryaml |
| --- | ---: | ---: |
| small config (1 KB) | 10.1 | 11.0 |
| helm values (50 KB, real) | 11.6 | 11.1 |
| manifests (100 KB) | 14.4 | 14.6 |
| manifests (1 MB) | 30.2 | 30.1 |
| deep nesting (300 levels) | 17.7 | 17.8 |
| flow heavy (200 KB) | 23.0 | 23.0 |

Crystal heap allocated per operation (Linux x86_64, KB). libyaml's own state
and buffers are malloc'ed outside the GC and not counted on the stdlib side;
cryaml's are ordinary GC memory:

| Workload | Operation | stdlib | cryaml |
| --- | --- | ---: | ---: |
| small config (1 KB) | parse | 9.0 | 10.1 |
| small config (1 KB) | pull | 0.9 | 4.0 |
| small config (1 KB) | nodes | 10.2 | 11.4 |
| small config (1 KB) | dump | 11.5 | 13.1 |
| helm values (50 KB, real) | parse | 78.7 | 79.4 |
| helm values (50 KB, real) | pull | 0.9 | 15.2 |
| helm values (50 KB, real) | nodes | 70.7 | 71.4 |
| helm values (50 KB, real) | dump | 73.1 | 90.8 |
| manifests (100 KB) | parse | 1013.1 | 1014.4 |
| manifests (100 KB) | pull | 10.6 | 224.8 |
| manifests (100 KB) | nodes | 1051.4 | 1052.7 |
| manifests (100 KB) | dump | 1318.2 | 1336.1 |
| manifests (1 MB) | parse | 9979.5 | 9981.4 |
| manifests (1 MB) | pull | 95.0 | 2207.6 |
| manifests (1 MB) | nodes | 10391.2 | 10392.4 |
| manifests (1 MB) | dump | 14460.3 | 14478.1 |
| deep nesting (300 levels) | parse | 1850.9 | 1885.1 |
| deep nesting (300 levels) | pull | 0.9 | 161.3 |
| deep nesting (300 levels) | nodes | 1130.8 | 1165.0 |
| flow heavy (200 KB) | parse | 3948.9 | 3959.0 |
| flow heavy (200 KB) | pull | 0.9 | 857.1 |
| flow heavy (200 KB) | nodes | 3929.1 | 3939.4 |
| flow heavy (200 KB) | dump | 4937.2 | 4955.0 |

- `parse` and `nodes` are within 0.2% on the large inputs: what's left is
  about 1 KB of scanner and parser state per parser (libyaml mallocs its
  own) and, for the deep document, the token queue that its runs of 300
  BLOCK-END tokens grow. A `String` in UTF-8 is validated in place, so no
  decode buffer is allocated for it.
- `pull` walks the events without reading values. cryaml creates each
  scalar's `String` while scanning; the binding creates it only when
  `PullParser#value` is called. Making cryaml's strings lazy cut the walk
  further but made `parse` and `nodes`, which read every value, 0.5-1.6%
  slower, so values stay eager.
- `dump`: the emitter's output buffer is GC memory here and malloc'ed by
  libyaml. It starts at 1 KB and grows to libyaml's 16 KB only when that
  fills up (flushes still happen exactly where libyaml's would), so small
  outputs allocate about 1.6 KB more than the binding and larger ones about
  18 KB more.

## Compile time and binary size

A small program using `YAML::Serializable`, `YAML.parse` and `to_yaml`
(Linux x86_64, cold cache, CPU user time of `crystal build`):

| | stdlib (libyaml) | cryaml |
| --- | ---: | ---: |
| release build | 7.3-7.5 s | 9.0-9.3 s |
| debug build | 5.3 s | 5.9 s |
| release binary, stripped | 798 KB + libyaml.so 133 KB | 925 KB |
| release binary, with debug info | 1.74 MB | 2.10 MB |

Almost all of the extra release time is LLVM optimizing the engine, which is
Crystal code in the program instead of a prebuilt C library; inlining was
tuned to cut it without slowing any row above. A program that only
`require`s cryaml compiles exactly like one that only `require`s `yaml`:
Crystal compiles only what is called.

## Reproduce

```sh
scripts/instructions.sh           # callgrind table (needs valgrind and libyaml 0.2.5)
crystal run bench/run.cr          # wall clock, both implementations, Markdown tables
bin/bench-cryaml                  # one implementation, human-readable
bin/bench-cryaml --rss "manifests (1 MB)" parse
```

Set `CRYAML_LIBYAML_PREFIX` to link a specific libyaml build on the stdlib
side (Crystal's macOS tarball bundles an older libyaml).
