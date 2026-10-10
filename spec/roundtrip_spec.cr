require "./spec_helper"

# parse -> dump -> parse must be stable.
#
# The first dump can be lossy in ways the stdlib shares (a `nil` mapping key
# is written as `''` and comes back as `""`; a `Set` comes back as an
# `Array`), so stability is checked from the first re-parse on: re-dumping
# yields the same text and the same value. The first dump itself is compared
# against the stdlib by the `dump` mode of `differential_spec.cr`.
private def roundtrip_corpus : Array({String, String})
  # Globs need `/` separators (`__DIR__` has `\` on Windows).
  root = Path[File.expand_path("..", __DIR__)].to_posix
  paths = Dir.glob(root.join("samples", "*.{yaml,yml}").to_s) +
          Dir.glob(root.join("spec", "fixtures", "yaml-test-suite", "*.yaml").to_s) +
          Dir.glob(root.join("spec", "fixtures", "edge", "*.yaml").to_s)
  raise "no corpus files under #{root}" if paths.empty?
  paths.sort.compact_map do |path|
    input = File.read(path)
    YAML.parse_all(input) rescue next
    {Path[path].relative_to(root).to_posix.to_s, input}
  end
end

# NaN never equals itself, so compare such documents by their dump only.
private def nan?(value : YAML::Any) : Bool
  case raw = value.raw
  when Float64 then raw.nan?
  when Array   then raw.any? { |item| nan?(item) }
  when Hash    then raw.any? { |key, item| nan?(key) || nan?(item) }
  when Set     then raw.any? { |item| nan?(item) }
  else              false
  end
end

describe "round trip" do
  roundtrip_corpus.each do |name, input|
    it "is stable for #{name}" do
      YAML.parse_all(input).each do |document|
        reparsed = YAML.parse(document.to_yaml)
        second = reparsed.to_yaml
        again = YAML.parse(second)
        again.to_yaml.should eq(second)
        again.should eq(reparsed) unless nan?(reparsed)
      end
    end
  end

  it "round-trips Serializable objects" do
    original = RoundTripConfig.new("app", 3, ["a", "b: c", "- d", "multi\nline"], {"x" => 1.5, "y" => -0.0})
    RoundTripConfig.from_yaml(original.to_yaml).should eq(original)
  end
end

private struct RoundTripConfig
  include YAML::Serializable

  getter name : String
  getter replicas : Int32
  getter tags : Array(String)
  getter weights : Hash(String, Float64)

  def initialize(@name, @replicas, @tags, @weights)
  end

  def_equals name, replicas, tags, weights
end
