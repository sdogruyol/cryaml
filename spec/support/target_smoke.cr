# Cross-target check for targets without exception support (wasm32-wasi):
# run the same dumps natively and on the target and diff the output.
#
#   crystal run spec/support/target_smoke.cr -- list  > files.txt   # native: inputs that parse without error
#   crystal run spec/support/target_smoke.cr -- dump files.txt       # native and on the target; outputs must match
#
# `list` needs exceptions, so it only runs natively; `dump` only gets inputs
# that don't raise.
require "../../src/cryaml"
require "./dump"

ROOT = File.expand_path("../..", __DIR__)

case ARGV[0]?
when "list"
  paths = Dir.glob(File.join(ROOT, "spec", "fixtures", "{yaml-test-suite,edge}", "*.yaml")) +
          Dir.glob(File.join(ROOT, "samples", "*.{yaml,yml}"))
  paths.sort.each do |path|
    input = File.read(path)
    begin
      YAML.parse_all(input).to_yaml
      YAML::Nodes.parse_all(input)
      puts Path[path].relative_to(ROOT)
    rescue
      # raises: not usable on targets without exceptions
    end
  end
when "dump"
  File.read_lines(ARGV[1]).each do |relative|
    input = File.read(File.join(ROOT, relative))
    puts "== #{relative}"
    io = IO::Memory.new
    CryamlDump.events(io, input)
    CryamlDump.nodes(io, input)
    io << YAML.parse_all(input).to_yaml
    puts io
  end
else
  abort "usage: target_smoke (list | dump FILES)"
end
