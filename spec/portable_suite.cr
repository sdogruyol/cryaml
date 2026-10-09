# Spec entry point for targets that can't run the whole suite the usual way
# (wasm32-wasi, the interpreter): everything except what needs GMP (`big`)
# or subprocesses (the live oracle). Differential specs run in golden mode.
require "./scanner_spec"
require "./differential_spec"
require "./builder_differential_spec"
require "./roundtrip_spec"
require "./security_spec"
require "./std/yaml/any_spec"
require "./std/yaml/builder_spec"
require "./std/yaml/serializable_spec"
require "./std/yaml/yaml_pull_parser_spec"
require "./std/yaml/yaml_spec"
require "./std/yaml/nodes/builder_spec"
require "./std/yaml/nodes/parser_spec"
require "./std/yaml/schema/core_spec"
require "./std/yaml/schema/fail_safe_spec"
