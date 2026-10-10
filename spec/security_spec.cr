require "./spec_helper"

# Hostile inputs: none of these may crash, overflow the stack, or run away in
# time or memory.
describe "hostile input" do
  describe "deep nesting" do
    it "rejects flow nesting beyond PullParser#max_nesting without recursing" do
      input = "[" * 100_000 + "]" * 100_000
      expect_raises(YAML::ParseException, "Nesting of 513 is too deep") do
        YAML.parse(input)
      end
    end

    it "rejects block nesting beyond PullParser#max_nesting" do
      input = String.build do |io|
        600.times { |i| io << " " * i << "- \n" }
        io << " " * 600 << "x\n"
      end
      expect_raises(YAML::ParseException, "Nesting of 513 is too deep") do
        YAML.parse(input)
      end
    end

    it "scans a deeply nested flow stream event by event without a nesting limit in the engine" do
      depth = 50_000
      parser = YAML::PullParser.new("[" * depth + "]" * depth)
      parser.max_nesting = Int32::MAX
      starts = 0
      until parser.kind.stream_end?
        starts += 1 if parser.kind.sequence_start?
        parser.read_next
      end
      starts.should eq(depth)
    end

    it "accepts nesting right at the limit" do
      input = "[" * 512 + "]" * 512
      YAML.parse(input).should_not be_nil
    end
  end

  describe "alias expansion (billion laughs)" do
    laughs = String.build do |io|
      io << "a: &a [\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\"]\n"
      prev = 'a'
      ('b'..'i').each do |name|
        io << name << ": &" << name << " ["
        io << (["*#{prev}"] * 9).join(',') << "]\n"
        prev = name
      end
    end

    it "rejects excessive aliasing in YAML.parse" do
      expect_raises(YAML::ParseException, "Document contains excessive aliasing") do
        YAML.parse(laughs)
      end
    end

    it "rejects excessive aliasing in from_yaml" do
      expect_raises(YAML::ParseException, "Document contains excessive aliasing") do
        Hash(String, Array(YAML::Any)).from_yaml(laughs)
      end
    end

    it "shares aliased values instead of copying them" do
      doc = YAML.parse("a: &x [1, 2]\nb: *x\n")
      doc["a"].as_a.should be(doc["b"].as_a)
    end

    it "still allows ordinary alias use" do
      input = String.build do |io|
        io << "base: &base {x: 1}\n"
        200.times { |i| io << "k" << i << ": *base\n" }
      end
      YAML.parse(input)["k199"]["x"].should eq(1)
    end

    # An anchor's cost is the number of aliases inside it, not the number
    # seen before it: `&c` holds 10 aliases, and 20 more precede it. With
    # n aliases of `*c` the document has 30 + 11n aliases and 32 + n anchors
    # (aliases count as anchors), so n = 290 is the last accepted. Expected
    # results recorded from the stdlib's libyaml binding (Crystal 1.21).
    alias_limit = ->(n : Int32) do
      String.build do |io|
        io << "s: &s x\nl: [" << (["*s"] * 20).join(", ") << "]\n"
        io << "c: &c [" << (["*s"] * 10).join(", ") << "]\n"
        io << "r: [" << (["*c"] * n).join(", ") << "]\n"
      end
    end

    it "accepts aliasing right at the alias/anchor limit" do
      YAML.parse(alias_limit.call(290))["r"].as_a.size.should eq(290)
    end

    it "rejects aliasing one alias past the limit" do
      expect_raises(YAML::ParseException, "Document contains excessive aliasing at line 4, column 1165") do
        YAML.parse(alias_limit.call(291))
      end
    end
  end

  describe "large scalars and long lines" do
    it "parses a multi-megabyte plain scalar" do
      value = "x" * 8_000_000
      YAML.parse("key: #{value}\n")["key"].as_s.bytesize.should eq(8_000_000)
    end

    it "parses a multi-megabyte double-quoted scalar with escapes" do
      body = "ab\\n" * 1_000_000
      YAML.parse(%("#{body}")).as_s.bytesize.should eq(3_000_000)
    end

    it "parses a multi-megabyte literal block scalar" do
      body = String.build { |io| 200_000.times { io << "  line of text\n" } }
      YAML.parse("|\n#{body}").as_s.bytesize.should eq(200_000 * 13)
    end

    it "parses a single line holding 100k flow items" do
      input = "[" + (["item"] * 100_000).join(", ") + "]"
      YAML.parse(input).as_a.size.should eq(100_000)
    end

    it "rejects a simple key longer than 1024 characters, like libyaml" do
      expect_raises(YAML::ParseException, "mapping values are not allowed in this context at line 1, column 2001") do
        YAML.parse("#{"k" * 2000}: v\n")
      end
    end
  end

  describe "malformed encodings" do
    it "rejects invalid UTF-8" do
      expect_raises(YAML::ParseException, "invalid leading UTF-8 octet") do
        YAML.parse("a: \xff\n")
      end
    end

    it "rejects control characters" do
      expect_raises(YAML::ParseException, "control characters are not allowed") do
        YAML.parse("a: \u0001\n")
      end
    end

    it "rejects a truncated UTF-16 stream" do
      expect_raises(YAML::ParseException, "incomplete UTF-16 character") do
        YAML.parse(IO::Memory.new(Bytes[0xFF, 0xFE, 'a'.ord, 0, 'b'.ord]))
      end
    end
  end

  describe "builder" do
    it "rejects emitting nesting beyond Builder#max_nesting" do
      expect_raises(YAML::Error, "Nesting of 100 is too deep") do
        YAML.build do |yaml|
          nest = uninitialized Proc(Int32, Nil)
          nest = ->(depth : Int32) do
            yaml.sequence { nest.call(depth + 1) if depth < 200 }
            nil
          end
          nest.call(0)
        end
      end
    end

    it "rejects invalid UTF-8 instead of emitting it" do
      expect_raises(YAML::Error, "invalid UTF-8") do
        YAML.dump("\xff")
      end
    end
  end
end
