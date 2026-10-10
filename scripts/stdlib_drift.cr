# Checks cryaml against the stdlib of the Crystal running this script.
#
# cryaml loads the stdlib's own YAML layers (Any, Nodes, schema,
# serialization) and replaces only `yaml.cr`, `yaml/pull_parser.cr`,
# `yaml/builder.cr` and `yaml/lib_yaml.cr`. This fails when:
#
# * one of the replaced files changed upstream since it was adapted (the
#   hashes below are Crystal 1.21.0's), so the change must be ported;
# * the stdlib's `yaml.cr` would load a file that `src/yaml.cr` doesn't.
#
#   crystal run scripts/stdlib_drift.cr
#
# CI runs it against 1.21.0, the latest release and nightly.
require "digest/sha1"

ROOT   = File.expand_path("..", __DIR__)
STDLIB = Crystal::PATH.split(Process::PATH_DELIMITER).find! { |dir| File.exists?(File.join(dir, "yaml.cr")) }

# stdlib file => {cryaml file, SHA-1 of the Crystal 1.21.0 original}
ADAPTED = {
  "yaml.cr"             => {"src/yaml.cr", "6dbc5ce10c69d8eaeee0329aad544e9e91e1ae32"},
  "yaml/pull_parser.cr" => {"src/yaml/pull_parser.cr", "94554ba262f3f9b81e22136c66cca7a602d5dee3"},
  "yaml/builder.cr"     => {"src/yaml/builder.cr", "caa2cdd8b0d6d8f5378c03c891e29769320f2a12"},
  "yaml/lib_yaml.cr"    => {"the engine in src/yaml/", "3136606d31eac8610ba1f1c3452e27eaf15d00fa"},
  "big/yaml.cr"         => {"src/cryaml/big.cr", "3db88d1131fe5aed4db9a984b01cc2e6699198e4"},
  "uri/yaml.cr"         => {"src/cryaml/uri.cr", "fd923b516ea2d774c9e39c80c2408fe57e17777f"},
  "uuid/yaml.cr"        => {"src/cryaml/uuid.cr", "70f87b7355e0b7e6f8f15214dd1350bebf6c3061"},
}

problems = [] of String

ADAPTED.each do |path, (ours, sha1)|
  upstream = File.join(STDLIB, path)
  if !File.exists?(upstream)
    problems << "#{path}: removed from the stdlib (replaced by #{ours})"
  elsif (actual = Digest::SHA1.hexdigest(File.read(upstream))) != sha1
    problems << "#{path}: changed upstream (#{actual}); port the change to #{ours} and update its hash"
  end
end

loaded = File.read_lines(File.join(ROOT, "src", "yaml.cr")).compact_map { |line| line.match(/\Arequire "(yaml\/[^"]+)"/).try { |m| "#{m[1]}.cr" } }.to_set
Dir.glob(File.join(Path[STDLIB].to_posix, "yaml", "**", "*.cr")).each do |file|
  path = Path[file].relative_to(STDLIB).to_posix.to_s
  next if loaded.includes?(path) || ADAPTED.has_key?(path)
  problems << "#{path}: loaded by the stdlib's yaml.cr but not by src/yaml.cr"
end
loaded.each do |path|
  problems << "#{path}: required by src/yaml.cr but gone from the stdlib" unless File.exists?(File.join(STDLIB, path))
end

puts "stdlib: #{STDLIB} (Crystal #{Crystal::VERSION})"
if problems.empty?
  puts "no drift: #{loaded.size} stdlib files loaded as is, #{ADAPTED.size} replaced files unchanged upstream"
else
  problems.each { |problem| puts "DRIFT #{problem}" }
  exit 1
end
