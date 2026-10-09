# stdlib `YAML` vs cryaml

| | stdlib `require "yaml"` | cryaml `require "cryaml"` |
| --- | --- | --- |
| Engine | libyaml through `lib LibYAML` | Crystal port of libyaml 0.2.5 |
| C code / system library | libyaml (`-lyaml`, `yaml.dll`) | none |
| libyaml version | whatever is linked: 0.2.5 from most Linux distros and Homebrew, but Crystal 1.21.0's macOS tarball links 0.1.6 by default (`YAML.libyaml_version` on GitHub's macos-15 runner) | behaves as 0.2.5 everywhere |
| Module | `YAML` | `YAML` |
| Public API | Crystal stdlib | identical: the layers above the engine are loaded from the compiler's own stdlib |
| YAML dialect | YAML 1.1 as libyaml parses it | same: same tokens, events, positions, errors |
| Error messages | libyaml's text + line/column | identical text and positions |
| Emitted text | libyaml emitter | identical |
| UTF-16 input (with BOM) | yes | yes |
| Nesting limit | `PullParser#max_nesting` (512), `Builder#max_nesting` (99) | same |
| Alias bomb guard | `PullParser` alias/anchor ratio | same |
| Deep flow nesting with the limit raised | quadratic in libyaml's simple-key scan | bounded scan, same tokens |
| Malformed UTF-8 passed to `Builder` | previous event re-emitted; may crash (`double free`) | `YAML::Error` |
| Memory | malloc'ed parser/emitter state, freed by finalizers | GC objects only, no finalizers |
| Throughput | baseline | `YAML.parse_all` 1.25x-3.09x, emitter 0.99x-1.90x ([numbers](PERFORMANCE.md)) |
| Platforms | wherever libyaml is available; not in Crystal's wasm32 libs | anywhere Crystal compiles, wasm32-wasi included |
| Debugging | C frames in backtraces | Crystal frames all the way down |

## API surface

Checked against Crystal 1.21.0's `src/yaml.cr` and `src/yaml/**`. cryaml
replaces `yaml.cr`, `yaml/pull_parser.cr`, `yaml/builder.cr` and
`yaml/lib_yaml.cr`; every other file is the compiler's own. The public
methods of the two adapted classes (`PullParser`, `Builder`) differ only by
the removed `finalize`.

Top level:

- `YAML.parse(data : String | IO) : YAML::Any`
- `YAML.parse_all(data : String) : Array(YAML::Any)`
- `YAML.dump(object) : String`, `YAML.dump(object, io : IO) : Nil`
- `YAML.build(&) : String`, `YAML.build(io : IO, &) : Nil`
- `YAML.libyaml_version : SemanticVersion` (returns 0.2.5, the reproduced
  release, so version checks such as the 0.2.1 document-end fix keep working)

Types: `YAML::Any`, `YAML::Error`, `YAML::ParseException` (`line_number`,
`column_number`, `location`), `YAML::PullParser`, `YAML::Builder`,
`YAML::Nodes` (`parse`, `parse_all`, `Document`, `Scalar`, `Sequence`,
`Mapping`, `Alias`, `Builder`), `YAML::ParseContext`, `YAML::Schema::Core`,
`YAML::Schema::FailSafe`, `YAML::Serializable` (with `YAML::Field`,
`Serializable::Options`, `Strict`, `Unmapped`, `use_yaml_discriminator`),
`YAML::EventKind`, `ScalarStyle`, `SequenceStyle`, `MappingStyle`, and
`.new(ctx, node)` / `#to_yaml` on the stdlib types.

Opt-in extensions: the stdlib's `big/yaml`, `uri/yaml` and `uuid/yaml` start
with `require "yaml"`. Either use `require "cryaml/big"`, `"cryaml/uri"` and
`"cryaml/uuid"`, or put `lib/cryaml/shim` first in `CRYSTAL_PATH` so every
`require "yaml"` loads cryaml (see the README).

## Internal types

The engine adds `YAML::Reader`, `Scanner`, `Token`, `TokenKind`, `Mark`,
`Event`, `EventParser`, `Emitter`, `ByteBuffer`, `Chars`, `Queue` and
`Stack`, all `:nodoc:`. The `LibYAML` binding they replace is not loaded.

## Verification

- `spec/std/yaml` of Crystal 1.21.0 (in `spec/std/`), and of the latest
  release and nightly in CI, passes against cryaml.
- Differential specs compare cryaml with libyaml 0.2.5 on 535 inputs
  (yaml-test-suite, edge cases, real-world files) in six modes, 1,183
  truncated inputs, and 3,805 `Builder` scripts. A differential fuzzer runs
  nightly. See [ARCHITECTURE.md](ARCHITECTURE.md#testing).
- The ameba and crystal-i18n test suites and shards' unit specs pass on
  cryaml in CI.
