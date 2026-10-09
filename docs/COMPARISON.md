# stdlib `YAML` vs cryaml

| | stdlib `require "yaml"` | cryaml `require "cryaml"` |
| --- | --- | --- |
| Engine | libyaml 0.2.x through `lib LibYAML` | Crystal port of libyaml 0.2.5 |
| C code / system library | libyaml (`-lyaml`, `yaml.dll`) | none |
| Module | `YAML` | `YAML` |
| Public API | Crystal 1.21.0 | identical (same source above the engine) |
| YAML dialect | YAML 1.1 as libyaml parses it | same: same tokens, events, positions, errors |
| Error messages | libyaml's text + line/column | identical text and positions |
| Emitted text | libyaml emitter | identical |
| UTF-16 input (with BOM) | yes | yes |
| Nesting limit | `PullParser#max_nesting` (512), `Builder#max_nesting` (99) | same |
| Alias bomb guard | `PullParser` alias/anchor ratio | same |
| Deep flow nesting with the limit raised | quadratic in libyaml's simple-key scan | bounded scan, same tokens |
| Invalid UTF-8 passed to `Builder` | stale event re-emitted; may crash (`double free`) | `YAML::Error` |
| Memory | malloc'ed parser/emitter state, freed by finalizers | GC objects only, no finalizers |
| Throughput | baseline | 0.76x-1.14x per operation, `YAML.parse_all` 0.92x-1.09x ([numbers](PERFORMANCE.md)) |
| Debugging | C frames in backtraces | Crystal frames all the way down |

## API surface

Checked against Crystal 1.21.0's `src/yaml.cr` and `src/yaml/**`. Every file
above the engine is the stdlib's own; the public method signatures of the two
adapted classes (`PullParser`, `Builder`) differ only by the removed
`finalize`.

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
with `require "yaml"`, which would load the libyaml binding next to cryaml.
Use `require "cryaml/big"`, `"cryaml/uri"` and `"cryaml/uuid"` instead.

## Internal types

The engine adds `YAML::Reader`, `Scanner`, `Token`, `TokenKind`, `Mark`,
`Event`, `EventParser`, `Emitter`, `ByteBuffer` and `Chars`, all `:nodoc:`.
The `LibYAML` binding they replace no longer exists.

## Verification

- Crystal's own `spec/std/yaml` suite (copied to `spec/std/`) passes against
  cryaml unchanged apart from the require lines.
- Differential specs compare cryaml with the libyaml binding on 524 inputs
  (yaml-test-suite, edge cases, real-world files) in six modes plus 1,183
  truncated inputs, and on 420 generated `Builder` scripts. See
  [ARCHITECTURE.md](ARCHITECTURE.md#testing).
