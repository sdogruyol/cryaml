# Changelog

## Unreleased

- `shard.yml` declares `MIT AND Apache-2.0 WITH Swift-exception`: the files
  adapted from Crystal's stdlib keep their license (see NOTICE.md).
- The README says which stdlib version `src/yaml.cr`, `PullParser` and
  `Builder` are adapted from, and how to check a newer compiler for drift.
- Faster: `YAML.parse_all` 1.16x-3.81x the libyaml binding's speed (was
  1.25x-3.09x), the event walk 1.81x-6.02x, `to_yaml` 1.29x-1.87x (was
  0.99x-1.90x), on Linux x86_64/aarch64 and macOS arm64/x86_64. Every
  benchmark row now runs 17-71% of libyaml's instructions.
- `to_yaml` of a small document allocates 15 KB less: the output buffer
  starts at 1 KB and grows to 16 KB only when needed (flushes unchanged).
- Parsing allocates about the same as the binding (UTF-8 `String` input is
  validated in place instead of being copied).
- Inlining tuned for compile time: release builds of a small program using
  YAML take about 1.7 s longer than with the binding (was about 2.3 s), and
  the stripped binary is about the binding's plus libyaml.so.

## 0.1.1 (2026-10-10)

### Fixed

- `require "yaml"` (or `big/yaml`, `uri/yaml`, `uuid/yaml`) after
  `require "cryaml"` compiled and silently replaced cryaml's `PullParser`
  and `Builder` with the libyaml binding. It now fails with an explanation,
  in either order.
- Scalars longer than 1 GiB raised `OverflowError` while scanning; they now
  parse like with libyaml, up to `Int32::MAX` bytes.
- A `YAML::Builder` stream raised `OverflowError` after 2^31 line breaks.
- Scanned tokens and emitted events stayed reachable from their queues after
  being consumed, keeping large scalars alive as long as the parser or
  builder.
- The `cryaml/uri` and `cryaml/uuid` docs pointed at the stdlib requires.

## 0.1.0 (2026-10-10)

First release: the stdlib `YAML` module on a pure Crystal engine.

### Added

- Pure Crystal port of libyaml 0.2.5: reader (UTF-8/UTF-16, BOM, 16 KiB
  chunked decoding), scanner, parser and emitter. No C code, no libyaml.
- `require "cryaml"` loads the stdlib's own `YAML::Any`, `YAML::Nodes`,
  schemas and `YAML::Serializable` from the installed compiler and replaces
  only `PullParser`, `Builder` and the libyaml binding.
- `cryaml/big`, `cryaml/uri`, `cryaml/uuid`: the stdlib's YAML extensions
  without `require "yaml"`.
- `shim/yaml.cr`: put `lib/cryaml/shim` first in `CRYSTAL_PATH` and every
  `require "yaml"`, including in dependencies, loads cryaml.

### Differences from the stdlib's libyaml binding

- Behavior matches libyaml 0.2.5 on every platform. The stdlib links whatever
  libyaml is installed; Crystal 1.21.0's macOS tarball embeds 0.1.6.
- Malformed UTF-8 passed to `YAML::Builder` (including tags whose
  `%`-escapes decode to it) raises `YAML::Error` instead of re-emitting a
  stale event.
- `YAML::PullParser` and `YAML::Builder` have no `finalize`; `close` is a
  no-op.
- `YAML.libyaml_version` returns 0.2.5, the reproduced release.
- Flow collections nested tens of thousands deep (with
  `PullParser#max_nesting` raised) scan in linear time; libyaml's simple-key
  check is quadratic there.
- Loading the stdlib's `yaml` next to cryaml fails to compile.

### Performance

Faster than the libyaml binding on every measured workload on Linux
x86_64/aarch64 and macOS arm64/x86_64 but one tie (0.99x)
(`YAML.parse_all` 1.25x-3.09x); see docs/PERFORMANCE.md.

### Verification

Differential tests against libyaml 0.2.5 (yaml-test-suite, edge cases,
real-world files, 3,805 `Builder` scripts), Crystal's `spec/std/yaml` for
1.21.0, latest and nightly, a line-by-line review against libyaml's C
source, about 1.2 billion fuzzed cases, valgrind memcheck, kcov coverage,
and the test suites of 22 projects that use YAML (shards, ameba, Lucky,
Amber, Mint, Invidious, noir, hwaro, ...) with results identical to the
stdlib's.
CI covers Linux, macOS, Windows (MSVC, MinGW-w64), Alpine, the interpreter
and wasm32-wasi. See docs/ROADMAP.md.
