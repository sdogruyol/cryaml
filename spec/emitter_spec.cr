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
end
