require "./spec_helper"
require "./support/differential"

# Every case is run through cryaml and through the stdlib's libyaml binding
# (see `support/oracle.cr`); the observable results must be identical.
private FIXTURES = File.join(__DIR__, "fixtures")

# Globs need `/` separators (`__DIR__` has `\` on Windows), and the golden
# keys are POSIX paths on every platform.
private def corpus(dir : String) : Array({String, String})
  files = Dir.glob(Path[dir].to_posix.join("**", "*.{yaml,yml}").to_s).sort.map do |path|
    {Path[path].relative_to(Differential::ROOT).to_posix.to_s, File.read(path)}
  end
  raise "no corpus files under #{dir}" if files.empty?
  files
end

# Inputs cut at a few points, to exercise error paths and stream ends.
private def truncations(name : String, input : String) : Array({String, String})
  size = input.bytesize
  return [] of {String, String} if size < 4
  {size // 3, size // 2, size - 2}.to_a.uniq.map do |cut|
    {"#{name}[0,#{cut}]", String.new(input.to_slice[0, cut])}
  end
end

describe "differential (cryaml vs libyaml)" do
  test_suite = corpus(File.join(FIXTURES, "yaml-test-suite"))
  samples = corpus(File.join(Differential::ROOT, "samples"))
  edge = corpus(File.join(FIXTURES, "edge"))

  cases = [] of Differential::Case
  (test_suite + samples + edge).each do |name, input|
    %w(events events_io any_all nodes emit dump).each do |mode|
      cases << Differential::Case.new(name, mode, input)
    end
  end
  test_suite.each do |name, input|
    truncations(name, input).each do |cut_name, cut|
      cases << Differential::Case.new(cut_name, "events", cut)
    end
  end
  Differential.compare("corpus", cases)
end
