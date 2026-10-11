require "./scanner"

# :nodoc:
#
# Port of libyaml 0.2.5 parser.c: turns the token stream produced by
# `YAML::Scanner` into events. Iterative state machine, like libyaml.
#
# Like libyaml's `yaml_parser_t`, which holds the reader, scanner and parser
# state in one struct, the parser is one object with the scanner it reads
# tokens from: a subclass, so every `PEEK_TOKEN` and `SKIP_TOKEN` is a
# direct call, and one allocation fewer per parser.
class YAML::EventParser < YAML::Scanner
  # :nodoc:
  # yaml_parser_state_t (one byte: the states stack grows with the nesting).
  enum State : UInt8
    STREAM_START
    IMPLICIT_DOCUMENT_START
    DOCUMENT_START
    DOCUMENT_CONTENT
    DOCUMENT_END
    BLOCK_NODE
    BLOCK_NODE_OR_INDENTLESS_SEQUENCE
    FLOW_NODE
    BLOCK_SEQUENCE_FIRST_ENTRY
    BLOCK_SEQUENCE_ENTRY
    INDENTLESS_SEQUENCE_ENTRY
    BLOCK_MAPPING_FIRST_KEY
    BLOCK_MAPPING_KEY
    BLOCK_MAPPING_VALUE
    FLOW_SEQUENCE_FIRST_ENTRY
    FLOW_SEQUENCE_ENTRY
    FLOW_SEQUENCE_ENTRY_MAPPING_KEY
    FLOW_SEQUENCE_ENTRY_MAPPING_VALUE
    FLOW_SEQUENCE_ENTRY_MAPPING_END
    FLOW_MAPPING_FIRST_KEY
    FLOW_MAPPING_KEY
    FLOW_MAPPING_VALUE
    FLOW_MAPPING_EMPTY_VALUE
    END
  end

  DEFAULT_TAG_DIRECTIVES = { {"!", "!"}, {"!!", "tag:yaml.org,2002:"} }

  # The start of every collection being parsed (libyaml's `marks` stack),
  # for the context of error messages. They only show line and column, so
  # the index isn't kept: 16 bytes per level instead of 24.
  private record ContextMark, line : Int64, column : Int64

  # Declared with its type, which puts it first among the parser's fields,
  # right after the scanner's flags, where it fits in their padding.
  @state : State = State::STREAM_START
  @states = Stack(State).new
  @marks = Stack(ContextMark).new
  # The %TAG directives of the current document (see `#process_directives`).
  @tag_directives : Array({String, String})? = nil
  @error : ParseException? = nil

  # The current event. The parser builds each event right here, where
  # `PullParser` reads it, rather than returning a 120-byte struct through
  # every state function. A SCALAR's `value` is only there after
  # `#make_value`.
  getter event = Event.new

  # Where the current SCALAR event's value lies in the `String` input
  # (`Token.input_scalar`) while the string hasn't been made:
  # `@event.value` is "" until `#make_value` makes it. `@value_bytesize` is
  # 0 for any other value of a SCALAR event (and stale after other events).
  @value_offset = 0
  @value_bytesize = 0

  # Makes sure that `event.value` holds the value of a SCALAR event (one
  # left in the input may still need to be made into a string).
  @[AlwaysInline]
  def make_value : Nil
    make_input_value if @value_bytesize != 0 && @event.kind.scalar?
  end

  # Makes the string of a value left in the input and keeps it in the
  # event. From now on the scanner makes them at once (see `@lazy_values`).
  @[NoInline]
  private def make_input_value : Nil
    offset = @value_offset
    bytesize = @value_bytesize
    # ASCII, so it has as many characters as bytes.
    @event.value = input_to_s(offset, offset &+ bytesize, bytesize)
    @value_bytesize = 0
    @lazy_values = false
  end

  # yaml_parser_parse: replaces `#event` with the next event. As with
  # libyaml, a failure leaves an empty (NONE) event behind.
  def parse : Nil
    if error = @error
      @event = Event.new
      raise error
    end
    # (libyaml also checks `stream_end_produced`, which `SKIP_TOKEN` sets as
    # the END state is entered.)
    if @state.end?
      @event = Event.new
      return
    end
    begin
      state_machine
    rescue ex
      @event = Event.new
      @error = ex if ex.is_a?(ParseException)
      raise ex
    end
  end

  @[AlwaysInline]
  private def peek : Token
    peek_token
  end

  # yaml_parser_set_parser_error / yaml_parser_set_parser_error_context
  private def error(problem : String, problem_mark : Mark, context : String? = nil, context_mark : Mark = Mark.new) : NoReturn
    syntax_error(problem, problem_mark, context, context_mark)
  end

  # PUSH(parser->marks, mark)
  @[AlwaysInline]
  private def push_mark(mark : Mark) : Nil
    @marks << ContextMark.new(mark.line, mark.column)
  end

  # POP(parser->marks) of an error's context mark (without its index).
  private def pop_mark : Mark
    mark = @marks.pop
    Mark.new(0_i64, mark.line, mark.column)
  end

  # yaml_parser_state_machine
  private def state_machine : Nil
    case @state
    in .stream_start?                      then parse_stream_start
    in .implicit_document_start?           then parse_document_start(true)
    in .document_start?                    then parse_document_start(false)
    in .document_content?                  then parse_document_content
    in .document_end?                      then parse_document_end
    in .block_node?                        then parse_node(true, false)
    in .block_node_or_indentless_sequence? then parse_node(true, true)
    in .flow_node?                         then parse_node(false, false)
    in .block_sequence_first_entry?        then parse_block_sequence_entry(true)
    in .block_sequence_entry?              then parse_block_sequence_entry(false)
    in .indentless_sequence_entry?         then parse_indentless_sequence_entry
    in .block_mapping_first_key?           then parse_block_mapping_key(true)
    in .block_mapping_key?                 then parse_block_mapping_key(false)
    in .block_mapping_value?               then parse_block_mapping_value
    in .flow_sequence_first_entry?         then parse_flow_sequence_entry(true)
    in .flow_sequence_entry?               then parse_flow_sequence_entry(false)
    in .flow_sequence_entry_mapping_key?   then parse_flow_sequence_entry_mapping_key
    in .flow_sequence_entry_mapping_value? then parse_flow_sequence_entry_mapping_value
    in .flow_sequence_entry_mapping_end?   then parse_flow_sequence_entry_mapping_end
    in .flow_mapping_first_key?            then parse_flow_mapping_key(true)
    in .flow_mapping_key?                  then parse_flow_mapping_key(false)
    in .flow_mapping_value?                then parse_flow_mapping_value(false)
    in .flow_mapping_empty_value?          then parse_flow_mapping_value(true)
    in .end?                               then @event = Event.new
    end
  end

  # yaml_parser_parse_stream_start
  private def parse_stream_start : Nil
    token = peek
    unless token.kind.stream_start?
      error("did not find expected <stream-start>", token.start_mark)
    end
    @state = State::IMPLICIT_DOCUMENT_START
    skip_token
    @event = Event.new(EventKind::STREAM_START, token.start_mark, token.start_mark)
  end

  # yaml_parser_parse_document_start
  private def parse_document_start(implicit : Bool) : Nil
    token = peek

    unless implicit
      while token.kind.document_end?
        skip_token
        token = peek
      end
    end

    kind = token.kind
    if implicit && !kind.version_directive? && !kind.tag_directive? &&
       !kind.document_start? && !kind.stream_end?
      process_directives
      @states << State::DOCUMENT_END
      @state = State::BLOCK_NODE
      @event = Event.new(EventKind::DOCUMENT_START, token.start_mark, token.start_mark)
      @event.implicit = true
    elsif !kind.stream_end?
      start_mark = token.start_mark
      version_directive, tag_directives = process_directives
      token = peek
      unless token.kind.document_start?
        error("did not find expected <document start>", token.start_mark)
      end
      @states << State::DOCUMENT_END
      @state = State::DOCUMENT_CONTENT
      end_mark = token.end_mark
      skip_token
      @event = Event.new(EventKind::DOCUMENT_START, start_mark, end_mark)
      @event.version_directive = version_directive
      @event.tag_directives = tag_directives
    else
      @state = State::END
      skip_token
      @event = Event.new(EventKind::STREAM_END, token.start_mark, token.end_mark)
    end
  end

  # yaml_parser_parse_document_content
  private def parse_document_content : Nil
    token = peek
    kind = token.kind
    if kind.version_directive? || kind.tag_directive? || kind.document_start? ||
       kind.document_end? || kind.stream_end?
      @state = @states.pop
      process_empty_scalar(token.start_mark)
    else
      parse_node(true, false)
    end
  end

  # yaml_parser_parse_document_end
  private def parse_document_end : Nil
    token = peek
    start_mark = end_mark = token.start_mark
    implicit = true
    if token.kind.document_end?
      end_mark = token.end_mark
      skip_token
      implicit = false
    end
    @tag_directives = nil
    @state = State::DOCUMENT_START
    @event = Event.new(EventKind::DOCUMENT_END, start_mark, end_mark)
    @event.implicit = implicit
  end

  # yaml_parser_parse_node
  private def parse_node(block : Bool, indentless_sequence : Bool) : Nil
    token = peek
    kind = token.kind

    # Most nodes are scalars without properties: what the code below does
    # for them, without keeping its variables.
    if kind.scalar?
      @state = @states.pop
      skip_token
      @value_offset = token.input_offset
      @value_bytesize = token.input_bytesize
      plain = token.style.plain?
      @event = Event.new(EventKind::SCALAR, token.start_mark, token.end_mark)
      @event.value = token.value
      @event.plain_implicit = plain
      @event.quoted_implicit = !plain
      @event.scalar_style = token.style
      return
    end

    if kind.alias?
      @state = @states.pop
      skip_token
      @event = Event.new(EventKind::ALIAS, token.start_mark, token.end_mark)
      @event.anchor = token.value
      return
    end

    anchor = nil
    tag_handle = nil
    tag_suffix = ""
    tag = nil
    start_mark = end_mark = tag_mark = token.start_mark

    if token.kind.anchor?
      anchor = token.value
      end_mark = token.end_mark
      skip_token
      token = peek
      if token.kind.tag?
        tag_handle = token.handle
        tag_suffix = token.suffix
        tag_mark = token.start_mark
        end_mark = token.end_mark
        skip_token
        token = peek
      end
    elsif token.kind.tag?
      tag_handle = token.handle
      tag_suffix = token.suffix
      start_mark = tag_mark = token.start_mark
      end_mark = token.end_mark
      skip_token
      token = peek
      if token.kind.anchor?
        anchor = token.value
        end_mark = token.end_mark
        skip_token
        token = peek
      end
    end

    if tag_handle
      if tag_handle.empty?
        tag = tag_suffix
      else
        tag = tag_prefix(tag_handle).try { |prefix| prefix + tag_suffix }
        unless tag
          error("found undefined tag handle", tag_mark, "while parsing a node", start_mark)
        end
      end
    end

    implicit = tag.nil? || tag.empty?

    if indentless_sequence && token.kind.block_entry?
      end_mark = token.end_mark
      @state = State::INDENTLESS_SEQUENCE_ENTRY
      collection_start_event(EventKind::SEQUENCE_START, start_mark, end_mark, anchor, tag, implicit)
      @event.sequence_style = SequenceStyle::BLOCK
      return
    end

    case token.kind
    when .scalar?
      plain_implicit = false
      quoted_implicit = false
      end_mark = token.end_mark
      if (token.style.plain? && tag.nil?) || tag == "!"
        plain_implicit = true
      elsif tag.nil?
        quoted_implicit = true
      end
      @state = @states.pop
      skip_token
      @value_offset = token.input_offset
      @value_bytesize = token.input_bytesize
      @event = Event.new(EventKind::SCALAR, start_mark, end_mark)
      @event.anchor = anchor
      @event.tag = tag
      @event.value = token.value
      @event.plain_implicit = plain_implicit
      @event.quoted_implicit = quoted_implicit
      @event.scalar_style = token.style
    when .flow_sequence_start?
      end_mark = token.end_mark
      @state = State::FLOW_SEQUENCE_FIRST_ENTRY
      collection_start_event(EventKind::SEQUENCE_START, start_mark, end_mark, anchor, tag, implicit)
      @event.sequence_style = SequenceStyle::FLOW
    when .flow_mapping_start?
      end_mark = token.end_mark
      @state = State::FLOW_MAPPING_FIRST_KEY
      collection_start_event(EventKind::MAPPING_START, start_mark, end_mark, anchor, tag, implicit)
      @event.mapping_style = MappingStyle::FLOW
    else
      if block && token.kind.block_sequence_start?
        end_mark = token.end_mark
        @state = State::BLOCK_SEQUENCE_FIRST_ENTRY
        collection_start_event(EventKind::SEQUENCE_START, start_mark, end_mark, anchor, tag, implicit)
        @event.sequence_style = SequenceStyle::BLOCK
      elsif block && token.kind.block_mapping_start?
        end_mark = token.end_mark
        @state = State::BLOCK_MAPPING_FIRST_KEY
        collection_start_event(EventKind::MAPPING_START, start_mark, end_mark, anchor, tag, implicit)
        @event.mapping_style = MappingStyle::BLOCK
      elsif anchor || tag
        @state = @states.pop
        @value_bytesize = 0
        @event = Event.new(EventKind::SCALAR, start_mark, end_mark)
        @event.anchor = anchor
        @event.tag = tag
        @event.plain_implicit = implicit
        @event.scalar_style = ScalarStyle::PLAIN
      else
        error("did not find expected node content", token.start_mark,
          block ? "while parsing a block node" : "while parsing a flow node", start_mark)
      end
    end
  end

  # yaml_parser_parse_block_sequence_entry
  private def parse_block_sequence_entry(first : Bool) : Nil
    if first
      token = peek
      push_mark(token.start_mark)
      skip_token
    end

    token = peek
    if token.kind.block_entry?
      mark = token.end_mark
      skip_token
      token = peek
      if !token.kind.block_entry? && !token.kind.block_end?
        @states << State::BLOCK_SEQUENCE_ENTRY
        parse_node(true, false)
      else
        @state = State::BLOCK_SEQUENCE_ENTRY
        process_empty_scalar(mark)
      end
    elsif token.kind.block_end?
      @state = @states.pop
      @marks.pop
      skip_token
      @event = Event.new(EventKind::SEQUENCE_END, token.start_mark, token.end_mark)
    else
      error("did not find expected '-' indicator", token.start_mark,
        "while parsing a block collection", pop_mark)
    end
  end

  # yaml_parser_parse_indentless_sequence_entry
  private def parse_indentless_sequence_entry : Nil
    token = peek
    if token.kind.block_entry?
      mark = token.end_mark
      skip_token
      token = peek
      kind = token.kind
      if !kind.block_entry? && !kind.key? && !kind.value? && !kind.block_end?
        @states << State::INDENTLESS_SEQUENCE_ENTRY
        parse_node(true, false)
      else
        @state = State::INDENTLESS_SEQUENCE_ENTRY
        process_empty_scalar(mark)
      end
    else
      @state = @states.pop
      @event = Event.new(EventKind::SEQUENCE_END, token.start_mark, token.start_mark)
    end
  end

  # yaml_parser_parse_block_mapping_key
  private def parse_block_mapping_key(first : Bool) : Nil
    if first
      token = peek
      push_mark(token.start_mark)
      skip_token
    end

    token = peek
    if token.kind.key?
      mark = token.end_mark
      skip_token
      token = peek
      kind = token.kind
      if !kind.key? && !kind.value? && !kind.block_end?
        @states << State::BLOCK_MAPPING_VALUE
        parse_node(true, true)
      else
        @state = State::BLOCK_MAPPING_VALUE
        process_empty_scalar(mark)
      end
    elsif token.kind.block_end?
      @state = @states.pop
      @marks.pop
      skip_token
      @event = Event.new(EventKind::MAPPING_END, token.start_mark, token.end_mark)
    else
      error("did not find expected key", token.start_mark,
        "while parsing a block mapping", pop_mark)
    end
  end

  # yaml_parser_parse_block_mapping_value
  private def parse_block_mapping_value : Nil
    token = peek
    if token.kind.value?
      mark = token.end_mark
      skip_token
      token = peek
      kind = token.kind
      if !kind.key? && !kind.value? && !kind.block_end?
        @states << State::BLOCK_MAPPING_KEY
        parse_node(true, true)
      else
        @state = State::BLOCK_MAPPING_KEY
        process_empty_scalar(mark)
      end
    else
      @state = State::BLOCK_MAPPING_KEY
      process_empty_scalar(token.start_mark)
    end
  end

  # yaml_parser_parse_flow_sequence_entry
  private def parse_flow_sequence_entry(first : Bool) : Nil
    if first
      token = peek
      push_mark(token.start_mark)
      skip_token
    end

    token = peek
    unless token.kind.flow_sequence_end?
      unless first
        if token.kind.flow_entry?
          skip_token
          token = peek
        else
          error("did not find expected ',' or ']'", token.start_mark,
            "while parsing a flow sequence", pop_mark)
        end
      end

      if token.kind.key?
        @state = State::FLOW_SEQUENCE_ENTRY_MAPPING_KEY
        skip_token
        @event = Event.new(EventKind::MAPPING_START, token.start_mark, token.end_mark)
        @event.implicit = true
        @event.mapping_style = MappingStyle::FLOW
        return
      elsif !token.kind.flow_sequence_end?
        @states << State::FLOW_SEQUENCE_ENTRY
        return parse_node(false, false)
      end
    end

    @state = @states.pop
    @marks.pop
    skip_token
    @event = Event.new(EventKind::SEQUENCE_END, token.start_mark, token.end_mark)
  end

  # yaml_parser_parse_flow_sequence_entry_mapping_key
  private def parse_flow_sequence_entry_mapping_key : Nil
    token = peek
    kind = token.kind
    if !kind.value? && !kind.flow_entry? && !kind.flow_sequence_end?
      @states << State::FLOW_SEQUENCE_ENTRY_MAPPING_VALUE
      parse_node(false, false)
    else
      mark = token.end_mark
      skip_token
      @state = State::FLOW_SEQUENCE_ENTRY_MAPPING_VALUE
      process_empty_scalar(mark)
    end
  end

  # yaml_parser_parse_flow_sequence_entry_mapping_value
  private def parse_flow_sequence_entry_mapping_value : Nil
    token = peek
    if token.kind.value?
      skip_token
      token = peek
      if !token.kind.flow_entry? && !token.kind.flow_sequence_end?
        @states << State::FLOW_SEQUENCE_ENTRY_MAPPING_END
        return parse_node(false, false)
      end
    end
    @state = State::FLOW_SEQUENCE_ENTRY_MAPPING_END
    process_empty_scalar(token.start_mark)
  end

  # yaml_parser_parse_flow_sequence_entry_mapping_end
  private def parse_flow_sequence_entry_mapping_end : Nil
    token = peek
    @state = State::FLOW_SEQUENCE_ENTRY
    @event = Event.new(EventKind::MAPPING_END, token.start_mark, token.start_mark)
  end

  # yaml_parser_parse_flow_mapping_key
  private def parse_flow_mapping_key(first : Bool) : Nil
    if first
      token = peek
      push_mark(token.start_mark)
      skip_token
    end

    token = peek
    unless token.kind.flow_mapping_end?
      unless first
        if token.kind.flow_entry?
          skip_token
          token = peek
        else
          error("did not find expected ',' or '}'", token.start_mark,
            "while parsing a flow mapping", pop_mark)
        end
      end

      if token.kind.key?
        skip_token
        token = peek
        kind = token.kind
        if !kind.value? && !kind.flow_entry? && !kind.flow_mapping_end?
          @states << State::FLOW_MAPPING_VALUE
          return parse_node(false, false)
        else
          @state = State::FLOW_MAPPING_VALUE
          return process_empty_scalar(token.start_mark)
        end
      elsif !token.kind.flow_mapping_end?
        @states << State::FLOW_MAPPING_EMPTY_VALUE
        return parse_node(false, false)
      end
    end

    @state = @states.pop
    @marks.pop
    skip_token
    @event = Event.new(EventKind::MAPPING_END, token.start_mark, token.end_mark)
  end

  # yaml_parser_parse_flow_mapping_value
  private def parse_flow_mapping_value(empty : Bool) : Nil
    token = peek
    if empty
      @state = State::FLOW_MAPPING_KEY
      return process_empty_scalar(token.start_mark)
    end

    if token.kind.value?
      skip_token
      token = peek
      if !token.kind.flow_entry? && !token.kind.flow_mapping_end?
        @states << State::FLOW_MAPPING_KEY
        return parse_node(false, false)
      end
    end
    @state = State::FLOW_MAPPING_KEY
    process_empty_scalar(token.start_mark)
  end

  # The SEQUENCE-START or MAPPING-START event of `#parse_node`, but for its
  # style.
  private def collection_start_event(kind : EventKind, start_mark : Mark, end_mark : Mark, anchor : String?, tag : String?, implicit : Bool) : Nil
    @event = Event.new(kind, start_mark, end_mark)
    @event.anchor = anchor
    @event.tag = tag
    @event.implicit = implicit
  end

  # yaml_parser_process_empty_scalar
  private def process_empty_scalar(mark : Mark) : Nil
    @value_bytesize = 0
    @event = Event.new(EventKind::SCALAR, mark, mark)
    @event.plain_implicit = true
    @event.scalar_style = ScalarStyle::PLAIN
  end

  # yaml_parser_process_directives
  private def process_directives : { {Int32, Int32}?, Array({String, String})? }
    version_directive = nil
    tag_directives = nil

    token = peek
    while token.kind.version_directive? || token.kind.tag_directive?
      if token.kind.version_directive?
        if version_directive
          error("found duplicate %YAML directive", token.start_mark)
        end
        if token.major != 1 || (token.minor != 1 && token.minor != 2)
          error("found incompatible YAML document", token.start_mark)
        end
        version_directive = {token.major, token.minor}
      else
        value = {token.handle, token.prefix}
        check_tag_directive(tag_directives, value, token.start_mark)
        (tag_directives ||= [] of {String, String}) << value
      end
      skip_token
      token = peek
    end

    # libyaml appends the default directives to the document's here, except
    # those whose handles it redefines; `#tag_prefix` looks them up after
    # the document's own instead, which finds the same prefixes.
    @tag_directives = tag_directives
    {version_directive, tag_directives}
  end

  # yaml_parser_append_tag_directive (without `allow_duplicates`): checks
  # *value* against the %TAG directives read so far.
  private def check_tag_directive(tag_directives : Array({String, String})?, value : {String, String}, mark : Mark) : Nil
    tag_directives.try &.each do |(handle, _)|
      error("found duplicate %TAG directive", mark) if handle == value[0]
    end
  end

  # The prefix that the current document's %TAG directives, or else the default
  # ones, give to *handle* (the search of libyaml's `parser->tag_directives`
  # in `yaml_parser_parse_node`).
  @[NoInline]
  private def tag_prefix(handle : String) : String?
    @tag_directives.try &.each do |(directive_handle, prefix)|
      return prefix if directive_handle == handle
    end
    DEFAULT_TAG_DIRECTIVES.each do |(directive_handle, prefix)|
      return prefix if directive_handle == handle
    end
    nil
  end
end
