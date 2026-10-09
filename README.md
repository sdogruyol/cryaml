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
`#to_yaml`, `YAML::PullParser`, `YAML::Builder` and `YAML::Nodes` are the
stdlib's.

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

**API parity.** The value, node, schema and serialization layers are copied
unchanged from Crystal 1.21.0. Only `PullParser` and `Builder` were adapted,
and their public methods are the same (minus the `finalize` hook, since there
is no native memory to free). Crystal's own `spec/std/yaml` suite runs
against cryaml in this repository and passes.

**Same behavior as libyaml.** Every input in the
[yaml-test-suite](https://github.com/yaml/yaml-test-suite), 110 edge cases
(tabs, BOMs, UTF-16, invalid UTF-8, directives, chunk boundaries) and 12
real-world files (Kubernetes, Docker Compose, GitHub Actions, CircleCI,
Helm, Home Assistant, OpenAPI) is run through both cryaml and the stdlib's
libyaml binding. Events, line/column positions, styles, tags, anchors,
values, error messages, `YAML::Any` results, node trees and emitted YAML must
be identical, and are. 420 generated `YAML::Builder` scripts are compared the
same way.

**Hostile input.** The parser is an explicit state machine, so nesting depth
never touches the call stack; `YAML.parse` stops at 512 levels like the
stdlib. Alias bombs ("billion laughs") are rejected by the same alias/anchor
ratio check. An 8 MB scalar or a single line with 100,000 flow items parses
in well under a second (unoptimized spec build). libyaml's simple-key scan is
quadratic in flow nesting depth; cryaml bounds it without changing the tokens.

**Performance.** Close to libyaml: `YAML.parse_all`
runs at 0.92x-1.09x of the stdlib's speed, the raw event walk at 0.79x-1.10x,
the emitter at 0.76x-0.99x. Peak RSS is the same (30.6 MB vs 30.7 MB parsing
a 1 MB document five times). Full tables: [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  cryaml:
    github: sdogruyol/cryaml
```

Run `shards install`. Crystal 1.21 or newer. libyaml does not need to be
installed.

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

## stdlib vs cryaml

| | stdlib `require "yaml"` | cryaml |
| --- | --- | --- |
| Engine | libyaml (C) | libyaml 0.2.5 ported to Crystal |
| System dependency | libyaml | none |
| API | Crystal 1.21.0 | identical |
| Parse results, positions, errors, emitted text | libyaml 0.2.5 | identical |
| `YAML.parse_all` speed | 1x | 0.92x-1.09x |
| Peak RSS (1 MB document) | 30.7 MB | 30.6 MB |
| Invalid UTF-8 given to `Builder` | can crash the process | raises `YAML::Error` |
| Backtraces | stop at C frames | Crystal all the way |

Details: [docs/COMPARISON.md](docs/COMPARISON.md). How it is built and
tested: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Development

```sh
crystal spec              # everything; needs libyaml for the differential oracle
crystal spec spec/std     # Crystal's own YAML specs, run against cryaml
crystal run bench/run.cr  # stdlib vs cryaml benchmark (release builds)
```

The differential specs compile `spec/support/oracle.cr` against the stdlib's
`require "yaml"` and compare its output with cryaml's. That is the only place
libyaml is used; the library itself contains no `lib`, `fun` or `LibC` calls,
and CI checks that a program using it does not link libyaml.

## License

MIT, see [LICENSE](LICENSE). The engine is derived from libyaml (MIT) and the
`YAML` layers from the Crystal standard library (Apache-2.0); see
[NOTICE.md](NOTICE.md).
