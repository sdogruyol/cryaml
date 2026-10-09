require "./spec_helper"

# Token streams below were produced by libyaml 0.2.5's `yaml_parser_scan`.
# Marks are "index,line,column" (zero-based, in characters).
private def scan(input : String | IO) : String
  scanner = YAML::Scanner.new(input)
  String.build do |io|
    loop do
      token = scanner.peek_token
      io << token.kind << ' ' << mark(token.start_mark) << ' ' << mark(token.end_mark)
      case token.kind
      when .alias?, .anchor?      then io << ' ' << token.value.inspect
      when .tag?, .tag_directive? then io << ' ' << token.handle.inspect << ' ' << token.value.inspect
      when .scalar?               then io << ' ' << token.value.inspect << ' ' << token.style
      when .version_directive?    then io << ' ' << token.major << '.' << token.minor
      else # no payload
      end
      io << '\n'
      scanner.skip_token
      break if token.kind.stream_end?
    end
  rescue ex : YAML::ParseException
    io << "ERR " << ex.message << '\n'
  end
end

private def mark(mark : YAML::Mark) : String
  "#{mark.index},#{mark.line},#{mark.column}"
end

describe YAML::Scanner do
  it "scans block collections" do
    scan("key: value\nlist:\n  - a\n  - b\n").should eq <<-TOKENS
      STREAM_START 0,0,0 0,0,0
      BLOCK_MAPPING_START 0,0,0 0,0,0
      KEY 0,0,0 0,0,0
      SCALAR 0,0,0 3,0,3 "key" PLAIN
      VALUE 3,0,3 4,0,4
      SCALAR 5,0,5 10,0,10 "value" PLAIN
      KEY 11,1,0 11,1,0
      SCALAR 11,1,0 15,1,4 "list" PLAIN
      VALUE 15,1,4 16,1,5
      BLOCK_SEQUENCE_START 19,2,2 19,2,2
      BLOCK_ENTRY 19,2,2 20,2,3
      SCALAR 21,2,4 22,2,5 "a" PLAIN
      BLOCK_ENTRY 25,3,2 26,3,3
      SCALAR 27,3,4 28,3,5 "b" PLAIN
      BLOCK_END 29,4,0 29,4,0
      BLOCK_END 29,4,0 29,4,0
      STREAM_END 29,4,0 29,4,0\n
      TOKENS
  end

  it "scans flow collections, inserting KEY tokens for simple keys" do
    scan("{a: [1, 2], b: {c: d}}").should eq <<-TOKENS
      STREAM_START 0,0,0 0,0,0
      FLOW_MAPPING_START 0,0,0 1,0,1
      KEY 1,0,1 1,0,1
      SCALAR 1,0,1 2,0,2 "a" PLAIN
      VALUE 2,0,2 3,0,3
      FLOW_SEQUENCE_START 4,0,4 5,0,5
      SCALAR 5,0,5 6,0,6 "1" PLAIN
      FLOW_ENTRY 6,0,6 7,0,7
      SCALAR 8,0,8 9,0,9 "2" PLAIN
      FLOW_SEQUENCE_END 9,0,9 10,0,10
      FLOW_ENTRY 10,0,10 11,0,11
      KEY 12,0,12 12,0,12
      SCALAR 12,0,12 13,0,13 "b" PLAIN
      VALUE 13,0,13 14,0,14
      FLOW_MAPPING_START 15,0,15 16,0,16
      KEY 16,0,16 16,0,16
      SCALAR 16,0,16 17,0,17 "c" PLAIN
      VALUE 17,0,17 18,0,18
      SCALAR 19,0,19 20,0,20 "d" PLAIN
      FLOW_MAPPING_END 20,0,20 21,0,21
      FLOW_MAPPING_END 21,0,21 22,0,22
      STREAM_END 22,1,0 22,1,0\n
      TOKENS
  end

  it "scans directives, tags, anchors and document markers" do
    scan("%YAML 1.1\n%TAG !e! tag:example.com,2000:\n--- !e!foo &x bar\n...\n").should eq <<-TOKENS
      STREAM_START 0,0,0 0,0,0
      VERSION_DIRECTIVE 0,0,0 9,0,9 1.1
      TAG_DIRECTIVE 10,1,0 40,1,30 "!e!" "tag:example.com,2000:"
      DOCUMENT_START 41,2,0 44,2,3
      TAG 45,2,4 51,2,10 "!e!" "foo"
      ANCHOR 52,2,11 54,2,13 "x"
      SCALAR 55,2,14 58,2,17 "bar" PLAIN
      DOCUMENT_END 59,3,0 62,3,3
      STREAM_END 63,4,0 63,4,0\n
      TOKENS
  end

  it "scans aliases and quoted scalars with escapes" do
    scan(%(- *x\n- !!str 'single ''q'''\n- "double\\tq\\u00e9"\n)).should eq <<-TOKENS
      STREAM_START 0,0,0 0,0,0
      BLOCK_SEQUENCE_START 0,0,0 0,0,0
      BLOCK_ENTRY 0,0,0 1,0,1
      ALIAS 2,0,2 4,0,4 "x"
      BLOCK_ENTRY 5,1,0 6,1,1
      TAG 7,1,2 12,1,7 "!!" "str"
      SCALAR 13,1,8 27,1,22 "single 'q'" SINGLE_QUOTED
      BLOCK_ENTRY 28,2,0 29,2,1
      SCALAR 30,2,2 47,2,19 "double\\tqé" DOUBLE_QUOTED
      BLOCK_END 48,3,0 48,3,0
      STREAM_END 48,3,0 48,3,0\n
      TOKENS
  end

  it "scans literal and folded block scalars with chomping" do
    scan("lit: |-\n  one\n  two\nfold: >\n  a\n  b\n").should eq <<-TOKENS
      STREAM_START 0,0,0 0,0,0
      BLOCK_MAPPING_START 0,0,0 0,0,0
      KEY 0,0,0 0,0,0
      SCALAR 0,0,0 3,0,3 "lit" PLAIN
      VALUE 3,0,3 4,0,4
      SCALAR 5,0,5 20,3,0 "one\\ntwo" LITERAL
      KEY 20,3,0 20,3,0
      SCALAR 20,3,0 24,3,4 "fold" PLAIN
      VALUE 24,3,4 25,3,5
      SCALAR 26,3,6 36,6,0 "a b\\n" FOLDED
      BLOCK_END 36,6,0 36,6,0
      STREAM_END 36,6,0 36,6,0\n
      TOKENS
  end

  it "reads IO input the same way as String input" do
    input = "? complex\n: value\n"
    scan(IO::Memory.new(input)).should eq(scan(input))
    scan(input).should eq <<-TOKENS
      STREAM_START 0,0,0 0,0,0
      BLOCK_MAPPING_START 0,0,0 0,0,0
      KEY 0,0,0 1,0,1
      SCALAR 2,0,2 9,0,9 "complex" PLAIN
      VALUE 10,1,0 11,1,1
      SCALAR 12,1,2 17,1,7 "value" PLAIN
      BLOCK_END 18,2,0 18,2,0
      STREAM_END 18,2,0 18,2,0\n
      TOKENS
  end

  it "reports libyaml's errors with problem and context positions" do
    scan("a: b: c").lines.last.should eq("ERR mapping values are not allowed in this context at line 1, column 5")
    scan(%("unterminated)).lines.last.should eq(
      "ERR found unexpected end of stream at line 1, column 14, while scanning a quoted scalar at line 1, column 1")
    scan("\tkey: v").lines.last.should eq(
      "ERR found character that cannot start any token at line 1, column 1, while scanning for the next token at line 1, column 1")
    scan("a: \xff").should eq("ERR invalid leading UTF-8 octet at line 1, column 1\n")
  end

  it "keeps raising the same error once it failed" do
    scanner = YAML::Scanner.new("a: b: c")
    first = expect_raises(YAML::ParseException) do
      loop do
        scanner.peek_token
        scanner.skip_token
      end
    end
    expect_raises(YAML::ParseException, first.message) { scanner.peek_token }
  end
end
