# cryaml

[![CI](https://img.shields.io/github/actions/workflow/status/sdogruyol/cryaml/ci.yml?branch=master&style=flat-square&logo=githubactions&label=CI)](https://github.com/sdogruyol/cryaml/actions/workflows/ci.yml)
[![Crystal](https://img.shields.io/badge/Crystal-%3E%3D1.21-000?style=flat-square&logo=crystal)](https://crystal-lang.org)
![License](https://img.shields.io/badge/license-MIT-3da639?style=flat-square)

cryaml is Crystal's standard `YAML` module running on a YAML engine written
in Crystal instead of libyaml. The scanner, parser and emitter are a
function-by-function port of libyaml 0.2.5; everything above them is the
stdlib's own code. Same `YAML` module, same API, same parse results, same
error messages, same emitted text, and no C library to install or link.

It is the second project in the "Crystal without C" series, after
[gcry](https://github.com/sdogruyol/gcry), the garbage collector written in
Crystal.

## Quick start

Change one line:

```crystal
# before: stdlib, binds libyaml
require "yaml"

# after: cryaml, pure Crystal
require "cryaml"

doc = YAML.parse("a: 1")
doc["a"].as_i # => 1
```

Nothing else changes: `YAML.parse`, `YAML::Any`, `YAML::Serializable`,
`#to_yaml` and `YAML::Nodes` are the stdlib's own code, and
`YAML::PullParser` and `YAML::Builder` have the stdlib's API.

## Demo

```crystal
# app.cr
require "cryaml"

config = YAML.parse(<<-YAML)
  defaults: &defaults
    adapter: postgres
    pool: 5
  production:
    <<: *defaults
    host: db.example.com
  YAML

puts config["production"]["host"]
puts config["production"]["pool"]
puts({name: "cryaml", c_code: 0}.to_yaml)
```

```console
$ crystal build app.cr && ./app
db.example.com
5
---
name: cryaml
c_code: 0
$ ldd app | grep yaml
$ ldd app_stdlib | grep yaml        # the same program with require "yaml"
	libyaml-0.so.2 => /usr/lib/x86_64-linux-gnu/libyaml-0.so.2
```

## Features

**API parity.** cryaml loads `YAML::Any`, `YAML::Nodes`, the schemas and
`YAML::Serializable` from your compiler's own stdlib and replaces only the
layer that called into C. `PullParser` and `Builder` keep their public
methods (minus the `finalize` hook: there is no native memory to free). CI
runs the stdlib's `spec/std/yaml` of Crystal 1.21.0, the latest release and
nightly against cryaml.

**Same behavior as libyaml.** Every input in the
[yaml-test-suite](https://github.com/yaml/yaml-test-suite), 168 edge cases
(tabs, BOMs, UTF-16, invalid UTF-8, directives, chunk boundaries, NUL in
tags) and 12 real-world files (Kubernetes, Docker Compose, GitHub Actions,
CircleCI, Helm, Home Assistant, OpenAPI) is compared with libyaml 0.2.5:
events with line/column positions, styles, tags, anchors, values, error
messages, `YAML::Any` results, node trees and emitted YAML must be
identical, and are. So are 3,862 `YAML::Builder` scripts (every value in
every scalar style in every position, plus random and invalid ones). On top:
a line-by-line review of the port against libyaml's C source, a differential
fuzzer (1.2 billion cases in one overnight run; it also runs nightly in CI),
valgrind memcheck over the suite and fuzzed inputs, and 100% line coverage of
the scanner (98% overall; the rest is unreachable through the public API).
See [docs/ROADMAP.md](docs/ROADMAP.md) for what was found along the way.

**Tested where Crystal runs.** Linux x86_64 and aarch64, macOS arm64 and
x86_64, Windows (MSVC and MinGW-w64), Alpine with a static binary, the
interpreter and wasm32-wasi, on every push. The test suites of 22 projects
that use YAML (shards, ameba, Lucky, Amber, Mint, Invidious, noir, ...) give
the same results on cryaml as on the stdlib, unmodified.

**Hostile input.** The parser is an explicit state machine, so nesting depth
never touches the call stack; `YAML.parse` stops at 512 levels like the
stdlib. Alias bombs ("billion laughs") are rejected by the same alias/anchor
ratio check. An 8 MB scalar or a single line with 100,000 flow items parses
in well under a second (unoptimized spec build). libyaml's simple-key scan is
quadratic in flow nesting depth; cryaml bounds it without changing the tokens.

**Performance.** Faster than the libyaml binding everywhere but one tie.
Measured on GitHub's Linux x86_64/aarch64 and macOS arm64/x86_64 runners:
`YAML.parse_all` runs 1.25x-3.09x as fast as the stdlib's, the raw event walk
1.46x-3.19x, the emitter 0.99x-1.90x. Peak RSS is about the same. Full tables
and instruction counts: [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  cryaml:
    github: sdogruyol/cryaml
```

Run `shards install`. libyaml does not need to be installed.

Crystal 1.21 or newer. cryaml loads the `YAML` layers above the engine from
your compiler's stdlib, but `src/yaml.cr`, `PullParser` and `Builder` are
adapted from Crystal 1.21.0. If a later Crystal changes those files or adds
new ones under `yaml/`, cryaml won't pick that up until a cryaml release
does. `crystal run lib/cryaml/scripts/stdlib_drift.cr` reports any such
drift for the compiler in use.

On wasm32-wasi, link with a larger stack (for example
`--link-flags="-z stack-size=8388608"`): the default is 64 KiB without a
guard page, and `YAML.parse` recurses once per nesting level, so a document
about 40 levels deep overflows it and corrupts the heap. The same holds for
the stdlib's YAML; cryaml's engine itself doesn't recurse.

## Usage

Everything in the [stdlib YAML docs](https://crystal-lang.org/api/YAML.html)
applies. A few examples:

```crystal
require "cryaml"

# Parse into YAML::Any
data = YAML.parse(File.read("config.yml"))
data["services"]["web"]["ports"].as_a.map(&.as_s)

# Several documents
YAML.parse_all("--- 1\n--- 2\n").map(&.as_i) # => [1, 2]

# Map to your own types
class Service
  include YAML::Serializable

  getter image : String
  getter replicas : Int32 = 1

  @[YAML::Field(key: "env")]
  getter environment : Hash(String, String) = {} of String => String
end

service = Service.from_yaml("image: nginx\nenv: {MODE: prod}\n")
service.to_yaml # => "---\nimage: nginx\nreplicas: 1\nenv:\n  MODE: prod\n"

# Stream events
parser = YAML::PullParser.new(File.open("big.yml"))
until parser.kind.stream_end?
  puts parser.value if parser.kind.scalar?
  parser.read_next
end

# Build YAML
YAML.build do |yaml|
  yaml.mapping do
    yaml.scalar "name"
    yaml.scalar "cryaml"
  end
end # => "---\nname: cryaml\n"
```

Errors are `YAML::ParseException`s with libyaml's wording and position:

```crystal
YAML.parse("a: b: c")
# => mapping values are not allowed in this context at line 1, column 5 (YAML::ParseException)
```

The stdlib's `big/yaml`, `uri/yaml` and `uuid/yaml` extensions
`require "yaml"` themselves, which would pull in the libyaml binding. Use
the mirrors instead:

```crystal
require "cryaml"
require "cryaml/big"  # BigInt, BigFloat, BigDecimal
require "cryaml/uri"  # URI
require "cryaml/uuid" # UUID
```

### Dependencies that require yaml

A program can't load both cryaml and the stdlib's `yaml`: they define the
same module, so cryaml stops the build whichever comes first. If a shard you
depend on says `require "yaml"` (directly or through `uuid/yaml` and
friends), put cryaml's shim directory first in `CRYSTAL_PATH`. Every
`require "yaml"` then loads cryaml, with no source changes:

```sh
CRYSTAL_PATH="lib/cryaml/shim:$(crystal env CRYSTAL_PATH)" crystal build src/app.cr
```

On Windows the separator is `;` (PowerShell:
`$env:CRYSTAL_PATH = "lib/cryaml/shim;$(crystal env CRYSTAL_PATH)"`).

The same trick runs an unmodified project's test suite on cryaml.

## stdlib vs cryaml

| | stdlib `require "yaml"` | cryaml |
| --- | --- | --- |
| Engine | libyaml (C) | libyaml 0.2.5 ported to Crystal |
| System dependency | libyaml (version varies by platform) | none |
| API | Crystal stdlib | identical (the same layers, loaded from your stdlib) |
| Parse results, positions, errors, emitted text | libyaml 0.2.5 on most platforms | identical to libyaml 0.2.5 everywhere |
| `YAML.parse_all` speed | 1x | 1.25x-3.09x |
| Peak RSS | baseline | about the same |
| Malformed UTF-8 given to `Builder` | can crash the process | raises `YAML::Error` |
| wasm32-wasi | needs libyaml built for WASI | works |
| Backtraces | stop at C frames | Crystal all the way |

Details: [docs/COMPARISON.md](docs/COMPARISON.md). How it is built and
tested: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Development

```sh
crystal spec              # everything; differential specs use recorded libyaml 0.2.5 output
crystal spec spec/std     # Crystal's own YAML specs, run against cryaml
crystal run bench/run.cr  # stdlib vs cryaml benchmark (release builds)
```

The differential specs compare cryaml's output with libyaml 0.2.5's, recorded
in `spec/fixtures/golden`. With `CRYAML_ORACLE=1`, `spec/differential_spec.cr`
and `spec/builder_differential_spec.cr` instead compile
`spec/support/oracle.cr` against the stdlib's `require "yaml"` and compare
live (`CRYAML_ORACLE=update` rewrites the recordings). That is the only place
libyaml is used; the library itself contains no `lib`, `fun` or `LibC` calls,
and CI checks that a program using it does not link libyaml.

## License

MIT, see [LICENSE](LICENSE). The engine is derived from libyaml (MIT) and the
`YAML` layers from the Crystal standard library (Apache-2.0 WITH
Swift-exception); see [NOTICE.md](NOTICE.md).
