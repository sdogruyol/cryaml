require "spec"
require "../src/cryaml"
require "./support/differential"

# Random `YAML::Builder` call sequences (see `CryamlDump.build`), emitted by
# cryaml and by the stdlib's libyaml binding; the output must be identical.
private module BuildScripts
  VALUES = [
    "", " ", "a", "foo", "foo bar", " lead", "trail ", " both ", "a\nb", "a\n\nb", "\n", "a\n",
    "a\n\n", "\nlead", "a \nb", "a\n b", "tab\there", "\t", "it's", "say \"hi\"", "'q'", "\"",
    "# comment", "a # b", "a#b", "key: value", "a:b", ":", "- item", "-", "--", "---", "...",
    "? x", "?x", "[a]", "{b}", "a,b", "&anchor", "*alias", "!tag", "|", ">", "%", "@", "`",
    "null", "~", "true", "false", "yes", "no", "1", "1.0", "-1", "0x1F", ".inf", ".nan", "<<",
    "héllo", "日本語", "emoji 😀", "\u00A0nbsp", "\u0085nel", "line\u2028sep", "bom\uFEFF",
    "\u0001ctl", "\u007F", "back\\slash", "a\r\nb", "trailing\n\n\n", "x\u00e9\n",
    "word " * 30, "longword" * 15, ("abc def " * 12) + "\nnext  line " * 3, " " * 5,
    "a  b", "a   \n  b", "\n\n", "  \n  ",
  ]
  ANCHORS = [nil, nil, nil, "a1", "anchor", "x-y_z"]
  TAGS    = [nil, nil, nil, nil, "!foo", "tag:yaml.org,2002:str", "!!int", "tag:yaml.org,2002:map",
             "tag:yaml.org,2002:seq", "!", "!a%20b", "http://example.com/t", "tag:example.com,2000:é"]

  def self.esc(s : String?) : String
    s.nil? ? "-" : CryamlDump.build_escape(s)
  end

  def self.node(rng : Random, lines : Array(String), depth : Int32) : Nil
    roll = rng.rand(10)
    if depth >= 4 || roll < 5
      if roll == 0 && depth > 0
        lines << "alias #{esc(ANCHORS[3 + rng.rand(3)])}"
      else
        style = YAML::ScalarStyle.values.sample(rng)
        lines << "scalar #{style} #{esc(ANCHORS.sample(rng))} #{esc(TAGS.sample(rng))} #{esc(VALUES.sample(rng))}"
      end
    elsif roll < 8
      style = rng.rand(3) == 0 ? "FLOW" : (rng.rand(2) == 0 ? "BLOCK" : "ANY")
      lines << "seq_start #{style} #{esc(ANCHORS.sample(rng))} #{esc(TAGS.sample(rng))}"
      rng.rand(4).times { node(rng, lines, depth + 1) }
      lines << "seq_end"
    else
      style = rng.rand(3) == 0 ? "FLOW" : (rng.rand(2) == 0 ? "BLOCK" : "ANY")
      lines << "map_start #{style} #{esc(ANCHORS.sample(rng))} #{esc(TAGS.sample(rng))}"
      rng.rand(4).times do
        node(rng, lines, depth + 1)
        node(rng, lines, depth + 1)
      end
      lines << "map_end"
    end
  end

  def self.script(rng : Random) : String
    lines = ["stream_start"]
    (1 + rng.rand(2)).times do
      lines << "doc_start #{rng.rand(2) == 0 ? "implicit" : "explicit"}"
      node(rng, lines, 0)
      lines << "doc_end"
    end
    lines << "stream_end"
    lines.join('\n')
  end

  INVALID = [
    "stream_start\ndoc_start explicit\nalias \"\"\ndoc_end\nstream_end",
    "stream_start\ndoc_start explicit\nscalar ANY \"\" - x\ndoc_end",
    "stream_start\ndoc_start explicit\nscalar ANY bad! - x\ndoc_end",
    "stream_start\ndoc_start explicit\nalias bad\\sname\ndoc_end",
    "stream_start\ndoc_start explicit\nscalar ANY - \"\" x\ndoc_end",
    "stream_start\ndoc_start explicit\nseq_end",
    "stream_start\ndoc_start explicit\nmap_end",
    "stream_start\ndoc_end",
    "stream_start\nseq_start ANY - -",
    "stream_start\nstream_end\nstream_start",
    "stream_start\nstream_end\nstream_end",
    "stream_start\ndoc_start explicit\nscalar ANY - - a\nscalar ANY - - b",
    "stream_start\ndoc_start explicit\nscalar ANY - - a\ndoc_end\ndoc_end",
    "stream_start\ndoc_start explicit\nseq_start ANY - -\nscalar ANY - - a\nmap_end",
    "stream_start\ndoc_start explicit\nmap_start ANY - -\nscalar ANY - - a\nseq_end",
    "stream_start\ndoc_start explicit\nmap_start ANY - -\nscalar ANY - - a\nmap_end",
    "stream_start\ndoc_start explicit\nscalar LITERAL - - a\\n\\n\ndoc_end\nstream_end",
    "stream_start\ndoc_start implicit\nscalar LITERAL - - a\\n\\n\ndoc_end\ndoc_start implicit\nscalar ANY - - b\ndoc_end\nstream_end",
    "stream_start\ndoc_start implicit\nscalar PLAIN - - a\ndoc_end\ndoc_start implicit\nscalar FOLDED - - \\n\ndoc_end\nstream_end",
    "stream_start\ndoc_start implicit\nscalar ANY - - a\nstream_end",
  ]

  # Byte strings libyaml's `yaml_check_utf8` accepts although they are not
  # valid UTF-8 for Crystal: encoded surrogates and code points above
  # U+10FFFF. The emitter writes them as escapes.
  ODD_BYTES = ["a\\x{ed}\\x{a0}\\x{80}b", "\\x{f4}\\x{90}\\x{80}\\x{80}", "\\x{f7}\\x{bf}\\x{bf}\\x{bf}",
               "\\x{f5}\\x{80}\\x{80}\\x{80}", "\\x{ed}\\x{bf}\\x{bf}"]

  def self.odd_byte_scripts : Array(String)
    ODD_BYTES.flat_map do |value|
      ["ANY", "PLAIN", "DOUBLE_QUOTED", "SINGLE_QUOTED", "LITERAL"].map do |style|
        "stream_start\ndoc_start implicit\nmap_start BLOCK - -\nscalar #{style} - - #{value}\n" \
        "scalar #{style} - !a#{value} #{value}\nmap_end\ndoc_end\nstream_end"
      end
    end
  end
end

describe "builder differential (cryaml vs libyaml)" do
  rng = Random.new(20261009)
  cases = [] of Differential::Case
  400.times do |i|
    cases << Differential::Case.new("random-#{i}", "build", BuildScripts.script(rng))
  end
  BuildScripts::INVALID.each_with_index do |script, i|
    cases << Differential::Case.new("invalid-#{i}", "build", script)
  end
  BuildScripts.odd_byte_scripts.each_with_index do |script, i|
    cases << Differential::Case.new("odd-bytes-#{i}", "build", script)
  end
  Differential.compare("builder", cases)
end
