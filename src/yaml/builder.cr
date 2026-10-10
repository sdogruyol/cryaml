# Adapted from Crystal 1.21.0 `src/yaml/builder.cr` (Apache-2.0): runs on
# `YAML::Emitter` (pure Crystal port of libyaml) instead of the libyaml binding.

# A YAML builder generates valid YAML.
#
# A `YAML::Error` is raised if attempting to generate
# an invalid YAML (for example, if invoking `end_sequence`
# without a matching `start_sequence`)
#
# ```
# require "yaml"
#
# string = YAML.build do |yaml|
#   yaml.mapping do
#     yaml.scalar "foo"
#     yaml.sequence do
#       yaml.scalar 1
#       yaml.scalar 2
#     end
#     yaml.scalar "bar"
#     yaml.mapping do
#       yaml.scalar "baz"
#       yaml.scalar "qux"
#     end
#   end
# end
# string # => "---\nfoo:\n- 1\n- 2\nbar:\n  baz: qux\n"
# ```
class YAML::Builder
  # By default the maximum nesting of sequences/mappings is 99. Nesting more
  # than this will result in a YAML::Error. Changing the value of this property
  # allows more/less nesting.
  property max_nesting = 99

  # Creates a `YAML::Builder` that will write to the given `IO`.
  def initialize(@io : IO)
    @emitter = Emitter.new(io)
    @nesting = 0
    @emitter.unicode = true
  end

  # Creates a `YAML::Builder` that writes to *io* and yields it to the block.
  #
  # After returning from the block the builder is closed.
  def self.build(io : IO, & : self ->) : Nil
    builder = new(io)
    yield builder ensure builder.close
  end

  # Starts a YAML stream.
  def start_stream
    emit "stream_start", Event.new(EventKind::STREAM_START)
  end

  # Ends a YAML stream.
  def end_stream : Nil
    emit "stream_end", Event.new(EventKind::STREAM_END)
    flush
  end

  # Starts a YAML stream, invokes the block, and ends it.
  def stream(&)
    start_stream
    yield.tap { end_stream }
  end

  # Starts a document.
  #
  # If *implicit_start_indicator* is true, skips printing the document start
  # indicator (`---`) if this is the first document in the stream.
  def start_document(*, implicit_start_indicator : Bool = false)
    emit "document_start", Event.new(EventKind::DOCUMENT_START, implicit: implicit_start_indicator)
  end

  # Ends a document.
  def end_document
    emit "document_end", Event.new(EventKind::DOCUMENT_END, implicit: true)
  end

  # Starts a document, invokes the block, and then ends it.
  #
  # If *implicit_start_indicator* is true, skips printing the document start
  # indicator (`---`) if this is the first document in the stream.
  def document(*, implicit_start_indicator : Bool = false, &)
    start_document(implicit_start_indicator: implicit_start_indicator)
    yield.tap { end_document }
  end

  # Emits a scalar value.
  def scalar(value, anchor : String? = nil, tag : String? = nil, style : YAML::ScalarStyle = YAML::ScalarStyle::ANY)
    string = value.to_s
    implicit = tag.nil?
    emit "scalar", Event.new(EventKind::SCALAR, anchor: c_string(anchor), tag: c_string(tag), value: string,
      plain_implicit: implicit, quoted_implicit: implicit, scalar_style: style)
  end

  # Starts a sequence.
  def start_sequence(anchor : String? = nil, tag : String? = nil, style : YAML::SequenceStyle = YAML::SequenceStyle::ANY) : Nil
    emit "sequence_start", Event.new(EventKind::SEQUENCE_START, anchor: c_string(anchor), tag: c_string(tag),
      implicit: tag.nil?, sequence_style: style)
    increase_nesting
  end

  # Ends a sequence.
  def end_sequence : Nil
    emit "sequence_end", Event.new(EventKind::SEQUENCE_END)
    decrease_nesting
  end

  # Starts a sequence, invokes the block, and the ends it.
  def sequence(anchor : String? = nil, tag : String? = nil, style : YAML::SequenceStyle = YAML::SequenceStyle::ANY, &)
    start_sequence(anchor, tag, style)
    yield.tap { end_sequence }
  end

  # Starts a mapping.
  def start_mapping(anchor : String? = nil, tag : String? = nil, style : YAML::MappingStyle = YAML::MappingStyle::ANY) : Nil
    emit "mapping_start", Event.new(EventKind::MAPPING_START, anchor: c_string(anchor), tag: c_string(tag),
      implicit: tag.nil?, mapping_style: style)
    increase_nesting
  end

  # Ends a mapping.
  def end_mapping : Nil
    emit "mapping_end", Event.new(EventKind::MAPPING_END)
    decrease_nesting
  end

  # Starts a mapping, invokes the block, and then ends it.
  def mapping(anchor : String? = nil, tag : String? = nil, style : YAML::MappingStyle = YAML::MappingStyle::ANY, &)
    start_mapping(anchor, tag, style)
    yield.tap { end_mapping }
  end

  # Emits an alias to the given *anchor*.
  #
  # ```
  # require "yaml"
  #
  # yaml = YAML.build do |builder|
  #   builder.mapping do
  #     builder.scalar "key"
  #     builder.alias "example"
  #   end
  # end
  #
  # yaml # => "---\nkey: *example\n"
  # ```
  def alias(anchor : String) : Nil
    emit "alias", Event.new(EventKind::ALIAS, anchor: c_string(anchor))
  end

  # Emits the scalar `"<<"` followed by an alias to the given *anchor*.
  #
  # See [YAML Merge](https://yaml.org/type/merge.html).
  #
  # ```
  # require "yaml"
  #
  # yaml = YAML.build do |builder|
  #   builder.mapping do
  #     builder.merge "development"
  #   end
  # end
  #
  # yaml # => "---\n<<: *development\n"
  # ```
  def merge(anchor : String) : Nil
    self.scalar "<<"
    self.alias anchor
  end

  # Flushes any pending data to the underlying `IO`.
  def flush
    @emitter.flush

    @io.flush
  end

  # Closes the builder. Nothing native is held; like libyaml, pending output
  # is not flushed.
  def close : Nil
  end

  # The libyaml binding passed anchors and tags as C strings, which end at the
  # first NUL; keep that.
  private def c_string(string : String?) : String?
    return unless string
    if index = string.byte_index(0_u8)
      string.byte_slice(0, index)
    else
      string
    end
  end

  # Inlined, so *event* is the caller's local and the emitter reads it in
  # place instead of from a copy.
  @[AlwaysInline]
  private def emit(event_name : String, event : Event) : Nil
    # libyaml's event constructors reject malformed UTF-8 (`yaml_check_utf8`).
    # The libyaml binding ignored that failure and re-emitted a stale event,
    # which could crash the process; report it instead.
    unless utf8?(event.anchor) && utf8?(event.tag) && utf8?(event.value)
      raise YAML::Error.new("Error emitting #{event_name}: invalid UTF-8 string")
    end

    unless @emitter.emit(pointerof(event))
      raise YAML::Error.new("Error emitting #{event_name}: #{@emitter.problem}")
    end
  end

  # libyaml `yaml_check_utf8`: well-formed sequences without overlong forms.
  # Unlike `String#valid_encoding?` it accepts encoded surrogates and code
  # points above U+10FFFF, which the emitter writes as escapes.
  private def utf8?(string : String?) : Bool
    return true unless string
    bytes = string.to_slice
    i = 0
    while i < bytes.size
      # Fast path: eight ASCII bytes at once.
      if bytes.size - i >= 8
        word = uninitialized UInt64
        pointerof(word).as(Pointer(UInt8)).copy_from(bytes.to_unsafe + i, 8)
        if word & 0x8080808080808080_u64 == 0
          i += 8
          next
        end
      end
      octet = bytes[i]
      if octet < 0x80
        i += 1
        next
      end
      width = Chars.width(bytes.to_unsafe, i)
      return false if width == 0 || i + width > bytes.size
      value = (width == 1 ? octet & 0x7F : width == 2 ? octet & 0x1F : width == 3 ? octet & 0x0F : octet & 0x07).to_u32
      (1...width).each do |k|
        octet = bytes[i + k]
        return false if octet & 0xC0 != 0x80
        value = (value << 6) + (octet & 0x3F)
      end
      return false unless width == 1 || (width == 2 && value >= 0x80) ||
                          (width == 3 && value >= 0x800) || (width == 4 && value >= 0x10000)
      i += width
    end
    true
  end

  private def increase_nesting
    @nesting += 1
    if @nesting > @max_nesting
      raise YAML::Error.new("Nesting of #{@nesting} is too deep")
    end
  end

  private def decrease_nesting
    @nesting -= 1
  end
end

module YAML
  # Returns the resulting String of writing YAML to the yielded `YAML::Builder`.
  #
  # ```
  # require "yaml"
  #
  # string = YAML.build do |yaml|
  #   yaml.mapping do
  #     yaml.scalar "foo"
  #     yaml.sequence do
  #       yaml.scalar 1
  #       yaml.scalar 2
  #     end
  #   end
  # end
  # string # => "---\nfoo:\n- 1\n- 2\n"
  # ```
  def self.build(&)
    String.build do |str|
      build(str) do |yaml|
        yield yaml
      end
    end
  end

  # Writes YAML into the given `IO`. A `YAML::Builder` is yielded to the block.
  def self.build(io : IO, &) : Nil
    YAML::Builder.build(io) do |yaml|
      yaml.stream do
        yaml.document do
          yield yaml
        end
      end
    end
  end
end
