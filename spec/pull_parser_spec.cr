require "./spec_helper"

# A `String` input's ASCII scalars that need no folding or escapes stay in the
# input until `PullParser#value` asks for them (`Token.input_scalar`), until
# the first value is read; an `IO` input's are always made at once. These
# specs check that how a value is made never shows.

private LAZY_INPUT = <<-YAML
  plain: value
  "double": 'single'
  multi word: two
    lines
  é: ünïcödé
  empty: ''
  empty2: ""
  escaped: "a\\tb"
  folded: >
    x
    y
  anchored: &a anchored value
  tagged: !!str 12
  alias: *a
  flow: [a, "b", 'c', {d: e}]
  YAML

# The values of every *nth* scalar (the others are skipped without being
# read), with their events' positions, as `{line, column, value}`.
private def values(input : String | IO, nth = 1) : Array({Int32, Int32, String})
  parser = YAML::PullParser.new(input)
  values = [] of {Int32, Int32, String}
  i = 0
  until parser.kind.stream_end?
    if parser.kind.scalar?
      values << {parser.start_line, parser.start_column, parser.value} if (i + 1) % nth == 0
      i += 1
    end
    parser.read_next
  end
  values
end

# `String#size` must not depend on a precomputed character count.
private def check_size(string : String) : Nil
  string.size.should eq(string.each_char.size)
  String.new(string.to_slice).size.should eq(string.size)
end

describe YAML::PullParser do
  it "reads the same values from a String and from an IO" do
    expected = values(IO::Memory.new(LAZY_INPUT))
    expected.map(&.[2]).should eq([
      "plain", "value", "double", "single", "multi word", "two lines",
      "é", "ünïcödé", "empty", "", "empty2", "", "escaped", "a\tb",
      "folded", "x y\n", "anchored", "anchored value", "tagged", "12",
      "alias", "flow", "a", "b", "c", "d", "e",
    ])
    values(LAZY_INPUT).should eq(expected)
    expected.each { |(_, _, value)| check_size(value) }
    values(LAZY_INPUT).each { |(_, _, value)| check_size(value) }
  end

  it "reads values after skipping some without reading them" do
    all = values(LAZY_INPUT)
    {2, 3, 5, 7, 100}.each do |nth|
      expected = all.each_slice(nth).select(&.size.==(nth)).map(&.last).to_a
      values(LAZY_INPUT, nth).should eq(expected)
      values(IO::Memory.new(LAZY_INPUT), nth).should eq(expected)
    end
  end

  it "reads the first value after walking most of the document" do
    parser = YAML::PullParser.new(LAZY_INPUT)
    # Up to "d" in `flow: [a, "b", 'c', {d: e}]`.
    until parser.kind.scalar? && parser.start_line == 15 && parser.start_column == 22
      parser.read_next
    end
    parser.value.should eq("d")
    parser.read_next
    parser.value.should eq("e")
    check_size(parser.value)
  end

  it "returns equal values when asked twice" do
    parser = YAML::PullParser.new("[abc, 'dé', \"x\"]")
    3.times { parser.read_next }
    %w(abc dé x).each do |expected|
      first = parser.value
      first.should eq(expected)
      parser.value.should eq(first)
      check_size(parser.value)
      parser.read_next
    end
    parser.kind.sequence_end?.should be_true
  end

  it "returns the current event's value only" do
    parser = YAML::PullParser.new("- abc\n- [def]\n")
    parser.read_stream_start
    parser.read_document_start
    parser.read_sequence_start
    parser.kind.scalar?.should be_true
    parser.read_next
    # The unread "abc" is gone: the parser is at the inner sequence.
    expect_raises(YAML::ParseException, "Expected SCALAR but was SEQUENCE_START") { parser.value }
    parser.read_next
    parser.value.should eq("def")
    parser.read_next
    expect_raises(YAML::ParseException, "Expected SCALAR but was SEQUENCE_END") { parser.value }
  end

  it "keeps returned values valid as parsing goes on" do
    input = "[" + (1..200).join(", ") { |i| "v#{i}" } + "]"
    parser = YAML::PullParser.new(input)
    3.times { parser.read_next }
    read = [] of String
    while parser.kind.scalar?
      read << parser.value
      parser.read_next
    end
    read.should eq((1..200).map { |i| "v#{i}" })
  end

  it "reads values before an error" do
    {"a: b\nc: d: e\n", "[a, b, 'c', d: e: f]", "x: \"abc\n...\n"}.each do |input|
      {1, 2}.each do |nth|
        read = {String, IO}.map do |type|
          parser = YAML::PullParser.new(type == String ? input : IO::Memory.new(input))
          values = [] of String
          i = 0
          error = expect_raises(YAML::ParseException) do
            loop do
              values << parser.value if parser.kind.scalar? && (i += 1) % nth == 0
              parser.read_next
            end
          end
          expect_raises(YAML::ParseException, "Expected SCALAR but was NONE") { parser.value }
          {values, error.message}
        end
        read[0].should eq(read[1])
        read[0][0].should_not be_empty if nth == 1
      end
    end
  end

  it "parses values left in the input like the others" do
    YAML.parse(LAZY_INPUT).to_yaml.should eq(YAML.parse(IO::Memory.new(LAZY_INPUT)).to_yaml)
    nodes = ->(input : String | IO) { YAML.build { |builder| YAML::Nodes.parse(input).to_yaml(builder) } }
    nodes.call(LAZY_INPUT).should eq(nodes.call(IO::Memory.new(LAZY_INPUT)))
  end
end
