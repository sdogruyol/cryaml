# :nodoc:
#
# Pure Crystal port of libyaml 0.2.5's emitter (emitter.c + writer.c),
# UTF-8 output only. Errors make `#emit` return false and set `#problem`,
# like `yaml_emitter_emit`.
class YAML::Emitter
  # libyaml's output buffer size: the buffer is flushed when fewer than 5
  # bytes of it are free (FLUSH), so the IO receives writes of these sizes.
  OUTPUT_BUFFER_SIZE = 16384

  # libyaml mallocs its 16 KiB buffer outside the GC; here it is GC memory,
  # allocated per emitter, and most outputs (configs, small objects) are
  # much smaller. So the buffer starts at 1 KiB and grows to
  # OUTPUT_BUFFER_SIZE in one step when that fills up (in one step: growing
  # gradually allocated more in total for large outputs, measured). Flushes
  # still happen only when the full 16 KiB would be used, so the IO sees the
  # same writes.
  private INITIAL_BUFFER_SIZE = 1024

  # yaml_emitter_state_t
  enum State
    STREAM_START
    FIRST_DOCUMENT_START
    DOCUMENT_START
    DOCUMENT_CONTENT
    DOCUMENT_END
    FLOW_SEQUENCE_FIRST_ITEM
    FLOW_SEQUENCE_ITEM
    FLOW_MAPPING_FIRST_KEY
    FLOW_MAPPING_KEY
    FLOW_MAPPING_SIMPLE_VALUE
    FLOW_MAPPING_VALUE
    BLOCK_SEQUENCE_FIRST_ITEM
    BLOCK_SEQUENCE_ITEM
    BLOCK_MAPPING_FIRST_KEY
    BLOCK_MAPPING_KEY
    BLOCK_MAPPING_SIMPLE_VALUE
    BLOCK_MAPPING_VALUE
    END
  end

  # Raised internally to unwind on an emitter error (set_emitter_error).
  private class Failure < Exception
  end

  private DEFAULT_TAG_DIRECTIVES = { {"!", "!"}, {"!!", "tag:yaml.org,2002:"} }

  # Block scalar indentation indicators, indexed by `@best_indent` (2..9).
  private INDENT_HINTS = {"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}

  property? unicode : Bool = false
  getter problem : String?

  @canonical = false
  @best_indent = 2
  @best_width = 80
  @state = State::STREAM_START
  @states = Stack(State).new
  @events = Queue(Event).new
  @indents = Stack(Int32).new
  # The current document's %TAG directives; the defaults are added by
  # `#each_tag_directive` once `@default_tag_directives` is set.
  @tag_directives : Array({String, String})? = nil
  @default_tag_directives = false
  @indent = -1
  @flow_level = 0
  @root_context = false
  @sequence_context = false
  @mapping_context = false
  @simple_key_context = false
  @column = 0
  @whitespace = false
  @indention = false
  @open_ended = 0

  # anchor_data
  @anchor = Pointer(UInt8).null
  @anchor_length = 0
  @anchor_alias = false
  # tag_data
  @tag_handle = Pointer(UInt8).null
  @tag_handle_length = 0
  @tag_suffix = Pointer(UInt8).null
  @tag_suffix_length = 0
  # scalar_data
  @scalar_value = Pointer(UInt8).null
  @scalar_length = 0
  @multiline = false
  @flow_plain_allowed = false
  @block_plain_allowed = false
  @single_quoted_allowed = false
  @block_allowed = false
  @scalar_style = ScalarStyle::ANY
  # Not in libyaml: set by analyze_scalar when the scalar is printable
  # ASCII without breaks and no flag but `flow_indicators` applies to it
  # (see `#simple_scalar`), and whether it has spaces. `#write_simple_plain?`
  # copies such a scalar at once.
  @simple_scalar = false
  @scalar_spaces = false

  def initialize(@io : IO)
    # `@buffer[0, @capacity]` is allocated; `@buffer[0, @pos]` is pending
    # output. FLUSH (or growing) is due once `@pos` reaches `@write_limit`,
    # `@capacity - 5`, kept to make that test a single comparison.
    @capacity = INITIAL_BUFFER_SIZE
    @write_limit = @capacity - 5
    @buffer = Pointer(UInt8).malloc(@capacity)
    @pos = 0
  end

  # Where the caller builds the next event before passing it to `#emit`:
  # the free slot at the tail of the queue. libyaml's ENQUEUE copies the
  # caller's event into the queue; building it in place saves copying the
  # 128-byte struct. The slot's marks are zero: the queue's memory starts
  # zeroed, and the events built in it (by `Builder`) have no marks.
  @[AlwaysInline]
  def event_slot : Event*
    @events.tail_slot
  end

  # yaml_emitter_emit, for the event built at `#event_slot`. Like libyaml,
  # the functions below take a pointer to the event (`yaml_event_t *`): the
  # head of the queue, or (fast path) the free slot it would be queued in.
  def emit(event : Event*) : Bool
    # Fast path: with nothing queued, an event that needs no lookahead (all
    # but DOCUMENT-START, SEQUENCE-START and MAPPING-START) would be queued
    # and then processed and dequeued at once by the loop below; process it
    # in its slot without queuing it.
    if @events.empty? && !lookahead?(event.value.kind)
      begin
        analyze_event(event)
        state_machine(event)
      rescue ex
        # libyaml leaves the failed event at the head of the queue, also when
        # the IO raises during a flush, so the next call processes it again.
        @events.push_tail_slot
        raise ex unless ex.is_a?(Failure)
        return false
      end
      return true
    end

    @events.push_tail_slot
    until need_more_events?
      # The state machine reads the queue but doesn't modify it.
      head = @events.first_pointer
      analyze_event(head)
      state_machine(head)
      dequeue_event
    end
    true
  rescue Failure
    false
  end

  # DEQUEUE of the head event. Its slot is overwritten when it is reused;
  # until then only the references it holds are cleared, so their strings
  # can be collected (libyaml frees each dequeued event). Each is a single
  # pointer (a nilable reference is one, `nil` being null), stored as null
  # like `Pointer#clear` would.
  @[AlwaysInline]
  private def dequeue_event : Nil
    head = @events.first_pointer.as(Pointer(UInt8))
    {% for field in %w(@tag_directives @anchor @tag @value) %}
      (head + offsetof(Event, {{field.id}})).as(Pointer(Pointer(Void))).value = Pointer(Void).null
    {% end %}
    @events.shift_keeping_slot
  end

  # Whether `need_more_events?` may wait for more events after *kind*.
  @[AlwaysInline]
  private def lookahead?(kind : EventKind) : Bool
    kind.document_start? || kind.sequence_start? || kind.mapping_start?
  end

  # yaml_emitter_flush (writer.c). Like libyaml, the buffer is reset before
  # writing, so an IO that raises drops the bytes instead of having them
  # written again by the next flush.
  def flush : Bool
    if @pos > 0
      size = @pos
      @pos = 0
      @io.write_string(Slice.new(@buffer, size))
    end
    true
  end

  # yaml_emitter_set_emitter_error
  private def error(problem : String) : NoReturn
    @problem = problem
    raise Failure.new
  end

  # yaml_emitter_need_more_events
  private def need_more_events? : Bool
    return true if @events.empty?
    head = @events.first_pointer
    accumulate = case head.value.kind
                 when .document_start? then 1
                 when .sequence_start? then 2
                 when .mapping_start?  then 3
                 else                       return false
                 end
    size = @events.size
    return false if size > accumulate
    # The head starts a document or collection, so the level is 1 after it.
    # The queued events are `head[0, size]`, at most 3, so neither `level`
    # nor `i` can overflow.
    level = 1
    i = 1
    while i < size
      case head[i].kind
      when .stream_start?, .document_start?, .sequence_start?, .mapping_start?
        level &+= 1
      when .stream_end?, .document_end?, .sequence_end?, .mapping_end?
        level &-= 1
      else
      end
      return false if level == 0
      i &+= 1
    end
    true
  end

  # yaml_emitter_append_tag_directive, for the document's own directives.
  private def append_tag_directive(value : {String, String}) : Nil
    directives = @tag_directives ||= [] of {String, String}
    directives.each do |directive|
      error("duplicate %TAG directive") if directive[0] == value[0]
    end
    directives << value
  end

  # The tag directives in effect, in libyaml's order: the document's own,
  # then the default ones whose handle they don't take (libyaml appends
  # those to the list with `allow_duplicates`; they aren't stored here, so
  # most emitters never allocate the list).
  private def each_tag_directive(& : {String, String} ->) : Nil
    directives = @tag_directives
    directives.try &.each { |directive| yield directive }
    return unless @default_tag_directives
    DEFAULT_TAG_DIRECTIVES.each do |default|
      next if directives.try &.any? { |directive| directive[0] == default[0] }
      yield default
    end
  end

  # yaml_emitter_increase_indent
  @[AlwaysInline]
  private def increase_indent(flow : Bool, indentless : Bool) : Nil
    @indents.push(@indent)
    if @indent < 0
      @indent = flow ? @best_indent : 0
    elsif !indentless
      @indent += @best_indent
    end
  end

  # yaml_emitter_state_machine (inlined: a jump table)
  @[AlwaysInline]
  private def state_machine(event : Event*) : Nil
    case @state
    in .stream_start?               then emit_stream_start(event)
    in .first_document_start?       then emit_document_start(event, true)
    in .document_start?             then emit_document_start(event, false)
    in .document_content?           then emit_document_content(event)
    in .document_end?               then emit_document_end(event)
    in .flow_sequence_first_item?   then emit_flow_sequence_item(event, true)
    in .flow_sequence_item?         then emit_flow_sequence_item(event, false)
    in .flow_mapping_first_key?     then emit_flow_mapping_key(event, true)
    in .flow_mapping_key?           then emit_flow_mapping_key(event, false)
    in .flow_mapping_simple_value?  then emit_flow_mapping_value(event, true)
    in .flow_mapping_value?         then emit_flow_mapping_value(event, false)
    in .block_sequence_first_item?  then emit_block_sequence_item(event, true)
    in .block_sequence_item?        then emit_block_sequence_item(event, false)
    in .block_mapping_first_key?    then emit_block_mapping_key(event, true)
    in .block_mapping_key?          then emit_block_mapping_key(event, false)
    in .block_mapping_simple_value? then emit_block_mapping_value(event, true)
    in .block_mapping_value?        then emit_block_mapping_value(event, false)
    in .end?                        then error("expected nothing after STREAM-END")
    end
  end

  # yaml_emitter_emit_stream_start
  private def emit_stream_start(event : Event*) : Nil
    @open_ended = 0
    if event.value.kind.stream_start?
      @best_indent = 2 if @best_indent < 2 || @best_indent > 9
      @best_width = 80 if @best_width >= 0 && @best_width <= @best_indent * 2
      @best_width = Int32::MAX if @best_width < 0
      @indent = -1
      @column = 0
      @whitespace = true
      @indention = true
      @state = State::FIRST_DOCUMENT_START
      return
    end
    error("expected STREAM-START")
  end

  # yaml_emitter_emit_document_start
  private def emit_document_start(event : Event*, first : Bool) : Nil
    if event.value.kind.document_start?
      version = event.value.version_directive
      directives = event.value.tag_directives
      has_directives = !directives.nil? && !directives.empty?

      analyze_version_directive(version) if version
      directives.try &.each do |directive|
        analyze_tag_directive(directive)
        append_tag_directive(directive)
      end
      @default_tag_directives = true

      implicit = event.value.implicit?
      implicit = false if !first || @canonical

      if (version || has_directives) && @open_ended != 0
        write_indicator("...", true, false, false)
        write_indent
      end
      @open_ended = 0

      if version || has_directives
        implicit = false
        write_directives(version, directives)
      end

      # yaml_emitter_check_empty_document always returns 0.

      unless implicit
        write_indent
        write_indicator("---", true, false, false)
        write_indent if @canonical
      end

      @state = State::DOCUMENT_CONTENT
      @open_ended = 0
      return
    elsif event.value.kind.stream_end?
      # This can happen if a block scalar with trailing empty lines
      # is at the end of the stream.
      if @open_ended == 2
        write_indicator("...", true, false, false)
        @open_ended = 0
        write_indent
      end
      flush
      @state = State::END
      return
    end
    error("expected DOCUMENT-START or STREAM-END")
  end

  # The %YAML and %TAG lines of yaml_emitter_emit_document_start, out of
  # line: directives are rare.
  @[NoInline]
  private def write_directives(version : {Int32, Int32}?, directives : Array({String, String})?) : Nil
    if version
      write_indicator("%YAML", true, false, false)
      write_indicator(version[1] == 1 ? "1.1" : "1.2", true, false, false)
      write_indent
    end

    directives.try &.each do |directive|
      write_indicator("%TAG", true, false, false)
      write_tag_handle(directive[0].to_unsafe, directive[0].bytesize)
      write_tag_content(directive[1].to_unsafe, directive[1].bytesize, true)
      write_indent
    end
  end

  # yaml_emitter_emit_document_content
  private def emit_document_content(event : Event*) : Nil
    emit_node(event, true, false, false, false, State::DOCUMENT_END)
  end

  # yaml_emitter_emit_document_end
  private def emit_document_end(event : Event*) : Nil
    if event.value.kind.document_end?
      write_indent
      if !event.value.implicit?
        write_indicator("...", true, false, false)
        @open_ended = 0
        write_indent
      elsif @open_ended == 0
        @open_ended = 1
      end
      flush
      @state = State::DOCUMENT_START
      @tag_directives.try &.clear
      @default_tag_directives = false
      return
    end
    error("expected DOCUMENT-END")
  end

  # yaml_emitter_emit_flow_sequence_item
  private def emit_flow_sequence_item(event : Event*, first : Bool) : Nil
    if first
      write_indicator("[", true, true, false)
      increase_indent(true, false)
      @flow_level += 1
    end

    if event.value.kind.sequence_end?
      @flow_level -= 1
      @indent = @indents.pop
      if @canonical && !first
        write_indicator(",", false, false, false)
        write_indent
      end
      write_indicator("]", false, false, false)
      @state = @states.pop
      return
    end

    write_indicator(",", false, false, false) unless first
    write_indent if @canonical || @column > @best_width
    emit_node(event, false, true, false, false, State::FLOW_SEQUENCE_ITEM)
  end

  # yaml_emitter_emit_flow_mapping_key
  private def emit_flow_mapping_key(event : Event*, first : Bool) : Nil
    if first
      write_indicator("{", true, true, false)
      increase_indent(true, false)
      @flow_level += 1
    end

    if event.value.kind.mapping_end?
      @flow_level -= 1
      @indent = @indents.pop
      if @canonical && !first
        write_indicator(",", false, false, false)
        write_indent
      end
      write_indicator("}", false, false, false)
      @state = @states.pop
      return
    end

    write_indicator(",", false, false, false) unless first
    write_indent if @canonical || @column > @best_width

    if !@canonical && check_simple_key?(event)
      emit_node(event, false, false, true, true, State::FLOW_MAPPING_SIMPLE_VALUE)
    else
      write_indicator("?", true, false, false)
      emit_node(event, false, false, true, false, State::FLOW_MAPPING_VALUE)
    end
  end

  # yaml_emitter_emit_flow_mapping_value
  private def emit_flow_mapping_value(event : Event*, simple : Bool) : Nil
    if simple
      write_indicator(":", false, false, false)
    else
      write_indent if @canonical || @column > @best_width
      write_indicator(":", true, false, false)
    end
    emit_node(event, false, false, true, false, State::FLOW_MAPPING_KEY)
  end

  # yaml_emitter_emit_block_sequence_item
  private def emit_block_sequence_item(event : Event*, first : Bool) : Nil
    increase_indent(false, @mapping_context && !@indention) if first

    if event.value.kind.sequence_end?
      @indent = @indents.pop
      @state = @states.pop
      return
    end

    write_indent
    write_indicator("-", true, false, true)
    emit_node(event, false, true, false, false, State::BLOCK_SEQUENCE_ITEM)
  end

  # yaml_emitter_emit_block_mapping_key
  private def emit_block_mapping_key(event : Event*, first : Bool) : Nil
    increase_indent(false, false) if first

    if event.value.kind.mapping_end?
      @indent = @indents.pop
      @state = @states.pop
      return
    end

    write_indent

    if check_simple_key?(event)
      emit_node(event, false, false, true, true, State::BLOCK_MAPPING_SIMPLE_VALUE)
    else
      write_indicator("?", true, false, true)
      emit_node(event, false, false, true, false, State::BLOCK_MAPPING_VALUE)
    end
  end

  # yaml_emitter_emit_block_mapping_value
  private def emit_block_mapping_value(event : Event*, simple : Bool) : Nil
    if simple
      write_indicator(":", false, false, false)
    else
      write_indent
      write_indicator(":", true, false, true)
    end
    emit_node(event, false, false, true, false, State::BLOCK_MAPPING_KEY)
  end

  # yaml_emitter_emit_node, with the state to return to (pushed by the
  # caller in libyaml). A scalar or an alias sets it at once when done,
  # instead of pushing it for its own pop, and pushes it only if it fails,
  # which leaves the stack as libyaml's.
  @[AlwaysInline]
  private def emit_node(event : Event*, root : Bool, sequence : Bool, mapping : Bool, simple_key : Bool, next_state : State) : Nil
    @root_context = root
    @sequence_context = sequence
    @mapping_context = mapping
    @simple_key_context = simple_key

    case event.value.kind
    when .alias?
      emit_alias(next_state)
    when .scalar?
      emit_scalar(event, next_state)
    when .sequence_start?
      @states.push(next_state)
      emit_sequence_start(event)
    when .mapping_start?
      @states.push(next_state)
      emit_mapping_start(event)
    else
      @states.push(next_state)
      error("expected SCALAR, SEQUENCE-START, MAPPING-START, or ALIAS")
    end
  end

  # yaml_emitter_emit_alias
  private def emit_alias(next_state : State) : Nil
    begin
      process_anchor
      put(' '.ord.to_u8) if @simple_key_context
    rescue ex
      @states.push(next_state)
      raise ex
    end
    @state = next_state
  end

  # yaml_emitter_emit_scalar. A simple plain scalar is written without the
  # increase_indent/pop pair around process_scalar: the indentation is only
  # read by line breaks, and it has none.
  @[AlwaysInline]
  private def emit_scalar(event : Event*, next_state : State) : Nil
    begin
      select_scalar_style(event)
      process_anchor
      process_tag
      unless write_simple_plain?
        increase_indent(true, false)
        process_scalar
        @indent = @indents.pop
      end
    rescue ex
      @states.push(next_state)
      raise ex
    end
    @state = next_state
  end

  # The usual case of process_scalar, inlined: a plain scalar of printable
  # ASCII without breaks (see `@simple_scalar`), with room for it and a
  # space before it before the next FLUSH, and no space past `@best_width`
  # that write_plain_scalar would break the line at. Writes what
  # write_plain_scalar would: the scalar as it is.
  @[AlwaysInline]
  private def write_simple_plain? : Bool
    length = @scalar_length
    return false unless @scalar_style.plain? && @simple_scalar && length < @write_limit - @pos
    if @scalar_spaces && !@simple_key_context
      # Every column it is written at is at most `@best_width` (the space
      # put before it included).
      column = @whitespace ? @column : @column + 1
      return false unless length <= @best_width - column
    end
    put(' '.ord.to_u8) unless @whitespace
    copy_bytes(@buffer + @pos, @scalar_value, length)
    @pos &+= length # below @write_limit
    @column += length
    @whitespace = false
    @indention = false
    true
  end

  # Copies *count* bytes from *src* to *dst*. Scalars are mostly short
  # words: up to 16 bytes are copied with two overlapping loads and stores
  # (of 8 or 4 bytes, or single bytes), which stay inside both ranges and
  # cost less than a call to memcpy.
  @[AlwaysInline]
  private def copy_bytes(dst : Pointer(UInt8), src : Pointer(UInt8), count : Int32) : Nil
    if count >= 8
      return dst.copy_from(src, count) if count > 16
      head = Chars.load_word(src)
      tail = Chars.load_word(src + (count &- 8))
      dst.copy_from(pointerof(head).as(Pointer(UInt8)), 8)
      (dst + (count &- 8)).copy_from(pointerof(tail).as(Pointer(UInt8)), 8)
    elsif count >= 4
      head32 = uninitialized UInt32
      tail32 = uninitialized UInt32
      pointerof(head32).as(Pointer(UInt8)).copy_from(src, 4)
      pointerof(tail32).as(Pointer(UInt8)).copy_from(src + (count &- 4), 4)
      dst.copy_from(pointerof(head32).as(Pointer(UInt8)), 4)
      (dst + (count &- 4)).copy_from(pointerof(tail32).as(Pointer(UInt8)), 4)
    elsif count > 0
      # 1 to 3 bytes: the first, middle and last cover them.
      half = count >> 1
      dst[0] = src[0]
      dst[half] = src[half]
      dst[count &- 1] = src[count &- 1]
    end
  end

  # yaml_emitter_emit_sequence_start
  private def emit_sequence_start(event : Event*) : Nil
    process_anchor
    process_tag
    if @flow_level > 0 || @canonical || event.value.sequence_style.flow? || check_empty_sequence?
      @state = State::FLOW_SEQUENCE_FIRST_ITEM
    else
      @state = State::BLOCK_SEQUENCE_FIRST_ITEM
    end
  end

  # yaml_emitter_emit_mapping_start
  private def emit_mapping_start(event : Event*) : Nil
    process_anchor
    process_tag
    if @flow_level > 0 || @canonical || event.value.mapping_style.flow? || check_empty_mapping?
      @state = State::FLOW_MAPPING_FIRST_KEY
    else
      @state = State::BLOCK_MAPPING_FIRST_KEY
    end
  end

  # yaml_emitter_check_empty_sequence
  private def check_empty_sequence? : Bool
    return false if @events.size < 2
    @events[0].kind.sequence_start? && @events[1].kind.sequence_end?
  end

  # yaml_emitter_check_empty_mapping
  private def check_empty_mapping? : Bool
    return false if @events.size < 2
    @events[0].kind.mapping_start? && @events[1].kind.mapping_end?
  end

  # yaml_emitter_check_simple_key. *event* is the event being emitted: the
  # head of the queue, or not queued at all (see `#emit`).
  private def check_simple_key?(event : Event*) : Bool
    length = 0_i64
    case event.value.kind
    when .alias?
      length += @anchor_length
    when .scalar?
      return false if @multiline
      length += @anchor_length + @tag_handle_length + @tag_suffix_length + @scalar_length
    when .sequence_start?
      return false unless check_empty_sequence?
      length += @anchor_length + @tag_handle_length + @tag_suffix_length
    when .mapping_start?
      return false unless check_empty_mapping?
      length += @anchor_length + @tag_handle_length + @tag_suffix_length
    else
      return false
    end
    length <= 128
  end

  # yaml_emitter_select_scalar_style
  @[AlwaysInline]
  private def select_scalar_style(event : Event*) : Nil
    style = event.value.scalar_style
    no_tag = @tag_handle.null? && @tag_suffix.null?

    if no_tag && !event.value.plain_implicit? && !event.value.quoted_implicit?
      error("neither tag nor implicit flags are specified")
    end

    style = ScalarStyle::PLAIN if style.any?
    style = ScalarStyle::DOUBLE_QUOTED if @canonical
    style = ScalarStyle::DOUBLE_QUOTED if @simple_key_context && @multiline

    if style.plain?
      if (@flow_level > 0 && !@flow_plain_allowed) || (@flow_level == 0 && !@block_plain_allowed)
        style = ScalarStyle::SINGLE_QUOTED
      end
      if @scalar_length == 0 && (@flow_level > 0 || @simple_key_context)
        style = ScalarStyle::SINGLE_QUOTED
      end
      style = ScalarStyle::SINGLE_QUOTED if no_tag && !event.value.plain_implicit?
    end

    if style.single_quoted?
      style = ScalarStyle::DOUBLE_QUOTED unless @single_quoted_allowed
    end

    if style.literal? || style.folded?
      if !@block_allowed || @flow_level > 0 || @simple_key_context
        style = ScalarStyle::DOUBLE_QUOTED
      end
    end

    if no_tag && !event.value.quoted_implicit? && !style.plain?
      @tag_handle = "!".to_unsafe
      @tag_handle_length = 1
    end

    @scalar_style = style
  end

  # yaml_emitter_process_anchor. Only the check is inlined (there usually is
  # no anchor); the rest would otherwise be copied into every caller.
  @[AlwaysInline]
  private def process_anchor : Nil
    write_anchor_property unless @anchor.null?
  end

  # The rest of yaml_emitter_process_anchor.
  @[NoInline]
  private def write_anchor_property : Nil
    write_indicator(@anchor_alias ? "*" : "&", true, false, false)
    write_anchor(@anchor, @anchor_length)
  end

  # yaml_emitter_process_tag. Only the check is inlined (there usually is
  # no tag); the rest would otherwise be copied into every caller.
  @[AlwaysInline]
  private def process_tag : Nil
    write_tag_property unless @tag_handle.null? && @tag_suffix.null?
  end

  # The rest of yaml_emitter_process_tag.
  @[NoInline]
  private def write_tag_property : Nil
    if !@tag_handle.null?
      write_tag_handle(@tag_handle, @tag_handle_length)
      write_tag_content(@tag_suffix, @tag_suffix_length, false) unless @tag_suffix.null?
    else
      write_indicator("!<", true, false, false)
      write_tag_content(@tag_suffix, @tag_suffix_length, false)
      write_indicator(">", false, false, false)
    end
  end

  # yaml_emitter_process_scalar
  private def process_scalar : Nil
    case @scalar_style
    when .plain?
      write_plain_scalar(@scalar_value, @scalar_length, !@simple_key_context)
    when .single_quoted?
      write_single_quoted_scalar(@scalar_value, @scalar_length, !@simple_key_context)
    when .double_quoted?
      write_double_quoted_scalar(@scalar_value, @scalar_length, !@simple_key_context)
    when .literal?
      write_literal_scalar(@scalar_value, @scalar_length)
    when .folded?
      write_folded_scalar(@scalar_value, @scalar_length)
    else
    end
  end

  # yaml_emitter_analyze_version_directive
  private def analyze_version_directive(version : {Int32, Int32}) : Nil
    if version[0] != 1 || (version[1] != 1 && version[1] != 2)
      error("incompatible %YAML directive")
    end
  end

  # yaml_emitter_analyze_tag_directive
  private def analyze_tag_directive(directive : {String, String}) : Nil
    handle, prefix = directive
    p = handle.to_unsafe
    size = handle.bytesize
    error("tag handle must not be empty") if size == 0
    error("tag handle must start with '!'") if p[0] != '!'.ord
    error("tag handle must end with '!'") if p[size - 1] != '!'.ord
    i = 1
    while i < size - 1
      error("tag handle must contain alphanumerical characters only") unless Chars.alpha?(p, i)
      i += Chars.width(p, i)
    end
    error("tag prefix must not be empty") if prefix.empty?
  end

  # yaml_emitter_analyze_anchor
  private def analyze_anchor(anchor : String, is_alias : Bool) : Nil
    p = anchor.to_unsafe
    size = anchor.bytesize
    if size == 0
      error(is_alias ? "alias value must not be empty" : "anchor value must not be empty")
    end
    i = 0
    while i != size
      unless Chars.alpha?(p, i)
        error(is_alias ? "alias value must contain alphanumerical characters only" : "anchor value must contain alphanumerical characters only")
      end
      i += Chars.width(p, i)
    end
    @anchor = p
    @anchor_length = size
    @anchor_alias = is_alias
  end

  # yaml_emitter_analyze_tag
  private def analyze_tag(tag : String) : Nil
    p = tag.to_unsafe
    size = tag.bytesize
    error("tag value must not be empty") if size == 0
    each_tag_directive do |(handle, prefix)|
      prefix_length = prefix.bytesize
      if prefix_length < size && prefix.to_unsafe.memcmp(p, prefix_length) == 0
        @tag_handle = handle.to_unsafe
        @tag_handle_length = handle.bytesize
        @tag_suffix = p + prefix_length
        @tag_suffix_length = size - prefix_length
        return
      end
    end
    @tag_suffix = p
    @tag_suffix_length = size
  end

  # yaml_emitter_analyze_scalar. Inlined up to the fast path; the general
  # case is in `#analyze_scalar_characters`.
  @[AlwaysInline]
  private def analyze_scalar(value : Pointer(UInt8), length : Int32) : Nil
    @scalar_value = value
    @scalar_length = length
    @simple_scalar = false

    if length == 0
      @multiline = false
      @flow_plain_allowed = false
      @block_plain_allowed = true
      @single_quoted_allowed = true
      @block_allowed = false
      return
    end

    simple, spaces, flow_indicators = simple_scalar(value, length)
    if simple
      @multiline = false
      @flow_plain_allowed = !flow_indicators
      @block_plain_allowed = true
      @single_quoted_allowed = true
      @block_allowed = true
      @simple_scalar = true
      @scalar_spaces = spaces
      return
    end

    analyze_scalar_characters(value, length)
  end

  # The rest of yaml_emitter_analyze_scalar (*length* > 0).
  private def analyze_scalar_characters(value : Pointer(UInt8), length : Int32) : Nil
    block_indicators = false
    flow_indicators = false
    line_breaks = false
    special_characters = false

    leading_space = false
    leading_break = false
    trailing_space = false
    trailing_break = false
    break_space = false
    space_break = false

    previous_space = false
    previous_break = false

    s = value
    if (s[0] == '-'.ord && s[1] == '-'.ord && s[2] == '-'.ord) ||
       (s[0] == '.'.ord && s[1] == '.'.ord && s[2] == '.'.ord)
      block_indicators = true
      flow_indicators = true
    end

    preceded_by_whitespace = true
    followed_by_whitespace = Chars.blankz?(s, Chars.width(s, 0))

    i = 0
    while i != length
      # Fast path: after the first character, printable ASCII characters
      # other than spaces and the indicators below set no flag. Skip a run
      # of them, leaving the look-around state as the last one would.
      if i != 0
        j = i
        while j != length && plain_ascii?(s[j])
          j &+= 1 # below length
        end
        if j != i
          i = j
          previous_space = false
          previous_break = false
          preceded_by_whitespace = false
          if i != length
            followed_by_whitespace = Chars.blankz?(s, i + Chars.width(s, i))
          end
          next
        end
      end

      c = s[i]
      if i == 0
        case c
        when '#'.ord, ','.ord, '['.ord, ']'.ord, '{'.ord, '}'.ord, '&'.ord, '*'.ord,
             '!'.ord, '|'.ord, '>'.ord, '\''.ord, '"'.ord, '%'.ord, '@'.ord, '`'.ord
          flow_indicators = true
          block_indicators = true
        when '?'.ord, ':'.ord
          flow_indicators = true
          block_indicators = true if followed_by_whitespace
        when '-'.ord
          if followed_by_whitespace
            flow_indicators = true
            block_indicators = true
          end
        else
        end
      else
        case c
        when ','.ord, '?'.ord, '['.ord, ']'.ord, '{'.ord, '}'.ord
          flow_indicators = true
        when ':'.ord
          flow_indicators = true
          block_indicators = true if followed_by_whitespace
        when '#'.ord
          if preceded_by_whitespace
            flow_indicators = true
            block_indicators = true
          end
        else
        end
      end

      if !Chars.printable?(s, i) || (!Chars.ascii?(s, i) && !@unicode)
        special_characters = true
      end

      is_break = Chars.break?(s, i)
      line_breaks = true if is_break

      if Chars.space?(s, i)
        leading_space = true if i == 0
        trailing_space = true if i + Chars.width(s, i) == length
        break_space = true if previous_break
        previous_space = true
        previous_break = false
      elsif is_break
        leading_break = true if i == 0
        trailing_break = true if i + Chars.width(s, i) == length
        space_break = true if previous_space
        previous_space = false
        previous_break = true
      else
        previous_space = false
        previous_break = false
      end

      preceded_by_whitespace = Chars.blankz?(s, i)
      i += Chars.width(s, i)
      if i != length
        followed_by_whitespace = Chars.blankz?(s, i + Chars.width(s, i))
      end
    end

    @multiline = line_breaks
    @flow_plain_allowed = true
    @block_plain_allowed = true
    @single_quoted_allowed = true
    @block_allowed = true

    if leading_space || leading_break || trailing_space || trailing_break
      @flow_plain_allowed = false
      @block_plain_allowed = false
    end

    @block_allowed = false if trailing_space

    if break_space
      @flow_plain_allowed = false
      @block_plain_allowed = false
      @single_quoted_allowed = false
    end

    if space_break || special_characters
      @flow_plain_allowed = false
      @block_plain_allowed = false
      @single_quoted_allowed = false
      @block_allowed = false
    end

    if line_breaks
      @flow_plain_allowed = false
      @block_plain_allowed = false
    end

    @flow_plain_allowed = false if flow_indicators
    @block_plain_allowed = false if block_indicators
  end

  # Printable ASCII, not a space, and not an indicator that
  # `analyze_scalar` looks at past the first character: 0x21..0x7E except
  # `#` `,` `:` `?` `[` `]` `{` `}`, as a bit set over 0x00..0x3F and
  # 0x40..0x7F.
  private PLAIN_ASCII_LOW  = 0x7BFFEFF600000000_u64
  private PLAIN_ASCII_HIGH = 0x57FFFFFFD7FFFFFF_u64

  @[AlwaysInline]
  private def plain_ascii?(c : UInt8) : Bool
    if c < 0x40
      (PLAIN_ASCII_LOW >> c) & 1 != 0
    else
      c < 0x80 && (PLAIN_ASCII_HIGH >> (c & 0x3F)) & 1 != 0
    end
  end

  # The characters of PLAIN_ASCII that can't start an indicator at the
  # start of a scalar (or `---` or `...`): all but `!` `"` `%` `&` `'` `*`
  # `-` `.` `>` `@` `` ` `` `|`.
  private FIRST_ASCII_LOW  = 0x3BFF8B1000000000_u64
  private FIRST_ASCII_HIGH = 0x47FFFFFED7FFFFFE_u64

  @[AlwaysInline]
  private def first_ascii?(c : UInt8) : Bool
    if c < 0x40
      (FIRST_ASCII_LOW >> c) & 1 != 0
    else
      c < 0x80 && (FIRST_ASCII_HIGH >> (c & 0x3F)) & 1 != 0
    end
  end

  # Whether `analyze_scalar` would set no flag for the scalar at *s*
  # (*length* > 0) but `flow_indicators`, whether it has spaces, and whether
  # it sets `flow_indicators`. That is the case when the first character is
  # in FIRST_ASCII, or is a `-` or `.` followed by a character in
  # PLAIN_ASCII (not whitespace) other than the start of `---` or `...`, the
  # others are in PLAIN_ASCII, spaces, or flow indicators (`,` `?` `[` `]`
  # `{` `}`, and `:` unless whitespace follows it), and the last isn't a
  # space. Such spaces set no flag: no break is next to them, and the
  # indicators that look at them (`#` after one, `:` before one) are
  # excluded. (Like analyze_scalar, this reads up to s[2]: the value is a
  # String's bytes, followed by a NUL.)
  @[AlwaysInline]
  private def simple_scalar(s : Pointer(UInt8), length : Int32) : {Bool, Bool, Bool}
    c = s[0]
    unless first_ascii?(c) ||
           ((c == '-'.ord || c == '.'.ord) && plain_ascii?(s[1]) && !(s[1] == c && s[2] == c))
      return {false, false, false}
    end
    return {false, false, false} if s[length - 1] == ' '.ord
    return simple_scalar_words(s, length) if length >= 8
    spaces = false
    i = 1
    while i < length
      c = s[i]
      unless plain_ascii?(c)
        return simple_scalar_bytes(s, i, length, spaces) unless c == ' '.ord
        spaces = true
      end
      i &+= 1 # below length
    end
    {true, spaces, false}
  end

  # The loop of `#simple_scalar` from *i*, with the spaces found before it,
  # for a scalar that has other bytes than PLAIN_ASCII and spaces. Out of
  # line, like `#simple_scalar_words`. (The first byte passed the test in
  # `#simple_scalar`, so it is in PLAIN_ASCII and changes no result if *i*
  # is 0.)
  @[NoInline]
  private def simple_scalar_bytes(s : Pointer(UInt8), i : Int32, length : Int32, spaces : Bool) : {Bool, Bool, Bool}
    flow_indicators = false
    while i < length
      c = s[i]
      unless plain_ascii?(c)
        if c == ' '.ord
          spaces = true
        elsif c == ','.ord || c == '?'.ord || c == '['.ord || c == ']'.ord ||
              c == '{'.ord || c == '}'.ord || c == ':'.ord
          # Whitespace after `:` (a space, or the end) makes it a block
          # indicator too.
          return {false, false, false} if c == ':'.ord && (i &+ 1 == length || s[i &+ 1] == ' '.ord)
          flow_indicators = true
        else
          return {false, false, false}
        end
      end
      i &+= 1 # below length
    end
    {true, spaces, flow_indicators}
  end

  # `#simple_scalar` for *length* >= 8: eight bytes at a time while they
  # are in PLAIN_ASCII or spaces (the words at 0, 8, ... and the last word,
  # which may overlap the one before), then byte by byte from the first
  # word that isn't. Out of line, so it doesn't weigh on the registers of
  # the inlined short case.
  @[NoInline]
  private def simple_scalar_words(s : Pointer(UInt8), length : Int32) : {Bool, Bool, Bool}
    spaces = 0_u64
    i = 0
    while true
      word = Chars.load_word(s + i)
      return simple_scalar_bytes(s, i, length, spaces != 0) unless plain_or_space_word?(word)
      spaces |= Chars.equal_mask(word, ' '.ord.to_u8)
      return {true, spaces != 0, false} if i == length &- 8
      i = Math.min(i &+ 8, length &- 8)
    end
  end

  # Whether every byte of *word* is in PLAIN_ASCII or a space: printable
  # ASCII (0x20..0x7E) other than `#` `,` `:` `?` `[` `]` `{` `}`. With
  # bit 5 set, `[` and `]` become `{` and `}`, and no other byte does.
  # (A borrow can flag a byte after a flagged one, so only "none" is exact.)
  @[AlwaysInline]
  private def plain_or_space_word?(word : UInt64) : Bool
    lower = word | 0x2020202020202020_u64
    flags = Chars.non_ascii_mask(word) | Chars.below_mask(word, 0x20_u8) |
            Chars.equal_mask(word, 0x7F_u8) |
            Chars.equal_mask(word, '#'.ord.to_u8) | Chars.equal_mask(word, ','.ord.to_u8) |
            Chars.equal_mask(word, ':'.ord.to_u8) | Chars.equal_mask(word, '?'.ord.to_u8) |
            Chars.equal_mask(lower, '{'.ord.to_u8) | Chars.equal_mask(lower, '}'.ord.to_u8)
    flags == 0
  end

  # yaml_emitter_analyze_event (inlined: mostly a few stores)
  @[AlwaysInline]
  private def analyze_event(event : Event*) : Nil
    @anchor = Pointer(UInt8).null
    @anchor_length = 0
    @tag_handle = Pointer(UInt8).null
    @tag_handle_length = 0
    @tag_suffix = Pointer(UInt8).null
    @tag_suffix_length = 0
    @scalar_value = Pointer(UInt8).null
    @scalar_length = 0

    case event.value.kind
    when .alias?
      analyze_anchor(event.value.anchor || "", true)
    when .scalar?
      if anchor = event.value.anchor
        analyze_anchor(anchor, false)
      end
      if (tag = event.value.tag) && (@canonical || (!event.value.plain_implicit? && !event.value.quoted_implicit?))
        analyze_tag(tag)
      end
      value = event.value.value
      analyze_scalar(value.to_unsafe, value.bytesize)
    when .sequence_start?, .mapping_start?
      if anchor = event.value.anchor
        analyze_anchor(anchor, false)
      end
      if (tag = event.value.tag) && (@canonical || !event.value.implicit?)
        analyze_tag(tag)
      end
    else
    end
  end

  # FLUSH: flushes when fewer than 5 of OUTPUT_BUFFER_SIZE bytes are free,
  # first growing the allocated buffer if it is smaller. Afterwards there is
  # room for at least 5 bytes, so the writes below advance `@pos` with `&+`:
  # it stays below `@capacity`.
  @[AlwaysInline]
  private def flush_if_needed : Nil
    make_room unless @pos < @write_limit
  end

  # The rest of FLUSH, out of line: it runs about once per 16 KiB of output,
  # and FLUSH is inlined into every PUT and WRITE.
  @[NoInline]
  private def make_room : Nil
    grow_buffer
    flush unless @pos < @write_limit
  end

  # Grows the buffer to OUTPUT_BUFFER_SIZE (see INITIAL_BUFFER_SIZE).
  private def grow_buffer : Nil
    return if @capacity == OUTPUT_BUFFER_SIZE
    @capacity = OUTPUT_BUFFER_SIZE
    @write_limit = @capacity - 5
    @buffer = @buffer.realloc(@capacity)
  end

  # PUT
  @[AlwaysInline]
  private def put(value : UInt8) : Nil
    flush_if_needed
    @buffer[@pos] = value
    @pos &+= 1
    @column += 1
  end

  # PUT_BREAK (line break is always LN)
  @[AlwaysInline]
  private def put_break : Nil
    flush_if_needed
    @buffer[@pos] = '\n'.ord.to_u8
    @pos &+= 1
    @column = 0
  end

  # COPY: copies one UTF-8 character from p+i, returns the new index. The
  # character (at most 4 bytes, in the value: the Builder rejects malformed
  # UTF-8) fits after a FLUSH.
  @[AlwaysInline]
  private def copy(p : Pointer(UInt8), i : Int32) : Int32
    w = Chars.width(p, i)
    buf = @buffer + @pos
    k = 0
    while k < w
      buf[k] = p[i &+ k]
      k &+= 1
    end
    @pos &+= w
    i &+ w
  end

  # WRITE. Inlined for an ASCII character, which is one PUT; longer ones are
  # copied out of line (`#write_multibyte`).
  @[AlwaysInline]
  private def write(p : Pointer(UInt8), i : Int32) : Int32
    c = p[i]
    return write_multibyte(p, i) unless c < 0x80
    put(c)
    i &+ 1
  end

  # WRITE of a character that isn't ASCII.
  @[NoInline]
  private def write_multibyte(p : Pointer(UInt8), i : Int32) : Int32
    flush_if_needed
    i = copy(p, i)
    @column += 1
    i
  end

  # WRITE repeated over the characters at p+i (before *length*) that are
  # ASCII, satisfy the block, and can be written one byte each before
  # `FLUSH` would flush or grow the buffer; returns the new index. Loops
  # that WRITE character by character use it to copy such a run at once, so
  # the buffer is still flushed at the same characters. Each byte is stored
  # as it is checked: short runs are the common case, and a call to memcpy
  # per run would cost more than the copy.
  @[AlwaysInline]
  private def write_ascii_run(p : Pointer(UInt8), i : Int32, length : Int32, &) : Int32
    # `n < limit` keeps p[i + n] inside the value and dst[n] inside the
    # buffer, so `n`, `i + n` and `@pos + n` can't overflow.
    limit = Math.min(length - i, @write_limit - @pos)
    src = p + i
    dst = @buffer + @pos
    n = 0
    while n < limit
      b = src[n]
      break unless b < 0x80 && yield b
      dst[n] = b
      n &+= 1
    end
    @pos &+= n
    @column += n
    i &+ n
  end

  # WRITE_BREAK
  @[AlwaysInline]
  private def write_break(p : Pointer(UInt8), i : Int32) : Int32
    flush_if_needed
    if p[i] == '\n'.ord
      put_break
      i + 1
    else
      i = copy(p, i)
      @column = 0
      i
    end
  end

  # yaml_emitter_write_indent
  private def write_indent : Nil
    indent = @indent >= 0 ? @indent : 0
    column = @column
    need_break = !@indention || column > indent || (column == indent && !@whitespace)
    # Fast path: an indentation of at most 16 columns, and room for the
    # break and 16 spaces before the next FLUSH, so none of the PUTs
    # would flush (or grow the buffer). Store the break and 16 spaces;
    # those past the indentation are past the end of the output, which
    # overwrites them. (`@write_limit` is at least INITIAL_BUFFER_SIZE - 5.)
    pos = @pos
    return write_indent_slow(indent, need_break) unless indent <= 16 && pos <= @write_limit &- 17
    buffer = @buffer
    if need_break
      buffer[pos] = '\n'.ord.to_u8
      pos &+= 1
      column = 0
    end
    spaces = 0x2020202020202020_u64
    (buffer + pos).copy_from(pointerof(spaces).as(Pointer(UInt8)), 8)
    (buffer + pos + 8).copy_from(pointerof(spaces).as(Pointer(UInt8)), 8)
    # Without a break, `column <= indent` (`column > indent` needs one).
    @pos = pos &+ (indent &- column)
    @column = indent
    @whitespace = true
    @indention = true
  end

  # The rest of yaml_emitter_write_indent: PUT per character, except that
  # the spaces that fit before a flush (or growing the buffer) are stored
  # at once.
  @[NoInline]
  private def write_indent_slow(indent : Int32, need_break : Bool) : Nil
    put_break if need_break
    while @column < indent
      n = Math.min(indent - @column, @write_limit - @pos)
      if n > 0
        (@buffer + @pos).fill(n, ' '.ord.to_u8)
        @pos += n
        @column += n
        next
      end
      put(' '.ord.to_u8)
    end
    @whitespace = true
    @indention = true
  end

  # yaml_emitter_write_indicator (inlined: indicators are short constants).
  # Every indicator is ASCII, so its WRITEs are PUTs (same FLUSH points).
  @[AlwaysInline]
  private def write_indicator(indicator : String, need_whitespace : Bool, is_whitespace : Bool, is_indention : Bool) : Nil
    put(' '.ord.to_u8) if need_whitespace && !@whitespace
    p = indicator.to_unsafe
    size = indicator.bytesize
    i = 0
    while i != size
      put(p[i])
      i &+= 1
    end
    @whitespace = is_whitespace
    @indention = @indention && is_indention
  end

  # yaml_emitter_write_anchor
  private def write_anchor(p : Pointer(UInt8), length : Int32) : Nil
    i = 0
    while i != length
      i = write(p, i)
    end
    @whitespace = false
    @indention = false
  end

  # yaml_emitter_write_tag_handle
  private def write_tag_handle(p : Pointer(UInt8), length : Int32) : Nil
    put(' '.ord.to_u8) unless @whitespace
    i = 0
    while i != length
      i = write(p, i)
    end
    @whitespace = false
    @indention = false
  end

  @[AlwaysInline]
  private def hex_digit(v : UInt32) : UInt8
    (v < 10 ? v + '0'.ord : v + 'A'.ord - 10).to_u8
  end

  # yaml_emitter_write_tag_content
  private def write_tag_content(p : Pointer(UInt8), length : Int32, need_whitespace : Bool) : Nil
    put(' '.ord.to_u8) if need_whitespace && !@whitespace
    i = 0
    while i != length
      c = p[i]
      if Chars.alpha?(p, i) ||
         c == ';'.ord || c == '/'.ord || c == '?'.ord || c == ':'.ord ||
         c == '@'.ord || c == '&'.ord || c == '='.ord || c == '+'.ord ||
         c == '$'.ord || c == ','.ord || c == '_'.ord || c == '.'.ord ||
         c == '~'.ord || c == '*'.ord || c == '\''.ord || c == '('.ord ||
         c == ')'.ord || c == '['.ord || c == ']'.ord
        i = write(p, i)
      else
        width = Chars.width(p, i)
        while width > 0
          width -= 1
          value = p[i].to_u32
          i += 1
          put('%'.ord.to_u8)
          put(hex_digit(value >> 4))
          put(hex_digit(value & 0x0F))
        end
      end
    end
    @whitespace = false
    @indention = false
  end

  # yaml_emitter_write_plain_scalar
  private def write_plain_scalar(p : Pointer(UInt8), length : Int32, allow_breaks : Bool) : Nil
    spaces = false
    breaks = false

    # Avoid trailing spaces for empty values in block mode.
    if !@whitespace && (length != 0 || @flow_level > 0)
      put(' '.ord.to_u8)
    end

    i = 0
    while i != length
      if Chars.space?(p, i)
        if allow_breaks && !spaces && @column > @best_width && !Chars.space?(p, i + 1)
          write_indent
          i += Chars.width(p, i)
        else
          i = write(p, i)
        end
        spaces = true
      elsif Chars.break?(p, i)
        put_break if !breaks && p[i] == '\n'.ord
        i = write_break(p, i)
        @indention = true
        breaks = true
      else
        write_indent if breaks
        i = write(p, i)
        # Fast path: WRITE repeated over the following characters that would
        # also take this branch.
        i = write_ascii_run(p, i, length) { |b| b != ' '.ord && b != '\r'.ord && b != '\n'.ord }
        @indention = false
        spaces = false
        breaks = false
      end
    end

    @whitespace = false
    @indention = false
  end

  # yaml_emitter_write_single_quoted_scalar
  private def write_single_quoted_scalar(p : Pointer(UInt8), length : Int32, allow_breaks : Bool) : Nil
    spaces = false
    breaks = false

    write_indicator("'", true, false, false)

    i = 0
    while i != length
      if Chars.space?(p, i)
        if allow_breaks && !spaces && @column > @best_width && i != 0 &&
           i != length - 1 && !Chars.space?(p, i + 1)
          write_indent
          i += Chars.width(p, i)
        else
          i = write(p, i)
        end
        spaces = true
      elsif Chars.break?(p, i)
        put_break if !breaks && p[i] == '\n'.ord
        i = write_break(p, i)
        @indention = true
        breaks = true
      else
        write_indent if breaks
        put('\''.ord.to_u8) if p[i] == '\''.ord
        i = write(p, i)
        # Fast path: WRITE repeated over the following characters that would
        # also take this branch without a quote to double.
        i = write_ascii_run(p, i, length) { |b| b != ' '.ord && b != '\r'.ord && b != '\n'.ord && b != '\''.ord }
        @indention = false
        spaces = false
        breaks = false
      end
    end

    write_indent if breaks
    write_indicator("'", false, false, false)

    @whitespace = false
    @indention = false
  end

  # yaml_emitter_write_double_quoted_scalar
  private def write_double_quoted_scalar(p : Pointer(UInt8), length : Int32, allow_breaks : Bool) : Nil
    spaces = false

    write_indicator("\"", true, false, false)

    i = 0
    while i != length
      c = p[i]
      if !Chars.printable?(p, i) || (!@unicode && !Chars.ascii?(p, i)) ||
         Chars.bom?(p, i) || Chars.break?(p, i) || c == '"'.ord || c == '\\'.ord
        i = write_escape(p, i)
        spaces = false
      elsif c == ' '.ord
        if allow_breaks && !spaces && @column > @best_width && i != 0 && i != length - 1
          write_indent
          put('\\'.ord.to_u8) if Chars.space?(p, i + 1)
          i += 1
        else
          i = write(p, i)
        end
        spaces = true
      else
        i = write(p, i)
        # Fast path: WRITE repeated over the following characters that would
        # also take this branch (printable ASCII, no space, quote or escape).
        i = write_ascii_run(p, i, length) { |b| b > 0x20 && b < 0x7F && b != '"'.ord && b != '\\'.ord }
        spaces = false
      end
    end

    write_indicator("\"", false, false, false)

    @whitespace = false
    @indention = false
  end

  # The escape branch of yaml_emitter_write_double_quoted_scalar, out of
  # line: escapes are rare. Writes the character at p+i as an escape
  # sequence and returns the index after it. libyaml PUTs the letter in each
  # branch; here the branches pick it (0 for none) and one PUT writes it.
  @[NoInline]
  private def write_escape(p : Pointer(UInt8), i : Int32) : Int32
    octet = p[i]
    width = (octet & 0x80) == 0x00 ? 1 : (octet & 0xE0) == 0xC0 ? 2 : (octet & 0xF0) == 0xE0 ? 3 : (octet & 0xF8) == 0xF0 ? 4 : 0
    value = ((octet & 0x80) == 0x00 ? octet & 0x7F : (octet & 0xE0) == 0xC0 ? octet & 0x1F : (octet & 0xF0) == 0xE0 ? octet & 0x0F : (octet & 0xF8) == 0xF0 ? octet & 0x07 : 0).to_u32
    k = 1
    while k < width
      value = (value << 6) + (p[i + k] & 0x3F).to_u32
      k += 1
    end
    i += width

    put('\\'.ord.to_u8)

    letter = case value
             when   0x00 then '0'
             when   0x07 then 'a'
             when   0x08 then 'b'
             when   0x09 then 't'
             when   0x0A then 'n'
             when   0x0B then 'v'
             when   0x0C then 'f'
             when   0x0D then 'r'
             when   0x1B then 'e'
             when   0x22 then '"'
             when   0x5C then '\\'
             when   0x85 then 'N'
             when   0xA0 then '_'
             when 0x2028 then 'L'
             when 0x2029 then 'P'
             else              '\0'
             end
    if letter != '\0'
      put(letter.ord.to_u8)
    else
      if value <= 0xFF
        put('x'.ord.to_u8)
        w = 2
      elsif value <= 0xFFFF
        put('u'.ord.to_u8)
        w = 4
      else
        put('U'.ord.to_u8)
        w = 8
      end
      k = (w - 1) * 4
      while k >= 0
        put(hex_digit((value >> k) & 0x0F))
        k -= 4
      end
    end
    i
  end

  # yaml_emitter_write_block_scalar_hints
  private def write_block_scalar_hints(p : Pointer(UInt8), length : Int32) : Nil
    if Chars.space?(p, 0) || Chars.break?(p, 0)
      write_indicator(INDENT_HINTS[@best_indent], false, false, false)
    end

    @open_ended = 0

    chomp_hint = nil
    i = length
    if i == 0
      chomp_hint = "-"
    else
      i -= 1
      while (p[i] & 0xC0) == 0x80
        i -= 1
      end
      if !Chars.break?(p, i)
        chomp_hint = "-"
      elsif i == 0
        chomp_hint = "+"
        @open_ended = 2
      else
        i -= 1
        while (p[i] & 0xC0) == 0x80
          i -= 1
        end
        if Chars.break?(p, i)
          chomp_hint = "+"
          @open_ended = 2
        end
      end
    end

    write_indicator(chomp_hint, false, false, false) if chomp_hint
  end

  # yaml_emitter_write_literal_scalar (not inlined into process_scalar:
  # block scalars are rare)
  @[NoInline]
  private def write_literal_scalar(p : Pointer(UInt8), length : Int32) : Nil
    breaks = true

    write_indicator("|", true, false, false)
    write_block_scalar_hints(p, length)
    put_break
    @indention = true
    @whitespace = true

    i = 0
    while i != length
      if Chars.break?(p, i)
        i = write_break(p, i)
        @indention = true
        breaks = true
      else
        write_indent if breaks
        i = write(p, i)
        # Fast path: WRITE repeated over the rest of the line.
        i = write_ascii_run(p, i, length) { |b| b != '\r'.ord && b != '\n'.ord }
        @indention = false
        breaks = false
      end
    end
  end

  # yaml_emitter_write_folded_scalar (not inlined into process_scalar:
  # block scalars are rare)
  @[NoInline]
  private def write_folded_scalar(p : Pointer(UInt8), length : Int32) : Nil
    breaks = true
    leading_spaces = true

    write_indicator(">", true, false, false)
    write_block_scalar_hints(p, length)
    put_break
    @indention = true
    @whitespace = true

    i = 0
    while i != length
      if Chars.break?(p, i)
        if !breaks && !leading_spaces && p[i] == '\n'.ord
          k = 0
          while Chars.break?(p, i + k)
            k += Chars.width(p, i + k)
          end
          put_break unless Chars.blankz?(p, i + k)
        end
        i = write_break(p, i)
        @indention = true
        breaks = true
      else
        if breaks
          write_indent
          leading_spaces = Chars.blank?(p, i)
        end
        if !breaks && Chars.space?(p, i) && !Chars.space?(p, i + 1) && @column > @best_width
          write_indent
          i += Chars.width(p, i)
        else
          i = write(p, i)
          # Fast path: WRITE repeated over the following characters that
          # would also take this branch.
          i = write_ascii_run(p, i, length) { |b| b != ' '.ord && b != '\r'.ord && b != '\n'.ord }
        end
        @indention = false
        breaks = false
      end
    end
  end
end
