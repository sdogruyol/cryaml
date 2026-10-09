# Differential fuzzer: mutates YAML inputs and Builder scripts, runs them
# through cryaml and through the stdlib's libyaml 0.2.5 binding, and records
# every difference.
#
#   crystal build --release fuzz/fuzz.cr -o bin/fuzz
#   bin/fuzz --seconds 3600 [--seed N] [--batch 2000] [--out fuzz/findings]
#
# Both sides run as dump servers (spec/support/oracle.cr, built with and
# without -Dcryaml) so a crash or hang on either side is caught instead of
# taking the fuzzer down. A finding is a case whose dumps differ, or on which
# only cryaml crashed or hung. Each one is minimized and written to the
# output directory as `<id>.yaml` (input) and `<id>.txt` (mode, both dumps).
# Exit status 1 if anything was found.
#
# Needs libyaml 0.2.5 for the oracle, like `CRYAML_ORACLE=1`.
require "../spec/support/differential"
require "digest/sha1"
require "option_parser"

module Fuzz
  record Finding, kind : String, mode : String, input : String, expected : String, actual : String

  ROOT = File.expand_path("..", __DIR__)

  TOKENS = [
    ":", ": ", "- ", "-", "? ", "?", ",", "[", "]", "{", "}", "#", " #", "&a ", "*a", "&b", "*b", "!",
    "!!str ", "!!int ", "!!map ", "!!seq ", "!local ", "!<tag:x> ", "!e!x ", "|", "|-", "|+", "|2",
    ">", ">-", ">+", "'", "''", "\"", "\\", "\\n", "\\x41", "\\u00e9", "\\U0001F600", "%", "@", "`",
    "---", "--- ", "...", "%YAML 1.1\n", "%YAML 1.2\n", "%TAG !e! tag:example.com,2000:\n",
    "<<: *a\n", "\n", "\r\n", "\r", "\t", " ", "  ", "    ", "\u0085", "\u2028", "\u2029", "\uFEFF",
    "é", "😀", "\u00A0", "\xFF", "\xC3", "\u0001", "\u007F", "~", "null", "true", "0x1F", ".inf",
    "a" * 1030, " " * 40,
  ]

  def self.seeds : Array(String)
    paths = Dir.glob(File.join(ROOT, "spec", "fixtures", "{yaml-test-suite,edge}", "*.yaml")) +
            Dir.glob(File.join(ROOT, "samples", "*.{yaml,yml}"))
    paths.sort.map { |path| File.read(path) }.reject { |input| input.bytesize > 20_000 }
  end

  def self.mutate(rng : Random, input : String, seeds : Array(String)) : String
    bytes = input.to_slice.to_a
    (1 + rng.rand(4)).times do
      pos = bytes.empty? ? 0 : rng.rand(bytes.size + 1)
      case rng.rand(9)
      when 0 # insert a token
        bytes.insert_all(pos, TOKENS.sample(rng).to_slice.to_a)
      when 1 # delete a range
        next if bytes.empty?
        start = rng.rand(bytes.size)
        bytes.delete_at(start, Math.min(1 + rng.rand(8), bytes.size - start))
      when 2 # duplicate a range
        next if bytes.empty?
        start = rng.rand(bytes.size)
        bytes.insert_all(pos, bytes[start, 1 + rng.rand(32)])
      when 3 # flip a byte to an interesting one
        next if bytes.empty?
        bytes[rng.rand(bytes.size)] = TOKENS.sample(rng).to_slice[0]? || 0_u8
      when 4 # splice in part of another seed
        other = seeds.sample(rng).to_slice
        next if other.empty?
        start = rng.rand(other.size)
        bytes.insert_all(pos, other[start, Math.min(1 + rng.rand(200), other.size - start)].to_a)
      when 5 # change indentation of a line
        line_start = (bytes[0, pos].rindex('\n'.ord.to_u8) || -1) + 1
        if rng.rand(2) == 0 && bytes[line_start]? == ' '.ord
          bytes.delete_at(line_start)
        else
          bytes.insert_all(line_start, (" " * (1 + rng.rand(4))).to_slice.to_a)
        end
      when 6 # truncate
        bytes = bytes[0, pos]
      when 7 # random byte
        bytes.insert(pos, rng.rand(256).to_u8)
      else # swap a line break style
        if index = bytes.index('\n'.ord.to_u8)
          bytes.insert(index, '\r'.ord.to_u8)
        end
      end
    end
    String.new(Slice.new(bytes.to_unsafe, bytes.size))
  end

  # A random, structurally valid Builder script (see CryamlDump.build).
  def self.build_script(rng : Random) : String
    lines = ["stream_start"]
    (1 + rng.rand(2)).times do
      lines << (rng.rand(2) == 0 ? "doc_start explicit" : "doc_start implicit")
      build_node(rng, lines, 0)
      lines << "doc_end"
    end
    lines << "stream_end"
    lines.join('\n')
  end

  SCALARS = ["", " ", "a", "a b", " x", "x ", "a\nb", "\n", "a\n\n", "it's", "\"q\"", "#", "a #b",
             "a: b", "- x", "---", "...", "null", "~", "1", "1.5", "true", "é", "😀", "\u0085",
             "\u2028", "\uFEFF", "\t", "a\tb", "\\", "a\r\nb", "x" * 90, "word " * 25, " \n ", "\u0001"]

  def self.build_node(rng : Random, lines : Array(String), depth : Int32) : Nil
    anchor = rng.rand(5) == 0 ? "a#{rng.rand(3)}" : "-"
    tag = rng.rand(5) == 0 ? ["!x", "tag:yaml.org,2002:str", "!!int", "!"].sample(rng) : "-"
    if depth >= 4 || rng.rand(2) == 0
      if depth > 0 && rng.rand(8) == 0
        lines << "alias a#{rng.rand(3)}"
      else
        style = %w(ANY PLAIN SINGLE_QUOTED DOUBLE_QUOTED LITERAL FOLDED).sample(rng)
        value = String.build { |io| (1 + rng.rand(2)).times { io << SCALARS.sample(rng) } }
        lines << "scalar #{style} #{anchor} #{CryamlDump.build_escape(tag)} #{CryamlDump.build_escape(value)}"
      end
    else
      flow = rng.rand(3) == 0 ? "FLOW" : "BLOCK"
      if rng.rand(2) == 0
        lines << "seq_start #{flow} #{anchor} #{tag}"
        rng.rand(4).times { build_node(rng, lines, depth + 1) }
        lines << "seq_end"
      else
        lines << "map_start #{flow} #{anchor} #{tag}"
        rng.rand(3).times { 2.times { build_node(rng, lines, depth + 1) } }
        lines << "map_end"
      end
    end
  end

  CRASHED = "!!crashed or timed out"

  class_property libyaml_server = ""
  class_property cryaml_server = ""

  # Dumps of *cases* from *server*. Cases on which the server crashes or
  # hangs are found by bisection and get `CRASHED`.
  def self.dumps(server : String, cases : Array(Differential::Case)) : Hash(String, String)
    timeout = Math.max(10.0, cases.size * 0.05).seconds
    Differential.run_server(server, cases, timeout)
  rescue Differential::ServerFailure
    return {Differential.key(cases[0]) => CRASHED} if cases.size == 1
    half = cases.size // 2
    dumps(server, cases[0, half]).merge(dumps(server, cases[half..]))
  end

  # Compares both sides on *cases*; crashes on both sides count as agreement
  # (the shared stdlib layers crash on some inputs in both).
  def self.compare(cases : Array(Differential::Case)) : Array(Finding)
    expected = dumps(libyaml_server, cases)
    actual = dumps(cryaml_server, cases)
    cases.compact_map do |c|
      key = Differential.key(c)
      want, got = expected[key], actual[key]
      next if want == got
      if got == CRASHED
        Finding.new("crash", c.mode, c.input, want, got)
      elsif want != CRASHED
        Finding.new("mismatch", c.mode, c.input, want, got)
      end
    end
  end

  # Delta debugging: repeatedly drop chunks while the case still fails the
  # same way.
  def self.minimize(finding : Finding) : Finding
    best = finding
    chunk = Math.max(best.input.bytesize // 2, 1)
    while chunk >= 1
      bytes = best.input.to_slice
      candidates = (0...bytes.size).step(chunk).map do |start|
        rest = Bytes.new(bytes.size - Math.min(chunk, bytes.size - start))
        rest.copy_from(bytes[0, start]) if start > 0
        tail = bytes[Math.min(start + chunk, bytes.size)..]
        tail.copy_to(rest[start..]) unless tail.empty?
        Differential::Case.new("min-#{start}", best.mode, String.new(rest))
      end.to_a
      smaller = compare(candidates).select(&.kind.==(best.kind)).min_by?(&.input.bytesize)
      if smaller && smaller.input.bytesize < best.input.bytesize
        best = smaller
        chunk = Math.max(best.input.bytesize // 2, 1)
      else
        chunk //= 2
      end
    end
    best
  end

  def self.save(dir : String, finding : Finding) : String
    Dir.mkdir_p(dir)
    id = "#{finding.kind}-#{finding.mode}-#{Digest::SHA1.hexdigest(finding.input)[0, 12]}"
    File.write(File.join(dir, "#{id}.yaml"), finding.input)
    File.write(File.join(dir, "#{id}.txt"), <<-TXT)
      kind: #{finding.kind}
      mode: #{finding.mode}
      input: #{finding.input.inspect}
      --- libyaml 0.2.5
      #{finding.expected}
      --- cryaml
      #{finding.actual}
      TXT
    id
  end
end

seconds = 60
seed = Random.new.rand(UInt32::MAX).to_u64
batch = 2000
out_dir = File.join(Fuzz::ROOT, "fuzz", "findings")
OptionParser.parse do |parser|
  parser.on("--seconds N", "How long to run") { |v| seconds = v.to_i }
  parser.on("--seed N", "Random seed") { |v| seed = v.to_u64 }
  parser.on("--batch N", "Cases per server run") { |v| batch = v.to_i }
  parser.on("--out DIR", "Where to write findings") { |v| out_dir = v }
end

Fuzz.libyaml_server = Differential.oracle_binary(release: true)
Fuzz.cryaml_server = Differential.oracle_binary(cryaml: true, release: true)
rng = Random.new(seed)
seeds = Fuzz.seeds
modes = %w(events events events events_io any_all nodes emit dump)
deadline = Time.instant + seconds.seconds
found = Set(String).new
total = 0
STDERR.puts "fuzz: seed=#{seed} seeds=#{seeds.size} batch=#{batch} seconds=#{seconds}"

while Time.instant < deadline
  cases = Array(Differential::Case).new(batch) do |i|
    if rng.rand(8) == 0
      Differential::Case.new("b#{i}", "build", Fuzz.build_script(rng))
    else
      input = Fuzz.mutate(rng, seeds.sample(rng), seeds)
      Differential::Case.new("c#{i}", modes.sample(rng), input)
    end
  end
  Fuzz.compare(cases).each do |finding|
    id = Fuzz.save(out_dir, Fuzz.minimize(finding))
    if found.add?(id)
      STDERR.puts "fuzz: #{finding.kind} #{finding.mode} #{finding.input.inspect[0, 120]} -> #{id}"
    end
  end
  total += cases.size
  STDERR.puts "fuzz: #{total} cases, #{found.size} findings"
end

exit(found.empty? ? 0 : 1)
