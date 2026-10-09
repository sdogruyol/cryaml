# Notice

cryaml is MIT licensed (see [LICENSE](LICENSE)). It contains work derived from
the following projects. Per-file copyright and license information is in
[REUSE.toml](REUSE.toml); license texts are in [LICENSES/](LICENSES/).

## libyaml

`src/yaml/reader.cr`, `scanner.cr`, `event_parser.cr`, `emitter.cr`,
`chars.cr`, `byte_buffer.cr`, `collections.cr`, `token.cr` and `event.cr` are
a Crystal port of libyaml 0.2.5 (`reader.c`, `scanner.c`, `parser.c`,
`emitter.c`, `writer.c`, `yaml_private.h`, `yaml.h`).

Copyright (c) 2017-2020 Ingy döt Net, Copyright (c) 2006-2016 Kirill Simonov.
MIT License: [LICENSES/MIT.txt](LICENSES/MIT.txt).

## Crystal standard library

cryaml loads the stdlib's own YAML layers (`YAML::Any`, `YAML::Nodes`, the
schemas, serialization) from the installed compiler; it does not copy them.
`src/yaml.cr`, `src/yaml/pull_parser.cr` and `src/yaml/builder.cr` are adapted
from Crystal 1.21.0 to run on the pure Crystal engine instead of the libyaml
binding, and `src/cryaml/{big,uri,uuid}.cr` mirror the stdlib's YAML
extensions; each says so in its header. `spec/std/` holds Crystal 1.21.0's
YAML specs.

Copyright 2012-2026 Manas Technology Solutions. Apache License 2.0 with Swift
exception: [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt),
[LICENSES/Swift-exception.txt](LICENSES/Swift-exception.txt).

## yaml-test-suite

`spec/fixtures/yaml-test-suite/` holds the `in.yaml` inputs of
[yaml-test-suite](https://github.com/yaml/yaml-test-suite) (data release
2022-01-17). Copyright (c) 2016-2020 Ingy döt Net. MIT License:
[spec/fixtures/yaml-test-suite/LICENSE](spec/fixtures/yaml-test-suite/LICENSE).

## Samples

`samples/` holds unmodified real-world files under their own licenses; see
[samples/SOURCES.md](samples/SOURCES.md).
