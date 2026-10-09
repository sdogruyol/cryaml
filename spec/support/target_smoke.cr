# Cross-target check for targets without exception support or file access
# (wasm32-wasi): run the same dumps natively and on the target, then diff.
#
#   crystal run spec/support/target_smoke.cr -- bundle > bundle.txt  # native
#   ./smoke dump < bundle.txt > native.txt                            # native
#   wasmtime run smoke.wasm dump < bundle.txt > wasm.txt              # target
#
# `bundle` writes every corpus input that parses without error (finding them
# needs exceptions, so it only runs natively) as "== path" plus a base64
# line. `dump` reads that from STDIN, since WASI builds can't open files.
require "base64"
require "../../src/cryaml"
require "./dump"

ROOT = File.expand_path("../..", __DIR__)

case ARGV[0]?
when "bundle"
  paths = Dir.glob(File.join(ROOT, "spec", "fixtures", "{yaml-test-suite,edge}", "*.yaml")) +
          Dir.glob(File.join(ROOT, "samples", "*.{yaml,yml}"))
  paths.sort.each do |path|
    input = File.read(path)
    begin
      YAML.parse_all(input).to_yaml
      YAML::Nodes.parse_all(input)
    rescue
      next # raises: not usable on targets without exceptions
    end
    puts "== #{Path[path].relative_to(ROOT)}"
    puts Base64.strict_encode(input)
  end
when "dump"
  while header = STDIN.gets
    input = String.new(Base64.decode(STDIN.gets.not_nil!))
    puts header
    io = IO::Memory.new
    CryamlDump.events(io, input)
    CryamlDump.nodes(io, input)
    io << YAML.parse_all(input).to_yaml
    puts io
  end
else
  abort "usage: target_smoke (bundle | dump)"
end
