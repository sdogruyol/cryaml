require "./spec_helper"

private class FailOnceIO < IO
  getter written = [] of String
  @failed = false

  def read(slice : Bytes) : Int32
    raise IO::Error.new("write-only")
  end

  def write(slice : Bytes) : Nil
    unless @failed
      @failed = true
      raise IO::Error.new("disk full")
    end
    @written << String.new(slice)
  end
end

private class WriteSizesIO < IO
  getter sizes = [] of Int32

  def read(slice : Bytes) : Int32
    raise IO::Error.new("write-only")
  end

  def write(slice : Bytes) : Nil
    @sizes << slice.size
  end
end

describe YAML::Builder do
  # libyaml empties its buffer before calling the write handler, so output
  # that failed to write is dropped, not written again by the next flush.
  it "does not write output again after the IO failed" do
    io = FailOnceIO.new
    builder = YAML::Builder.new(io)
    builder.start_stream
    builder.start_document
    builder.scalar "a"
    expect_raises(IO::Error, "disk full") { builder.end_document }
    builder.flush
    io.written.should be_empty
  end

  # A tag's %-escapes can decode to bytes libyaml's yaml_check_utf8 rejects
  # (here an overlong sequence). Re-emitting such a node used to send a
  # stale event through the binding; cryaml reports it.
  it "raises on a tag that is not valid UTF-8 after %-decoding" do
    document = YAML::Nodes.parse("!<tag:%C0%A9> v")
    expect_raises(YAML::Error, "Error emitting scalar: invalid UTF-8 string") do
      YAML::Builder.build(IO::Memory.new) do |builder|
        builder.stream { document.to_yaml(builder) }
      end
    end
  end

  # yaml_check_utf8 rejects overlong forms (here also behind eight ASCII
  # bytes, past the fast path) in values, anchors and tags. The libyaml
  # binding ignored that failure (see above), so this is cryaml's own check;
  # the shortest forms around them are accepted.
  {"\xE0\x82\x80", "abcdefgh\xE0\x82\x80", "\xE0\x9F\xBF", "\xC1\xBF", "abcdefgh\xC1\xBF", "\xF0\x8F\xBF\xBF"}.each do |bytes|
    it "raises on the overlong UTF-8 sequence #{bytes.inspect}" do
      {
        ->(b : YAML::Builder) { b.scalar(bytes) },
        ->(b : YAML::Builder) { b.scalar("x", anchor: "a#{bytes}") },
        ->(b : YAML::Builder) { b.scalar("x", tag: "!a#{bytes}") },
      }.each do |call|
        expect_raises(YAML::Error, "Error emitting scalar: invalid UTF-8 string") do
          YAML::Builder.build(IO::Memory.new) { |builder| builder.stream { builder.document { call.call(builder) } } }
        end
      end
    end
  end

  it "accepts the shortest UTF-8 forms (output recorded from the libyaml binding)" do
    YAML.dump(["\u0080", "\u0800", "\u{10000}"]).should eq("---\n- \"\\x80\"\n- \u0800\n- \"\\U00010000\"\n")
  end

  # libyaml flushes its 16 KiB output buffer when fewer than 5 bytes are
  # free (`FLUSH`), so a large document reaches the IO in writes of this
  # exact size. Sizes recorded from the stdlib's libyaml binding.
  it "writes to the IO in chunks of libyaml's sizes" do
    io = WriteSizesIO.new
    YAML.build(io) do |yaml|
      yaml.sequence do
        3000.times { |i| yaml.scalar "item number #{i}" }
      end
    end
    io.sizes.should eq([16379, 16379, 16379, 6757])
  end
end
