# Adapted from Crystal 1.21.0 `src/yaml/pull_parser.cr` (Apache-2.0): runs on
# `YAML::EventParser` (pure Crystal port of libyaml) instead of the libyaml binding.

# A pull parser allows parsing a YAML document by events.
#
# When creating an instance, the parser is positioned in
# the first event. To get the event kind invoke `kind`.
# If the event is a scalar you can invoke `value` to get
# its **string** value. Other methods like `tag`, `anchor`
# and `scalar_style` let you inspect other information from events.
#
# Invoking `read_next` reads the next event.
class YAML::PullParser
  protected getter content

  # :nodoc:
  #
  # Maximum structural depth (nested sequences and mappings) allowed.
  property max_nesting = 512

  # :nodoc:
  #
  # If true, evaluates the alias/anchor ratio to avoid excessive expansion of
  # aliases.
  property enforce_alias_anchor_ratio = true

  # :nodoc:
  #
  # Minimum number of aliases required before starting to evaluate the
  # alias/anchor ratio. This avoids affecting smaller documents.
  property alias_anchor_min_aliases = 100

  # :nodoc:
  #
  # The multiplier for the alias/anchor ratio evaluation. An error will be
  # raised when `aliases > multiplier * anchors` once `min_aliases` has been
  # reached.
  property alias_anchor_multiplier = 10

  # Created by the first anchor that needs them: most documents have none.
  @anchor_scope : Hash(Int32, {String, Int32})? = nil
  @anchor_costs : Hash(String, Int32)? = nil

  def initialize(@content : String | IO)
    @parser = EventParser.new(content)

    @nesting = 0
    @anchors = 0
    @aliases = 0

    read_next
    raise "Expected STREAM_START" unless kind.stream_start?
  end

  # Creates a parser, yields it to the block, and closes
  # the parser at the end of it.
  def self.new(content, &)
    parser = new(content)
    yield parser ensure parser.close
  end

  # The current event kind.
  def kind : EventKind
    @parser.event.kind
  end

  # Returns the tag associated to the current event, or `nil`
  # if there's no tag.
  def tag : String?
    case kind
    when .mapping_start?, .sequence_start?, .scalar?
      @parser.event.tag
    else
      # no tag
    end
  end

  # Returns the scalar value, assuming the pull parser
  # is located at a scalar. Raises otherwise.
  def value : String
    expect_kind EventKind::SCALAR

    @parser.event.value
  end

  # Returns the anchor associated to the current event, or `nil`
  # if there's no anchor.
  getter anchor : String?

  # Returns the sequence style, assuming the pull parser is located
  # at a sequence begin event. Raises otherwise.
  def sequence_style : SequenceStyle
    expect_kind EventKind::SEQUENCE_START
    @parser.event.sequence_style
  end

  # Returns the mapping style, assuming the pull parser is located
  # at a mapping begin event. Raises otherwise.
  def mapping_style : MappingStyle
    expect_kind EventKind::MAPPING_START
    @parser.event.mapping_style
  end

  # Returns the scalar style, assuming the pull parser is located
  # at a scalar event. Raises otherwise.
  def scalar_style : ScalarStyle
    expect_kind EventKind::SCALAR
    @parser.event.scalar_style
  end

  # Reads the next event.
  def read_next : EventKind
    # As with libyaml, a failed read leaves an empty (NONE) event behind
    # (`EventParser#parse` sees to that).
    @parser.parse

    read_anchor
    @anchors += 1 if @anchor

    case kind
    when EventKind::SEQUENCE_START, EventKind::MAPPING_START
      increase_nesting
    when EventKind::SEQUENCE_END, EventKind::MAPPING_END
      decrease_nesting
    when EventKind::ALIAS
      increase_alias
    end

    kind
  end

  # Reads a "stream start" event, yields to the block,
  # and then reads a "stream end" event.
  def read_stream(&)
    read_stream_start
    value = yield
    read_stream_end
    value
  end

  # Reads a "document start" event, yields to the block,
  # and then reads a "document end" event.
  def read_document(&)
    read_document_start
    value = yield
    read_document_end
    value
  end

  # Reads a "sequence start" event, yields to the block,
  # and then reads a "sequence end" event.
  def read_sequence(&)
    read_sequence_start
    value = yield
    read_sequence_end
    value
  end

  # Reads a "mapping start" event, yields to the block,
  # and then reads a "mapping end" event.
  def read_mapping(&)
    read_mapping_start
    value = yield
    read_mapping_end
    value
  end

  # Reads an alias event, returning its anchor.
  def read_alias : String?
    expect_kind EventKind::ALIAS
    anchor = @anchor
    read_next
    anchor
  end

  # Reads a scalar, returning its value.
  def read_scalar : String
    expect_kind EventKind::SCALAR
    value = self.value
    read_next
    value
  end

  # Reads a "stream start" event.
  def read_stream_start
    read EventKind::STREAM_START
  end

  # Reads a "stream end" event.
  def read_stream_end
    read EventKind::STREAM_END
  end

  # Reads a "document start" event.
  def read_document_start
    read EventKind::DOCUMENT_START
  end

  # Reads a "document end" event.
  def read_document_end
    read EventKind::DOCUMENT_END
  end

  # Reads a "sequence start" event.
  def read_sequence_start
    read EventKind::SEQUENCE_START
  end

  # Reads a "sequence end" event.
  def read_sequence_end
    read EventKind::SEQUENCE_END
  end

  # Reads a "mapping start" event.
  def read_mapping_start
    read EventKind::MAPPING_START
  end

  # Reads a "mapping end" event.
  def read_mapping_end
    read EventKind::MAPPING_END
  end

  # Reads an expected event kind.
  def read(expected_kind : EventKind) : EventKind
    expect_kind expected_kind
    read_next
  end

  def skip : YAML::EventKind
    case kind
    when .scalar?
      read_next
    when .alias?
      read_next
    when .sequence_start?
      read_next
      until kind.sequence_end?
        skip
      end
      read_next
    when .mapping_start?
      read_next
      until kind.mapping_end?
        skip
        skip
      end
      read_next
    when .document_start?
      read_next
      until kind.document_end?
        skip
      end
      read_next
    when .stream_start?
      read_next
      until kind.stream_end?
        skip
      end
      read_next
    else
      read_next
    end
  end

  # Note: YAML starts counting from 0, we want to count from 1

  def location : {Int32, Int32}
    {start_line, start_column}
  end

  def start_line : Int32
    @parser.event.start_mark.line.to_i32 + 1
  end

  def start_column : Int32
    @parser.event.start_mark.column.to_i32 + 1
  end

  def end_line : Int32
    @parser.event.end_mark.line.to_i32 + 1
  end

  def end_column : Int32
    @parser.event.end_mark.column.to_i32 + 1
  end

  # Closes the parser. Nothing native is held, so there is nothing to free.
  def close : Nil
  end

  # Raises if the current kind is not the expected one.
  def expect_kind(kind : EventKind) : Nil
    raise "Expected #{kind} but was #{self.kind}" unless kind == self.kind
  end

  private def read_anchor
    @anchor =
      case kind
      when .scalar?, .sequence_start?, .mapping_start?, .alias?
        @parser.event.anchor
      end
  end

  def raise(msg : String, line_number = self.start_line, column_number = self.start_column, context_info = nil) : NoReturn
    ::raise ParseException.new(msg, line_number, column_number, context_info)
  end

  private def increase_nesting
    @nesting += 1

    if @nesting > @max_nesting
      raise "Nesting of #{@nesting} is too deep"
    end

    if anchor = @anchor
      (@anchor_scope ||= Hash(Int32, {String, Int32}).new)[@nesting] = {anchor, @aliases}
    end
  end

  private def decrease_nesting
    if (anchor_scope = @anchor_scope) && (scope = anchor_scope.delete(@nesting))
      anchor, aliases = scope
      (@anchor_costs ||= Hash(String, Int32).new)[anchor] = @aliases - aliases
    end

    @nesting -= 1
  end

  private def increase_alias
    aliases = @anchor_costs.try(&.[@anchor]?) || 0
    @aliases += aliases + 1

    if @enforce_alias_anchor_ratio &&
       @aliases > @alias_anchor_min_aliases &&
       @aliases > @alias_anchor_multiplier * @anchors
      raise "Document contains excessive aliasing"
    end
  end
end
