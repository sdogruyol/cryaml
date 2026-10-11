# Compile-cost program: parse a String into `YAML::Any` and nothing else.
# Built by `scripts/compile_cost.sh`.
{% if flag?(:stdlib_yaml) %}
  require "yaml"
{% else %}
  require "../../src/cryaml"
{% end %}

puts YAML.parse(ARGV[0]? || "a: 1")["a"]?
