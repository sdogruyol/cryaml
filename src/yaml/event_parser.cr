# :nodoc:
#
# Port of libyaml 0.2.5 parser.c: turns the token stream produced by
# `YAML::Scanner` into events. Iterative state machine, like libyaml.
class YAML::EventParser
  # :nodoc:
  # yaml_parser_state_t
  enum State
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

  DEFAULT_TAG_DIRECTIVES = [{"!", "!"}, {"!!", "tag:yaml.org,2002:"}]

  @state = State::STREAM_START
  @states = [] of State
  @marks = [] of Mark
  @tag_directives = [] of {String, String}
  @error : ParseException? = nil

  def initialize(input : String | IO)
    @scanner = Scanner.new(input)
  end

  # yaml_parser_parse
  def parse : Event
    if error = @error
      raise error
    end
    return Event.new if @scanner.stream_end_produced? || @state.end?
    begin
      state_machine
    rescue ex : ParseException
      @error = ex
      raise ex
    end
  end

  private def peek : Token
    @scanner.peek_token
  end

  private def skip : Nil
    @scanner.skip_token
  end

  # yaml_parser_set_parser_error / yaml_parser_set_parser_error_context
  private def error(problem : String, problem_mark : Mark, context : String? = nil, context_mark : Mark = Mark.new) : NoReturn
    @scanner.syntax_error(problem, problem_mark, context, context_mark)
  end

  # yaml_parser_state_machine
  private def state_machine : Event
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
    in .end?                               then Event.new
    end
  end

  # yaml_parser_parse_stream_start
  private def parse_stream_start : Event
    token = peek
    unless token.kind.stream_start?
      error("did not find expected <stream-start>", token.start_mark)
    end
    @state = State::IMPLICIT_DOCUMENT_START
    skip
    Event.new(EventKind::STREAM_START, token.start_mark, token.start_mark)
  end

  # yaml_parser_parse_document_start
  private def parse_document_start(implicit : Bool) : Event
    token = peek

    unless implicit
      while token.kind.document_end?
        skip
        token = peek
      end
    end

    kind = token.kind
    if implicit && !kind.version_directive? && !kind.tag_directive? &&
       !kind.document_start? && !kind.stream_end?
      process_directives
      @states << State::DOCUMENT_END
      @state = State::BLOCK_NODE
      Event.new(EventKind::DOCUMENT_START, token.start_mark, token.start_mark, implicit: true)
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
      skip
      Event.new(EventKind::DOCUMENT_START, start_mark, end_mark,
        version_directive: version_directive, tag_directives: tag_directives, implicit: false)
    else
      @state = State::END
      skip
      Event.new(EventKind::STREAM_END, token.start_mark, token.end_mark)
    end
  end

  # yaml_parser_parse_document_content
  private def parse_document_content : Event
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
  private def parse_document_end : Event
    token = peek
    start_mark = end_mark = token.start_mark
    implicit = true
    if token.kind.document_end?
      end_mark = token.end_mark
      skip
      implicit = false
    end
    @tag_directives.clear
    @state = State::DOCUMENT_START
    Event.new(EventKind::DOCUMENT_END, start_mark, end_mark, implicit: implicit)
  end

  # yaml_parser_parse_node
  private def parse_node(block : Bool, indentless_sequence : Bool) : Event
    token = peek

    if token.kind.alias?
      @state = @states.pop
      skip
      return Event.new(EventKind::ALIAS, token.start_mark, token.end_mark, anchor: token.value)
    end

    anchor = nil
    tag_handle = nil
    tag_suffix = ""
    tag = nil
    start_mark = end_mark = tag_mark = token.start_mark

    if token.kind.anchor?
      anchor = token.value
      end_mark = token.end_mark
      skip
      token = peek
      if token.kind.tag?
        tag_handle = token.handle
        tag_suffix = token.suffix
        tag_mark = token.start_mark
        end_mark = token.end_mark
        skip
        token = peek
      end
    elsif token.kind.tag?
      tag_handle = token.handle
      tag_suffix = token.suffix
      start_mark = tag_mark = token.start_mark
      end_mark = token.end_mark
      skip
      token = peek
      if token.kind.anchor?
        anchor = token.value
        end_mark = token.end_mark
        skip
        token = peek
      end
    end

    if tag_handle
      if tag_handle.empty?
        tag = tag_suffix
      else
        @tag_directives.each do |(handle, prefix)|
          if handle == tag_handle
            tag = prefix + tag_suffix
            break
          end
        end
        unless tag
          error("found undefined tag handle", tag_mark, "while parsing a node", start_mark)
        end
      end
    end

    implicit = tag.nil? || tag.empty?

    if indentless_sequence && token.kind.block_entry?
      end_mark = token.end_mark
      @state = State::INDENTLESS_SEQUENCE_ENTRY
      return Event.new(EventKind::SEQUENCE_START, start_mark, end_mark,
        anchor: anchor, tag: tag, implicit: implicit, sequence_style: SequenceStyle::BLOCK)
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
      skip
      Event.new(EventKind::SCALAR, start_mark, end_mark,
        anchor: anchor, tag: tag, value: token.value,
        plain_implicit: plain_implicit, quoted_implicit: quoted_implicit,
        scalar_style: token.style)
    when .flow_sequence_start?
      end_mark = token.end_mark
      @state = State::FLOW_SEQUENCE_FIRST_ENTRY
      Event.new(EventKind::SEQUENCE_START, start_mark, end_mark,
        anchor: anchor, tag: tag, implicit: implicit, sequence_style: SequenceStyle::FLOW)
    when .flow_mapping_start?
      end_mark = token.end_mark
      @state = State::FLOW_MAPPING_FIRST_KEY
      Event.new(EventKind::MAPPING_START, start_mark, end_mark,
        anchor: anchor, tag: tag, implicit: implicit, mapping_style: MappingStyle::FLOW)
    else
      if block && token.kind.block_sequence_start?
        end_mark = token.end_mark
        @state = State::BLOCK_SEQUENCE_FIRST_ENTRY
        Event.new(EventKind::SEQUENCE_START, start_mark, end_mark,
          anchor: anchor, tag: tag, implicit: implicit, sequence_style: SequenceStyle::BLOCK)
      elsif block && token.kind.block_mapping_start?
        end_mark = token.end_mark
        @state = State::BLOCK_MAPPING_FIRST_KEY
        Event.new(EventKind::MAPPING_START, start_mark, end_mark,
          anchor: anchor, tag: tag, implicit: implicit, mapping_style: MappingStyle::BLOCK)
      elsif anchor || tag
        @state = @states.pop
        Event.new(EventKind::SCALAR, start_mark, end_mark,
          anchor: anchor, tag: tag, value: "",
          plain_implicit: implicit, quoted_implicit: false,
          scalar_style: ScalarStyle::PLAIN)
      else
        error("did not find expected node content", token.start_mark,
          block ? "while parsing a block node" : "while parsing a flow node", start_mark)
      end
    end
  end

  # yaml_parser_parse_block_sequence_entry
  private def parse_block_sequence_entry(first : Bool) : Event
    if first
      token = peek
      @marks << token.start_mark
      skip
    end

    token = peek
    if token.kind.block_entry?
      mark = token.end_mark
      skip
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
      skip
      Event.new(EventKind::SEQUENCE_END, token.start_mark, token.end_mark)
    else
      error("did not find expected '-' indicator", token.start_mark,
        "while parsing a block collection", @marks.pop)
    end
  end

  # yaml_parser_parse_indentless_sequence_entry
  private def parse_indentless_sequence_entry : Event
    token = peek
    if token.kind.block_entry?
      mark = token.end_mark
      skip
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
      Event.new(EventKind::SEQUENCE_END, token.start_mark, token.start_mark)
    end
  end

  # yaml_parser_parse_block_mapping_key
  private def parse_block_mapping_key(first : Bool) : Event
    if first
      token = peek
      @marks << token.start_mark
      skip
    end

    token = peek
    if token.kind.key?
      mark = token.end_mark
      skip
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
      skip
      Event.new(EventKind::MAPPING_END, token.start_mark, token.end_mark)
    else
      error("did not find expected key", token.start_mark,
        "while parsing a block mapping", @marks.pop)
    end
  end

  # yaml_parser_parse_block_mapping_value
  private def parse_block_mapping_value : Event
    token = peek
    if token.kind.value?
      mark = token.end_mark
      skip
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
  private def parse_flow_sequence_entry(first : Bool) : Event
    if first
      token = peek
      @marks << token.start_mark
      skip
    end

    token = peek
    unless token.kind.flow_sequence_end?
      unless first
        if token.kind.flow_entry?
          skip
          token = peek
        else
          error("did not find expected ',' or ']'", token.start_mark,
            "while parsing a flow sequence", @marks.pop)
        end
      end

      if token.kind.key?
        @state = State::FLOW_SEQUENCE_ENTRY_MAPPING_KEY
        skip
        return Event.new(EventKind::MAPPING_START, token.start_mark, token.end_mark,
          implicit: true, mapping_style: MappingStyle::FLOW)
      elsif !token.kind.flow_sequence_end?
        @states << State::FLOW_SEQUENCE_ENTRY
        return parse_node(false, false)
      end
    end

    @state = @states.pop
    @marks.pop
    skip
    Event.new(EventKind::SEQUENCE_END, token.start_mark, token.end_mark)
  end

  # yaml_parser_parse_flow_sequence_entry_mapping_key
  private def parse_flow_sequence_entry_mapping_key : Event
    token = peek
    kind = token.kind
    if !kind.value? && !kind.flow_entry? && !kind.flow_sequence_end?
      @states << State::FLOW_SEQUENCE_ENTRY_MAPPING_VALUE
      parse_node(false, false)
    else
      mark = token.end_mark
      skip
      @state = State::FLOW_SEQUENCE_ENTRY_MAPPING_VALUE
      process_empty_scalar(mark)
    end
  end

  # yaml_parser_parse_flow_sequence_entry_mapping_value
  private def parse_flow_sequence_entry_mapping_value : Event
    token = peek
    if token.kind.value?
      skip
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
  private def parse_flow_sequence_entry_mapping_end : Event
    token = peek
    @state = State::FLOW_SEQUENCE_ENTRY
    Event.new(EventKind::MAPPING_END, token.start_mark, token.start_mark)
  end

  # yaml_parser_parse_flow_mapping_key
  private def parse_flow_mapping_key(first : Bool) : Event
    if first
      token = peek
      @marks << token.start_mark
      skip
    end

    token = peek
    unless token.kind.flow_mapping_end?
      unless first
        if token.kind.flow_entry?
          skip
          token = peek
        else
          error("did not find expected ',' or '}'", token.start_mark,
            "while parsing a flow mapping", @marks.pop)
        end
      end

      if token.kind.key?
        skip
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
    skip
    Event.new(EventKind::MAPPING_END, token.start_mark, token.end_mark)
  end

  # yaml_parser_parse_flow_mapping_value
  private def parse_flow_mapping_value(empty : Bool) : Event
    token = peek
    if empty
      @state = State::FLOW_MAPPING_KEY
      return process_empty_scalar(token.start_mark)
    end

    if token.kind.value?
      skip
      token = peek
      if !token.kind.flow_entry? && !token.kind.flow_mapping_end?
        @states << State::FLOW_MAPPING_KEY
        return parse_node(false, false)
      end
    end
    @state = State::FLOW_MAPPING_KEY
    process_empty_scalar(token.start_mark)
  end

  # yaml_parser_process_empty_scalar
  private def process_empty_scalar(mark : Mark) : Event
    Event.new(EventKind::SCALAR, mark, mark, value: "",
      plain_implicit: true, quoted_implicit: false, scalar_style: ScalarStyle::PLAIN)
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
        append_tag_directive(value, false, token.start_mark)
        (tag_directives ||= [] of {String, String}) << value
      end
      skip
      token = peek
    end

    DEFAULT_TAG_DIRECTIVES.each do |value|
      append_tag_directive(value, true, token.start_mark)
    end

    {version_directive, tag_directives}
  end

  # yaml_parser_append_tag_directive
  private def append_tag_directive(value : {String, String}, allow_duplicates : Bool, mark : Mark) : Nil
    @tag_directives.each do |(handle, _)|
      if handle == value[0]
        return if allow_duplicates
        error("found duplicate %TAG directive", mark)
      end
    end
    @tag_directives << value
  end
end
