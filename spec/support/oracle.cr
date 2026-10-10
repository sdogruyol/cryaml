# Dump server for differential tests and the fuzzer.
#
# Built normally it is the reference: the stdlib's libyaml binding
# (test-only; cryaml itself never links libyaml). Built with `-Dcryaml` it
# runs the same dumps on cryaml, which lets the fuzzer survive crashes and
# hangs on either side.
#
# Usage: oracle BUNDLE.json
#   BUNDLE.json: [{"name": ..., "mode": ..., "input": BASE64}, ...]
# Prints a JSON object mapping each name to the dump of its case, plus
# "__engine__" ("libyaml" or "cryaml") and "__libyaml_version__" (the harness
# refuses anything but libyaml 0.2.5 as the reference).
require "json"
{% if flag?(:cryaml) %}
  require "../../src/cryaml"
{% else %}
  require "yaml"
{% end %}
require "base64"
require "./dump"

cases = Array({name: String, mode: String, input: String}).from_json(File.read(ARGV[0]))
result = cases.to_h { |c| {c[:name], CryamlDump.run(c[:mode], String.new(Base64.decode(c[:input])))} }
result["__libyaml_version__"] = YAML.libyaml_version.to_s
result["__engine__"] = {{ @top_level.has_constant?("LibYAML") ? "libyaml" : "cryaml" }}
STDOUT << result.to_json
