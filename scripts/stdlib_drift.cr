# Checks cryaml's copy of the stdlib YAML layers against the stdlib of the
# Crystal running this script:
#
# * files copied verbatim must be byte-identical to the stdlib's;
# * files cryaml adapted must still match the upstream version they were
#   adapted from (recorded below), otherwise the adaptation needs redoing;
# * the stdlib must not have grown YAML files cryaml doesn't know about.
#
#   crystal run scripts/stdlib_drift.cr
#
# Exit status 1 on any drift. CI runs it against the latest and nightly
# Crystal to catch upstream changes early.
require "digest/sha1"

ROOT   = File.expand_path("..", __DIR__)
STDLIB = Crystal::PATH.split(Process::PATH_DELIMITER).find! { |dir| File.exists?(File.join(dir, "yaml.cr")) }

VERBATIM = %w(
  yaml/any.cr yaml/enums.cr yaml/from_yaml.cr yaml/nodes.cr yaml/parse_context.cr
  yaml/parser.cr yaml/serialization.cr yaml/to_yaml.cr
  yaml/nodes/builder.cr yaml/nodes/nodes.cr yaml/nodes/parser.cr
  yaml/schema/core.cr yaml/schema/fail_safe.cr yaml/schema/core/parser.cr
)

# stdlib file => {cryaml file, SHA-1 of the Crystal 1.21.0 original}
ADAPTED = {
  "yaml.cr"             => {"src/yaml.cr", "6dbc5ce10c69d8eaeee0329aad544e9e91e1ae32"},
  "yaml/pull_parser.cr" => {"src/yaml/pull_parser.cr", "94554ba262f3f9b81e22136c66cca7a602d5dee3"},
  "yaml/builder.cr"     => {"src/yaml/builder.cr", "caa2cdd8b0d6d8f5378c03c891e29769320f2a12"},
  "yaml/lib_yaml.cr"    => {"(replaced by the engine)", "3136606d31eac8610ba1f1c3452e27eaf15d00fa"},
  "big/yaml.cr"         => {"src/cryaml/big.cr", "3db88d1131fe5aed4db9a984b01cc2e6699198e4"},
  "uri/yaml.cr"         => {"src/cryaml/uri.cr", "fd923b516ea2d774c9e39c80c2408fe57e17777f"},
  "uuid/yaml.cr"        => {"src/cryaml/uuid.cr", "70f87b7355e0b7e6f8f15214dd1350bebf6c3061"},
}

problems = [] of String

VERBATIM.each do |path|
  upstream = File.join(STDLIB, path)
  ours = File.join(ROOT, "src", path)
  if !File.exists?(upstream)
    problems << "#{path}: removed from the stdlib"
  elsif File.read(upstream) != File.read(ours)
    problems << "#{path}: differs from the stdlib; copy it again (it is meant to be verbatim)"
  end
end

ADAPTED.each do |path, (ours, sha1)|
  upstream = File.join(STDLIB, path)
  if !File.exists?(upstream)
    problems << "#{path}: removed from the stdlib (adapted as #{ours})"
  elsif (actual = Digest::SHA1.hexdigest(File.read(upstream))) != sha1
    problems << "#{path}: changed upstream (#{actual}); port the change to #{ours} and update its hash"
  end
end

known = VERBATIM.to_set + ADAPTED.keys.select(&.starts_with?("yaml/")).to_set
Dir.glob(File.join(STDLIB, "yaml", "**", "*.cr")).each do |file|
  path = Path[file].relative_to(STDLIB).to_posix.to_s
  problems << "#{path}: new stdlib file, not in cryaml" unless known.includes?(path)
end

puts "stdlib: #{STDLIB} (Crystal #{Crystal::VERSION})"
if problems.empty?
  puts "no drift: #{VERBATIM.size} verbatim files identical, #{ADAPTED.size} adapted files unchanged upstream"
else
  problems.each { |problem| puts "DRIFT #{problem}" }
  exit 1
end
