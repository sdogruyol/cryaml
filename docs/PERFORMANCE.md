# Performance

Measured 2026-10-09 with `crystal run bench/run.cr`: Crystal 1.21.0, LLVM 20,
`--release`, Linux 7.0 x86_64 (12-vCPU QEMU VM), libyaml 0.2.5 on the stdlib
side. Each cell runs for at least 0.5 s after a warm-up; run-to-run noise on
this machine is around ±5%.

## Workloads

| Workload | Size | What it is |
| --- | ---: | --- |
| small config | 1 KB | shard.yml / docker-compose style config |
| helm values | 50 KB | `samples/helm-nginx-values.yaml` (real file, comment heavy) |
| manifests | 100 KB, 1 MB | Kubernetes multi-document manifests with anchors, merge keys, flow maps, folded scalars |
| deep nesting | 1.25 MB | 20 trees of alternating block mappings and sequences, about 300 collections deep (indentation runs to 600 columns) |
| flow heavy | 200 KB | JSON-like flow sequence of flow mappings |

Operations: `parse` = `YAML.parse_all`; `pull` = walk every `PullParser`
event (the tokenizer and parser alone); `nodes` = `YAML::Nodes.parse_all`;
`dump` = `to_yaml` of the parsed value (emitter). The deep document exceeds
`Builder#max_nesting` (99) in both implementations, so it has no `dump` row.

## Throughput, MB/s (higher is better)

| Workload | Operation | stdlib (libyaml) | cryaml | cryaml / stdlib |
| --- | --- | ---: | ---: | ---: |
| small config | parse | 55.06 | 50.87 | 0.92x |
| small config | pull | 73.21 | 76.70 | 1.05x |
| small config | nodes | 68.03 | 64.62 | 0.95x |
| small config | dump | 76.67 | 62.29 | 0.81x |
| helm values | parse | 226.41 | 228.93 | 1.01x |
| helm values | pull | 293.58 | 307.97 | 1.05x |
| helm values | nodes | 249.64 | 251.72 | 1.01x |
| helm values | dump | 656.98 | 513.67 | 0.78x |
| manifests 100 KB | parse | 53.49 | 49.37 | 0.92x |
| manifests 100 KB | pull | 108.15 | 85.78 | 0.79x |
| manifests 100 KB | nodes | 70.64 | 58.07 | 0.82x |
| manifests 100 KB | dump | 84.01 | 64.20 | 0.76x |
| manifests 1 MB | parse | 59.48 | 57.53 | 0.97x |
| manifests 1 MB | pull | 111.69 | 97.61 | 0.87x |
| manifests 1 MB | nodes | 79.77 | 73.75 | 0.92x |
| manifests 1 MB | dump | 75.12 | 67.97 | 0.90x |
| deep nesting | parse | 342.84 | 374.41 | 1.09x |
| deep nesting | pull | 453.22 | 500.70 | 1.10x |
| deep nesting | nodes | 389.73 | 444.50 | 1.14x |
| flow heavy | parse | 35.81 | 33.91 | 0.95x |
| flow heavy | pull | 66.54 | 53.86 | 0.81x |
| flow heavy | nodes | 41.17 | 41.98 | 1.02x |
| flow heavy | dump | 50.92 | 50.49 | 0.99x |

Every cell is between 0.76x and 1.14x of libyaml. For `YAML.parse_all`, what
applications actually call, the range is 0.92x to 1.09x: most of the time
goes into building `YAML::Any` values, which is the same Crystal code in both.
The widest gaps are the raw event walk on token-dense input and the emitter.

## Memory

Peak RSS of a fresh process running `YAML.parse_all` five times (MB, lower is
better):

| Workload | stdlib (libyaml) | cryaml |
| --- | ---: | ---: |
| small config | 10.5 | 10.2 |
| helm values | 10.4 | 10.4 |
| manifests 100 KB | 14.5 | 14.7 |
| manifests 1 MB | 30.7 | 30.6 |
| deep nesting | 18.3 | 18.6 |
| flow heavy | 27.5 | 23.8 |

Crystal heap allocated per `YAML.parse_all` (KB; libyaml's malloc'ed buffers
are invisible to the GC and not included on the stdlib side):

| Workload | stdlib (libyaml) | cryaml |
| --- | ---: | ---: |
| small config | 9.0 | 12.3 |
| helm values | 78.7 | 127.9 |
| manifests 100 KB | 1013.0 | 1063.8 |
| manifests 1 MB | 9979.9 | 10030.5 |
| deep nesting | 1851.0 | 2014.1 |
| flow heavy | 3948.9 | 4009.4 |

The engine's own buffers are bounded like libyaml's (a 16 KB raw chunk and a
48 KB decode buffer, smaller for short strings), so the extra heap per parse is
roughly constant: about 50 KB on a 1 MB document. Everything is ordinary GC
memory; there are no C-side buffers.

The one structural difference is on the bare event walk: cryaml creates each
scalar's `String` while scanning, the libyaml binding only when
`PullParser#value` is called. Code that skips values (`PullParser#skip`) pays
for strings it never reads; every API that builds values reads them anyway.

## Reproduce

```sh
crystal run bench/run.cr          # builds both binaries with --release, prints these tables
bin/bench-cryaml                  # one implementation, human-readable
bin/bench-cryaml --rss "manifests (1 MB)" parse
```
