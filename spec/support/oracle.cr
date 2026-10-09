# Reference implementation for differential tests: the stdlib's libyaml
# binding. Test-only; cryaml itself never links libyaml.
#
# Usage: oracle BUNDLE.json
#   BUNDLE.json: [{"name": ..., "mode": ..., "input": BASE64}, ...]
# Prints a JSON object mapping each name to the dump of its case, plus
# "__libyaml_version__" (the harness refuses anything but 0.2.5).
require "json"
require "yaml"
require "base64"
require "./dump"

cases = Array({name: String, mode: String, input: String}).from_json(File.read(ARGV[0]))
result = cases.to_h { |c| {c[:name], CryamlDump.run(c[:mode], String.new(Base64.decode(c[:input])))} }
result["__libyaml_version__"] = YAML.libyaml_version.to_s
STDOUT << result.to_json
