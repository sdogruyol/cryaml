# Performance

cryaml is faster than the libyaml binding on every workload measured, on all
four platforms, except one where they tie (`to_yaml` of a 1 KB config on
Linux aarch64, 0.99x).

## Method

- **Wall clock**: `crystal run bench/run.cr` builds `bench/bench.cr` twice
  with `--release` (stdlib `require "yaml"` on libyaml 0.2.5, and cryaml) and
  runs each operation for at least 0.5 s after a warm-up. Numbers below come
  from the [Bench workflow](../.github/workflows/bench.yml) on GitHub's hosted
  runners, 2026-10-09, Crystal 1.21.0. Hosted runners are shared machines;
  expect a few percent of noise.
- **Instructions**: callgrind on release builds, counting only the measured
  function, with GC disabled inside it. Deterministic, so it is what the
  optimization work was judged by.

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
| small config (1 KB) | parse | 1.33x | 1.39x | 1.67x | 1.42x |
| small config (1 KB) | pull | 1.72x | 1.76x | 2.12x | 2.20x |
| small config (1 KB) | nodes | 1.41x | 1.46x | 1.81x | 1.58x |
| small config (1 KB) | dump | 1.05x | 0.99x | 1.62x | 1.16x |
| helm values (50 KB, real) | parse | 1.80x | 1.95x | 2.32x | 1.74x |
| helm values (50 KB, real) | pull | 2.16x | 2.29x | 2.38x | 2.14x |
| helm values (50 KB, real) | nodes | 1.90x | 2.04x | 2.12x | 1.92x |
| helm values (50 KB, real) | dump | 1.07x | 1.03x | 1.90x | 1.34x |
| manifests (100 KB) | parse | 1.35x | 1.38x | 1.62x | 1.48x |
| manifests (100 KB) | pull | 1.49x | 1.46x | 2.20x | 1.76x |
| manifests (100 KB) | nodes | 1.40x | 1.39x | 1.96x | 1.48x |
| manifests (100 KB) | dump | 1.08x | 1.04x | 1.33x | 1.22x |
| manifests (1 MB) | parse | 1.36x | 1.36x | 1.55x | 1.78x |
| manifests (1 MB) | pull | 1.50x | 1.51x | 1.67x | 1.89x |
| manifests (1 MB) | nodes | 1.43x | 1.44x | 1.82x | 1.90x |
| manifests (1 MB) | dump | 1.10x | 1.09x | 1.22x | 1.43x |
| deep nesting (300 levels) | parse | 2.16x | 2.21x | 3.09x | 2.07x |
| deep nesting (300 levels) | pull | 2.70x | 2.67x | 3.19x | 2.90x |
| deep nesting (300 levels) | nodes | 2.42x | 2.38x | 2.35x | 4.68x |
| flow heavy (200 KB) | parse | 1.38x | 1.39x | 1.25x | 1.65x |
| flow heavy (200 KB) | pull | 1.50x | 1.49x | 1.82x | 1.90x |
| flow heavy (200 KB) | nodes | 1.47x | 1.46x | 1.83x | 1.66x |
| flow heavy (200 KB) | dump | 1.10x | 1.02x | 1.18x | 1.29x |

`YAML.parse_all` is 1.25x-3.09x faster although the code that builds
`YAML::Any` is the same on both sides, so the whole difference comes from what
sits under `PullParser`: the engine, or libyaml plus the binding. The emitter
gains the least (0.99x-1.90x).

## Instructions (callgrind, lower is better)

| Workload | cryaml before tuning | cryaml now | libyaml |
| --- | ---: | ---: | ---: |
| manifests 1 MB, pull walk | 226.6M | 140.3M | 191.9M |
| flow 200 KB, pull walk | 82.2M | 54.4M | 69.2M |
| deep, pull walk | 76.1M | 31.9M | 73.5M |
| helm values, `YAML.parse_all` | 4.46M | 2.42M | 4.48M |
| small config, `YAML.parse_all` x200 | 52.5M | 37.5M | 47.9M |
| manifests 100 KB, `Nodes.parse_all` | 26.2M | 17.5M | 23.8M |
| `to_yaml` of manifests 100 KB | 25.5M | 19.97M | 21.14M |
| `to_yaml` of helm values | 1.59M | 1.18M | 1.30M |
| `to_yaml` of flow 200 KB | 81.0M | 72.1M | 70.8M |

The last row is the one where cryaml runs more instructions, about 2%. About
half of each total is the shared `Any#to_yaml` code, which is the same on both
sides, so the whole difference (about 1.3M here, 2.1M at 0.1.1) is in the
emitter.
How the engine got there is in [ARCHITECTURE.md](ARCHITECTURE.md#performance-techniques).

## Memory

Peak RSS of a fresh process running `YAML.parse_all` five times is the same
on both sides (Linux x86_64, `VmHWM` via `bin/bench-* --rss`: 31.3-31.4 MB on
both for the 1 MB manifests, three runs each); individual runs can move by a
few MB depending on when the GC collects.

Crystal heap allocated per `YAML.parse_all` is slightly higher with cryaml
(Linux x86_64, KB):

| Workload | stdlib (libyaml) | cryaml |
| --- | ---: | ---: |
| small config | 9.0 | 12.4 |
| helm values | 78.7 | 127.8 |
| manifests 100 KB | 1013.0 | 1063.6 |
| manifests 1 MB | 9979.8 | 10030.3 |
| deep nesting | 1851.0 | 2021.8 |
| flow heavy | 3948.8 | 4009.3 |

libyaml's own buffers are malloc'ed outside the GC and don't show up on the
stdlib side; cryaml's equivalents (a 16 KB raw chunk and a decode buffer of
up to 48 KB, smaller for short strings) are ordinary GC memory, so the
difference is roughly constant. On the bare event walk cryaml creates each
scalar's `String` while scanning, the binding only when `PullParser#value` is
called; code that skips values pays for strings it never reads.

## Reproduce

```sh
crystal run bench/run.cr          # both implementations, release builds, Markdown tables
bin/bench-cryaml                  # one implementation, human-readable
bin/bench-cryaml --rss "manifests (1 MB)" parse
```

Set `CRYAML_LIBYAML_PREFIX` to link a specific libyaml build on the stdlib
side (Crystal's macOS tarball bundles an older libyaml).
