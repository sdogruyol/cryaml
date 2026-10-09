# Notice

cryaml is MIT licensed (see [LICENSE](LICENSE)). It contains work derived from
the following projects.

## libyaml

`src/yaml/reader.cr`, `scanner.cr`, `event_parser.cr`, `emitter.cr`,
`chars.cr` and `byte_buffer.cr` are a Crystal port of libyaml 0.2.5
(`reader.c`, `scanner.c`, `parser.c`, `emitter.c`, `writer.c`,
`yaml_private.h`).

Copyright (c) 2017-2020 Ingy döt Net, Copyright (c) 2006-2016 Kirill Simonov.
MIT License: [LICENSES/libyaml-MIT.txt](LICENSES/libyaml-MIT.txt).

## Crystal standard library

The value, node, schema and serialization layers in `src/yaml/` (`any.cr`,
`enums.cr`, `from_yaml.cr`, `nodes.cr`, `nodes/`, `parse_context.cr`,
`parser.cr`, `schema/`, `serialization.cr`, `to_yaml.cr`), the mirrors in
`src/cryaml/` and the specs in `spec/std/` are copied from Crystal 1.21.0.
`src/yaml.cr`, `src/yaml/pull_parser.cr`, `src/yaml/builder.cr` and the
`src/cryaml/` mirrors were modified to run on the pure Crystal engine instead
of the libyaml binding; each says so in its header.

Copyright 2012-2026 Manas Technology Solutions. Apache License 2.0 with Swift
exception: [LICENSES/Crystal-Apache-2.0.txt](LICENSES/Crystal-Apache-2.0.txt).

## yaml-test-suite

`spec/fixtures/yaml-test-suite/` holds the `in.yaml` inputs of
[yaml-test-suite](https://github.com/yaml/yaml-test-suite) (data release
2022-01-17). Copyright (c) 2016-2020 Ingy döt Net. MIT License:
[spec/fixtures/yaml-test-suite/LICENSE](spec/fixtures/yaml-test-suite/LICENSE).

## Samples

`samples/` holds unmodified real-world files under their own licenses; see
[samples/SOURCES.md](samples/SOURCES.md).
