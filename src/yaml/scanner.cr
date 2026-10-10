# :nodoc:
#
# A port of libyaml 0.2.5 `scanner.c`: turns the decoded character stream of
# `YAML::Reader` into `YAML::Token`s.
#
# libyaml reports errors by returning 0 and filling `parser->problem`; here a
# `ParseException` is raised instead (with identical text and marks) and kept,
# so that every later `#peek_token` raises it again.
class YAML::Scanner < YAML::Reader
  # libyaml `yaml_simple_key_t`.
  private record SimpleKey,
    possible : Bool,
    required : Bool,
    token_number : Int64,
    mark : Mark

  @tokens = Queue(Token).new
  @token_available = false
  # Token numbers and character indices count input, so they can't overflow
  # an `Int64` and are computed with wrapping arithmetic; a token number
  # minus `@tokens_parsed` is a position in the queue (an `Int32`).
  @tokens_parsed = 0_i64
  @stream_start_produced = false
  @stream_end_produced = false
  @indent = -1
  @indents = Stack(Int32).new
  @simple_key_allowed = false
  @simple_keys = [] of SimpleKey
  # Every simple key below this index is known not to be possible. libyaml
  # walks the whole stack on every token, which is quadratic in the flow
  # nesting depth; starting at the floor visits the same possible keys in
  # the same order, so behavior is unchanged.
  @possible_floor = 0
  # Lower bounds of `mark.line` and `mark.index + 1024` over all possible
  # simple keys (`Int64::MAX` when there are none). Until the position
  # passes one of them no key can be stale, so `#stale_simple_keys` has
  # nothing to do.
  @stale_key_line = Int64::MAX
  @stale_key_index = Int64::MAX
  @flow_level = 0
  @scanner_error : ParseException? = nil

  # Scratch strings (libyaml allocates them per scan with STRING_INIT).
  @string = ByteBuffer.new
  @leading_break = ByteBuffer.new
  @trailing_breaks = ByteBuffer.new
  @whitespaces = ByteBuffer.new

  def stream_end_produced? : Bool
    @stream_end_produced
  end

  # libyaml `PEEK_TOKEN`.
  @[AlwaysInline]
  def peek_token : Token
    # A stored error leaves `@token_available` false, so it is raised again
    # by `#fetch_tokens`.
    fetch_tokens unless @token_available
    @tokens.first
  end

  private def fetch_tokens : Nil
    if error = @scanner_error
      raise error
    end
    begin
      fetch_more_tokens
    rescue ex : ParseException
      @scanner_error = ex
      raise ex
    end
  end

  # libyaml `SKIP_TOKEN`.
  @[AlwaysInline]
  def skip_token : Nil
    @tokens_parsed &+= 1
    token = @tokens.shift
    @stream_end_produced = token.kind.stream_end?
    # libyaml clears `token_available` here, so the next `PEEK_TOKEN` runs
    # `yaml_parser_fetch_more_tokens`. While tokens remain, that function
    # first checks for stale simple keys, which is a no-op: the position
    # hasn't moved since its previous run ended with the same check. So it
    # fetches nothing unless the next token is a possible simple key, and
    # otherwise the token stays available without the call.
    @token_available = !@tokens.empty? && !simple_key_pending?
  end

  # yaml_parser_set_scanner_error
  private def scanner_error(context : String?, context_mark : Mark, problem : String) : NoReturn
    syntax_error(problem, mark, context, context_mark)
  end

  # Whether the next token is a possible simple key, so that more tokens are
  # needed to decide whether a KEY goes before it.
  @[AlwaysInline]
  private def simple_key_pending? : Bool
    i = @possible_floor
    size = @simple_keys.size
    while i < size
      simple_key = @simple_keys.unsafe_fetch(i)
      return true if simple_key.possible && simple_key.token_number == @tokens_parsed
      i += 1
    end
    false
  end

  # yaml_parser_fetch_more_tokens
  private def fetch_more_tokens : Nil
    while true
      need_more_tokens = false
      if @tokens.empty?
        need_more_tokens = true
      else
        stale_simple_keys
        need_more_tokens = simple_key_pending?
      end
      break unless need_more_tokens
      fetch_next_token
    end
    @token_available = true
  end

  # yaml_parser_fetch_next_token
  private def fetch_next_token : Nil
    cache(1)

    return fetch_stream_start unless @stream_start_produced

    scan_to_next_token
    stale_simple_keys
    unroll_indent(@column)

    cache(4)

    return fetch_stream_end if z?

    if @column == 0 && check?('%')
      return fetch_directive
    end

    if @column == 0 && check?('-', 0) && check?('-', 1) && check?('-', 2) && blankz?(3)
      return fetch_document_indicator(TokenKind::DOCUMENT_START)
    end

    if @column == 0 && check?('.', 0) && check?('.', 1) && check?('.', 2) && blankz?(3)
      return fetch_document_indicator(TokenKind::DOCUMENT_END)
    end

    c = byte
    case c
    when '['.ord then return fetch_flow_collection_start(TokenKind::FLOW_SEQUENCE_START)
    when '{'.ord then return fetch_flow_collection_start(TokenKind::FLOW_MAPPING_START)
    when ']'.ord then return fetch_flow_collection_end(TokenKind::FLOW_SEQUENCE_END)
    when '}'.ord then return fetch_flow_collection_end(TokenKind::FLOW_MAPPING_END)
    when ','.ord then return fetch_flow_entry
    end

    return fetch_block_entry if c == '-'.ord && blankz?(1)
    return fetch_key if c == '?'.ord && (@flow_level != 0 || blankz?(1))
    return fetch_value if c == ':'.ord && (@flow_level != 0 || blankz?(1))

    case c
    when '*'.ord then return fetch_anchor(TokenKind::ALIAS)
    when '&'.ord then return fetch_anchor(TokenKind::ANCHOR)
    when '!'.ord then return fetch_tag
    end

    return fetch_block_scalar(true) if c == '|'.ord && @flow_level == 0
    return fetch_block_scalar(false) if c == '>'.ord && @flow_level == 0
    return fetch_flow_scalar(true) if c == '\''.ord
    return fetch_flow_scalar(false) if c == '"'.ord

    if !(blankz? || c == '-'.ord || c == '?'.ord || c == ':'.ord ||
       c == ','.ord || c == '['.ord || c == ']'.ord || c == '{'.ord ||
       c == '}'.ord || c == '#'.ord || c == '&'.ord || c == '*'.ord ||
       c == '!'.ord || c == '|'.ord || c == '>'.ord || c == '\''.ord ||
       c == '"'.ord || c == '%'.ord || c == '@'.ord || c == '`'.ord) ||
       (c == '-'.ord && !blank?(1)) ||
       (@flow_level == 0 && (c == '?'.ord || c == ':'.ord) && !blankz?(1))
      return fetch_plain_scalar
    end

    scanner_error("while scanning for the next token", mark,
      "found character that cannot start any token")
  end

  # yaml_parser_stale_simple_keys
  @[AlwaysInline]
  private def stale_simple_keys : Nil
    return if @line <= @stale_key_line && @index <= @stale_key_index
    remove_stale_simple_keys
  end

  private def remove_stale_simple_keys : Nil
    stale_key_line = Int64::MAX
    stale_key_index = Int64::MAX
    i = @possible_floor
    size = @simple_keys.size
    while i < size
      simple_key = @simple_keys.unsafe_fetch(i)
      if simple_key.possible
        if simple_key.mark.line < @line || simple_key.mark.index &+ 1024 < @index
          if simple_key.required
            scanner_error("while scanning a simple key", simple_key.mark,
              "could not find expected ':'")
          end
          @simple_keys[i] = simple_key.copy_with(possible: false)
        else
          stale_key_line = Math.min(stale_key_line, simple_key.mark.line)
          stale_key_index = Math.min(stale_key_index, simple_key.mark.index &+ 1024)
        end
      end
      i += 1
    end
    @stale_key_line = stale_key_line
    @stale_key_index = stale_key_index
    while @possible_floor < size && !@simple_keys.unsafe_fetch(@possible_floor).possible
      @possible_floor += 1
    end
  end

  # The simple key of the current flow level (libyaml's
  # `simple_keys.top - 1`). The stack is never empty here: the stream's key
  # is pushed by `#fetch_stream_start` before any other token is fetched,
  # and `#decrease_flow_level` only pops the keys of flow levels.
  @[AlwaysInline]
  private def current_simple_key : Pointer(SimpleKey)
    @simple_keys.to_unsafe + (@simple_keys.size - 1)
  end

  # yaml_parser_save_simple_key
  private def save_simple_key : Nil
    required = @flow_level == 0 && @indent == @column
    if @simple_key_allowed
      simple_key = SimpleKey.new(true, required, @tokens_parsed &+ @tokens.size, mark)
      remove_simple_key
      current_simple_key.value = simple_key
      @possible_floor = Math.min(@possible_floor, @simple_keys.size - 1)
      @stale_key_line = Math.min(@stale_key_line, simple_key.mark.line)
      @stale_key_index = Math.min(@stale_key_index, simple_key.mark.index &+ 1024)
    end
  end

  # yaml_parser_remove_simple_key
  private def remove_simple_key : Nil
    pointer = current_simple_key
    simple_key = pointer.value
    if simple_key.possible && simple_key.required
      scanner_error("while scanning a simple key", simple_key.mark,
        "could not find expected ':'")
    end
    pointer.value = simple_key.copy_with(possible: false)
  end

  # yaml_parser_increase_flow_level
  private def increase_flow_level : Nil
    @simple_keys << SimpleKey.new(false, false, 0_i64, Mark.new)
    @flow_level += 1
  end

  # yaml_parser_decrease_flow_level
  private def decrease_flow_level : Nil
    if @flow_level != 0
      @flow_level -= 1
      @simple_keys.pop
      @possible_floor = Math.min(@possible_floor, @simple_keys.size)
    end
  end

  # yaml_parser_roll_indent
  private def roll_indent(column : Int64, number : Int64, kind : TokenKind, mark : Mark) : Nil
    return if @flow_level != 0
    if @indent < column
      @indents << @indent
      @indent = column.to_i32
      token = Token.new(kind, mark, mark)
      if number == -1
        @tokens << token
      else
        @tokens.insert((number &- @tokens_parsed).to_i32!, token)
      end
    end
  end

  # yaml_parser_unroll_indent
  @[AlwaysInline]
  private def unroll_indent(column : Int64) : Nil
    return if @flow_level != 0
    while @indent > column
      m = mark
      @tokens << Token.new(TokenKind::BLOCK_END, m, m)
      @indent = @indents.pop
    end
  end

  # yaml_parser_fetch_stream_start
  private def fetch_stream_start : Nil
    @indent = -1
    @simple_keys << SimpleKey.new(false, false, 0_i64, Mark.new)
    @simple_key_allowed = true
    @stream_start_produced = true
    m = mark
    @tokens << Token.new(TokenKind::STREAM_START, m, m)
  end

  # yaml_parser_fetch_stream_end
  private def fetch_stream_end : Nil
    if @column != 0
      @column = 0_i64
      @line += 1
    end
    unroll_indent(-1_i64)
    remove_simple_key
    @simple_key_allowed = false
    m = mark
    @tokens << Token.new(TokenKind::STREAM_END, m, m)
  end

  # yaml_parser_fetch_directive
  private def fetch_directive : Nil
    unroll_indent(-1_i64)
    remove_simple_key
    @simple_key_allowed = false
    @tokens << scan_directive
  end

  # yaml_parser_fetch_document_indicator
  private def fetch_document_indicator(kind : TokenKind) : Nil
    unroll_indent(-1_i64)
    remove_simple_key
    @simple_key_allowed = false
    start_mark = mark
    skip
    skip
    skip
    @tokens << Token.new(kind, start_mark, mark)
  end

  # yaml_parser_fetch_flow_collection_start
  private def fetch_flow_collection_start(kind : TokenKind) : Nil
    save_simple_key
    increase_flow_level
    @simple_key_allowed = true
    start_mark = mark
    skip
    @tokens << Token.new(kind, start_mark, mark)
  end

  # yaml_parser_fetch_flow_collection_end
  private def fetch_flow_collection_end(kind : TokenKind) : Nil
    remove_simple_key
    decrease_flow_level
    @simple_key_allowed = false
    start_mark = mark
    skip
    @tokens << Token.new(kind, start_mark, mark)
  end

  # yaml_parser_fetch_flow_entry
  private def fetch_flow_entry : Nil
    remove_simple_key
    @simple_key_allowed = true
    start_mark = mark
    skip
    @tokens << Token.new(TokenKind::FLOW_ENTRY, start_mark, mark)
  end

  # yaml_parser_fetch_block_entry
  private def fetch_block_entry : Nil
    if @flow_level == 0
      unless @simple_key_allowed
        scanner_error(nil, mark, "block sequence entries are not allowed in this context")
      end
      roll_indent(@column, -1_i64, TokenKind::BLOCK_SEQUENCE_START, mark)
    end
    remove_simple_key
    @simple_key_allowed = true
    start_mark = mark
    skip
    @tokens << Token.new(TokenKind::BLOCK_ENTRY, start_mark, mark)
  end

  # yaml_parser_fetch_key
  private def fetch_key : Nil
    if @flow_level == 0
      unless @simple_key_allowed
        scanner_error(nil, mark, "mapping keys are not allowed in this context")
      end
      roll_indent(@column, -1_i64, TokenKind::BLOCK_MAPPING_START, mark)
    end
    remove_simple_key
    @simple_key_allowed = @flow_level == 0
    start_mark = mark
    skip
    @tokens << Token.new(TokenKind::KEY, start_mark, mark)
  end

  # yaml_parser_fetch_value
  private def fetch_value : Nil
    pointer = current_simple_key
    simple_key = pointer.value
    if simple_key.possible
      @tokens.insert((simple_key.token_number &- @tokens_parsed).to_i32!,
        Token.new(TokenKind::KEY, simple_key.mark, simple_key.mark))
      roll_indent(simple_key.mark.column, simple_key.token_number,
        TokenKind::BLOCK_MAPPING_START, simple_key.mark)
      pointer.value = simple_key.copy_with(possible: false)
      @simple_key_allowed = false
    else
      if @flow_level == 0
        unless @simple_key_allowed
          scanner_error(nil, mark, "mapping values are not allowed in this context")
        end
        roll_indent(@column, -1_i64, TokenKind::BLOCK_MAPPING_START, mark)
      end
      @simple_key_allowed = @flow_level == 0
    end
    start_mark = mark
    skip
    @tokens << Token.new(TokenKind::VALUE, start_mark, mark)
  end

  # yaml_parser_fetch_anchor
  private def fetch_anchor(kind : TokenKind) : Nil
    save_simple_key
    @simple_key_allowed = false
    @tokens << scan_anchor(kind)
  end

  # yaml_parser_fetch_tag
  private def fetch_tag : Nil
    save_simple_key
    @simple_key_allowed = false
    @tokens << scan_tag
  end

  # yaml_parser_fetch_block_scalar
  private def fetch_block_scalar(literal : Bool) : Nil
    remove_simple_key
    @simple_key_allowed = true
    @tokens << scan_block_scalar(literal)
  end

  # yaml_parser_fetch_flow_scalar
  private def fetch_flow_scalar(single : Bool) : Nil
    save_simple_key
    @simple_key_allowed = false
    @tokens << scan_flow_scalar(single)
  end

  # yaml_parser_fetch_plain_scalar
  private def fetch_plain_scalar : Nil
    save_simple_key
    @simple_key_allowed = false
    @tokens << scan_plain_scalar
  end

  # yaml_parser_scan_to_next_token
  private def scan_to_next_token : Nil
    while true
      cache(1)
      skip if @column == 0 && bom?

      cache(1)
      # Fast path: `SKIP` + `CACHE(1)` repeated over a run of whitespace.
      tabs = @flow_level != 0 || !@simple_key_allowed
      n = ascii_run(1) { |b| b == ' '.ord || (tabs && b == '\t'.ord) }
      skip_ascii(n) if n > 0
      while check?(' ') || ((@flow_level != 0 || !@simple_key_allowed) && check?('\t'))
        skip
        cache(1)
      end

      if check?('#')
        until breakz?
          # Fast path: `SKIP` + `CACHE(1)` repeated over the comment text.
          n = ascii_run(1) { |b| b >= 0x20 || b == '\t'.ord }
          if n > 0
            skip_ascii(n)
            next
          end
          skip
          cache(1)
        end
      end

      if break?
        cache(2)
        skip_line
        @simple_key_allowed = true if @flow_level == 0
      else
        break
      end
    end
  end

  # yaml_parser_scan_directive
  private def scan_directive : Token
    start_mark = mark
    skip

    name = scan_directive_name(start_mark)

    if name == "YAML"
      major, minor = scan_version_directive_value(start_mark)
      token = Token.new(TokenKind::VERSION_DIRECTIVE, start_mark, mark, major: major, minor: minor)
    elsif name == "TAG"
      handle, prefix = scan_tag_directive_value(start_mark)
      token = Token.new(TokenKind::TAG_DIRECTIVE, start_mark, mark, value: prefix, handle: handle)
    else
      scanner_error("while scanning a directive", start_mark, "found unknown directive name")
    end

    cache(1)
    while blank?
      skip
      cache(1)
    end

    if check?('#')
      until breakz?
        skip
        cache(1)
      end
    end

    unless breakz?
      scanner_error("while scanning a directive", start_mark,
        "did not find expected comment or line break")
    end

    if break?
      cache(2)
      skip_line
    end

    token
  end

  # yaml_parser_scan_directive_name
  private def scan_directive_name(start_mark : Mark) : String
    string = @string
    string.clear

    cache(1)
    while alpha?
      read(string)
      cache(1)
    end

    if string.empty?
      scanner_error("while scanning a directive", start_mark,
        "could not find expected directive name")
    end

    unless blankz?
      scanner_error("while scanning a directive", start_mark,
        "found unexpected non-alphabetical character")
    end

    string.to_s
  end

  # yaml_parser_scan_version_directive_value
  private def scan_version_directive_value(start_mark : Mark) : {Int32, Int32}
    cache(1)
    while blank?
      skip
      cache(1)
    end

    major = scan_version_directive_number(start_mark)

    unless check?('.')
      scanner_error("while scanning a %YAML directive", start_mark,
        "did not find expected digit or '.' character")
    end
    skip

    minor = scan_version_directive_number(start_mark)
    {major, minor}
  end

  private MAX_NUMBER_LENGTH = 9

  # yaml_parser_scan_version_directive_number
  private def scan_version_directive_number(start_mark : Mark) : Int32
    value = 0
    length = 0

    cache(1)
    while digit?
      length += 1
      if length > MAX_NUMBER_LENGTH
        scanner_error("while scanning a %YAML directive", start_mark,
          "found extremely long version number")
      end
      value = value * 10 + as_digit
      skip
      cache(1)
    end

    if length == 0
      scanner_error("while scanning a %YAML directive", start_mark,
        "did not find expected version number")
    end

    value
  end

  # yaml_parser_scan_tag_directive_value
  private def scan_tag_directive_value(start_mark : Mark) : {String, String}
    cache(1)
    while blank?
      skip
      cache(1)
    end

    handle = scan_tag_handle(true, start_mark)

    cache(1)
    unless blank?
      scanner_error("while scanning a %TAG directive", start_mark,
        "did not find expected whitespace")
    end

    while blank?
      skip
      cache(1)
    end

    prefix = scan_tag_uri(true, true, nil, start_mark)

    cache(1)
    unless blankz?
      scanner_error("while scanning a %TAG directive", start_mark,
        "did not find expected whitespace or line break")
    end

    {handle, prefix}
  end

  # yaml_parser_scan_anchor
  private def scan_anchor(kind : TokenKind) : Token
    string = @string
    string.clear
    length = 0

    start_mark = mark
    skip

    cache(1)
    while alpha?
      read(string)
      cache(1)
      length += 1
    end

    end_mark = mark

    if length == 0 || !(blankz? || check?('?') || check?(':') || check?(',') ||
       check?(']') || check?('}') || check?('%') || check?('@') || check?('`'))
      scanner_error(kind.anchor? ? "while scanning an anchor" : "while scanning an alias",
        start_mark, "did not find expected alphabetic or numeric character")
    end

    Token.new(kind, start_mark, end_mark, value: string.to_s)
  end

  # yaml_parser_scan_tag
  private def scan_tag : Token
    start_mark = mark

    cache(2)

    if check?('<', 1)
      handle = ""
      skip
      skip
      suffix = scan_tag_uri(true, false, nil, start_mark)
      unless check?('>')
        scanner_error("while scanning a tag", start_mark, "did not find the expected '>'")
      end
      skip
    else
      handle = scan_tag_handle(false, start_mark)
      if handle.bytesize > 1 && handle.byte_at(0) == '!'.ord && handle.byte_at(handle.bytesize - 1) == '!'.ord
        suffix = scan_tag_uri(false, false, nil, start_mark)
      else
        suffix = scan_tag_uri(false, false, handle, start_mark)
        handle = "!"
        if suffix.empty?
          handle, suffix = suffix, handle
        end
      end
    end

    cache(1)
    unless blankz?
      if @flow_level == 0 || !check?(',')
        scanner_error("while scanning a tag", start_mark,
          "did not find expected whitespace or line break")
      end
    end

    Token.new(TokenKind::TAG, start_mark, mark, value: suffix, handle: handle)
  end

  # yaml_parser_scan_tag_handle
  private def scan_tag_handle(directive : Bool, start_mark : Mark) : String
    string = @string
    string.clear

    cache(1)
    unless check?('!')
      scanner_error(directive ? "while scanning a tag directive" : "while scanning a tag",
        start_mark, "did not find expected '!'")
    end

    read(string)
    cache(1)
    while alpha?
      read(string)
      cache(1)
    end

    if check?('!')
      read(string)
    else
      if directive && !(string.size == 1 && string[0] == '!'.ord)
        scanner_error("while parsing a tag directive", start_mark, "did not find expected '!'")
      end
    end

    string.to_s
  end

  # yaml_parser_scan_tag_uri
  private def scan_tag_uri(uri_char : Bool, directive : Bool, head : String?, start_mark : Mark) : String
    length = head ? head.bytesize : 0
    string = @string
    string.clear

    if head && length > 1
      string.write(head.to_unsafe + 1, length - 1)
    end

    cache(1)
    while true
      c = byte
      break unless alpha? || c == ';'.ord || c == '/'.ord || c == '?'.ord ||
                   c == ':'.ord || c == '@'.ord || c == '&'.ord || c == '='.ord ||
                   c == '+'.ord || c == '$'.ord || c == '.'.ord || c == '%'.ord ||
                   c == '!'.ord || c == '~'.ord || c == '*'.ord || c == '\''.ord ||
                   c == '('.ord || c == ')'.ord ||
                   (uri_char && (c == ','.ord || c == '['.ord || c == ']'.ord))
      if c == '%'.ord
        scan_uri_escapes(directive, start_mark, string)
      else
        read(string)
      end
      length += 1
      cache(1)
    end

    if length == 0
      scanner_error(directive ? "while parsing a %TAG directive" : "while parsing a tag",
        start_mark, "did not find expected tag URI")
    end

    # libyaml returns the URI as a C string, so a `%00` escape ends it there
    # for every later consumer (the '!' special case, %TAG prefixes, joining
    # prefix and suffix).
    bytes = string.to_slice
    if index = bytes.index(0_u8)
      bytes = bytes[0, index]
    end
    String.new(bytes)
  end

  # yaml_parser_scan_uri_escapes
  private def scan_uri_escapes(directive : Bool, start_mark : Mark, string : ByteBuffer) : Nil
    width = 0
    while true
      cache(3)

      unless check?('%') && hex?(1) && hex?(2)
        scanner_error(directive ? "while parsing a %TAG directive" : "while parsing a tag",
          start_mark, "did not find URI escaped octet")
      end

      octet = ((as_hex(1) << 4) + as_hex(2)).to_u8

      if width == 0
        width = octet & 0x80 == 0x00 ? 1 : octet & 0xE0 == 0xC0 ? 2 : octet & 0xF0 == 0xE0 ? 3 : octet & 0xF8 == 0xF0 ? 4 : 0
        if width == 0
          scanner_error(directive ? "while parsing a %TAG directive" : "while parsing a tag",
            start_mark, "found an incorrect leading UTF-8 octet")
        end
      else
        if octet & 0xC0 != 0x80
          scanner_error(directive ? "while parsing a %TAG directive" : "while parsing a tag",
            start_mark, "found an incorrect trailing UTF-8 octet")
        end
      end

      string << octet
      skip
      skip
      skip

      width -= 1
      break if width == 0
    end
  end

  # yaml_parser_scan_block_scalar
  private def scan_block_scalar(literal : Bool) : Token
    string = @string
    leading_break = @leading_break
    trailing_breaks = @trailing_breaks
    string.clear
    leading_break.clear
    trailing_breaks.clear

    chomping = 0
    increment = 0
    indent = 0
    leading_blank = false
    trailing_blank = false

    start_mark = mark
    skip

    cache(1)
    if check?('+') || check?('-')
      chomping = check?('+') ? 1 : -1
      skip
      cache(1)
      if digit?
        if check?('0')
          scanner_error("while scanning a block scalar", start_mark,
            "found an indentation indicator equal to 0")
        end
        increment = as_digit
        skip
      end
    elsif digit?
      if check?('0')
        scanner_error("while scanning a block scalar", start_mark,
          "found an indentation indicator equal to 0")
      end
      increment = as_digit
      skip
      cache(1)
      if check?('+') || check?('-')
        chomping = check?('+') ? 1 : -1
        skip
      end
    end

    cache(1)
    while blank?
      skip
      cache(1)
    end

    if check?('#')
      until breakz?
        skip
        cache(1)
      end
    end

    unless breakz?
      scanner_error("while scanning a block scalar", start_mark,
        "did not find expected comment or line break")
    end

    if break?
      cache(2)
      skip_line
    end

    end_mark = mark

    if increment != 0
      indent = @indent >= 0 ? @indent + increment : increment
    end

    indent, end_mark = scan_block_scalar_breaks(indent, trailing_breaks, start_mark)

    cache(1)
    while @column == indent && !z?
      trailing_blank = blank?

      if !literal && leading_break.first_byte == '\n'.ord && !leading_blank && !trailing_blank
        if trailing_breaks.first_byte == 0
          string << ' '
        end
        leading_break.clear
      else
        string.join(leading_break)
        leading_break.clear
      end

      string.join(trailing_breaks)
      trailing_breaks.clear

      leading_blank = blank?

      until breakz?
        # Fast path: `READ` + `CACHE(1)` repeated over a run of the line.
        n = ascii_run(1) { |b| b >= 0x20 || b == '\t'.ord }
        if n > 0
          read_ascii(string, n)
          next
        end
        read(string)
        cache(1)
      end

      cache(2)
      read_line(leading_break)

      indent, end_mark = scan_block_scalar_breaks(indent, trailing_breaks, start_mark)
    end

    string.join(leading_break) if chomping != -1
    string.join(trailing_breaks) if chomping == 1

    Token.new(TokenKind::SCALAR, start_mark, end_mark, value: string.to_s,
      style: literal ? ScalarStyle::LITERAL : ScalarStyle::FOLDED)
  end

  # yaml_parser_scan_block_scalar_breaks; returns the (possibly determined)
  # indent and the end mark.
  private def scan_block_scalar_breaks(indent : Int32, breaks : ByteBuffer, start_mark : Mark) : {Int32, Mark}
    max_indent = 0
    end_mark = mark

    while true
      cache(1)
      # Fast path: `SKIP` + `CACHE(1)` repeated over indentation spaces.
      room = indent == 0 ? Int32::MAX : Math.max(indent - @column, 0_i64).to_i32
      n = ascii_run(1, room) { |b| b == ' '.ord }
      skip_ascii(n) if n > 0
      while (indent == 0 || @column < indent) && space?
        skip
        cache(1)
      end

      max_indent = @column.to_i32 if @column > max_indent

      if (indent == 0 || @column < indent) && tab?
        scanner_error("while scanning a block scalar", start_mark,
          "found a tab character where an indentation space is expected")
      end

      break unless break?

      cache(2)
      read_line(breaks)
      end_mark = mark
    end

    if indent == 0
      indent = max_indent
      indent = @indent + 1 if indent < @indent + 1
      indent = 1 if indent < 1
    end

    {indent, end_mark}
  end

  # yaml_parser_scan_flow_scalar
  private def scan_flow_scalar(single : Bool) : Token
    string = @string
    leading_break = @leading_break
    trailing_breaks = @trailing_breaks
    whitespaces = @whitespaces
    string.clear
    leading_break.clear
    trailing_breaks.clear
    whitespaces.clear

    quote = single ? '\''.ord.to_u8 : '"'.ord.to_u8

    start_mark = mark
    skip

    while true
      cache(4)

      if @column == 0 &&
         ((check?('-', 0) && check?('-', 1) && check?('-', 2)) ||
         (check?('.', 0) && check?('.', 1) && check?('.', 2))) &&
         blankz?(3)
        scanner_error("while scanning a quoted scalar", start_mark,
          "found unexpected document indicator")
      end

      if z?
        scanner_error("while scanning a quoted scalar", start_mark,
          "found unexpected end of stream")
      end

      cache(2)
      leading_blanks = false

      until blankz?
        # Fast path: a run of characters that are neither quotes nor escapes
        # is `READ` + `CACHE(2)` repeated.
        n = ascii_run(2) { |b| b > 0x20 && b != quote && (single || b != '\\'.ord) }
        if n > 0
          read_ascii(string, n)
          next
        end

        c = byte
        if single && c == '\''.ord && check?('\'', 1)
          string << '\''
          skip
          skip
        elsif c == quote
          break
        elsif !single && c == '\\'.ord && break?(1)
          cache(3)
          skip
          skip_line
          leading_blanks = true
          break
        elsif !single && c == '\\'.ord
          code_length = 0
          case byte(1)
          when '0'.ord           then string << 0_u8
          when 'a'.ord           then string << 0x07_u8
          when 'b'.ord           then string << 0x08_u8
          when 't'.ord, '\t'.ord then string << 0x09_u8
          when 'n'.ord           then string << 0x0A_u8
          when 'v'.ord           then string << 0x0B_u8
          when 'f'.ord           then string << 0x0C_u8
          when 'r'.ord           then string << 0x0D_u8
          when 'e'.ord           then string << 0x1B_u8
          when ' '.ord           then string << 0x20_u8
          when '"'.ord           then string << '"'
          when '/'.ord           then string << '/'
          when '\\'.ord          then string << '\\'
          when 'N'.ord           then string << 0xC2_u8 << 0x85_u8
          when '_'.ord           then string << 0xC2_u8 << 0xA0_u8
          when 'L'.ord           then string << 0xE2_u8 << 0x80_u8 << 0xA8_u8
          when 'P'.ord           then string << 0xE2_u8 << 0x80_u8 << 0xA9_u8
          when 'x'.ord           then code_length = 2
          when 'u'.ord           then code_length = 4
          when 'U'.ord           then code_length = 8
          else
            scanner_error("while parsing a quoted scalar", start_mark,
              "found unknown escape character")
          end

          skip
          skip

          if code_length != 0
            value = 0_u32
            cache(code_length)
            k = 0
            while k < code_length
              unless hex?(k)
                scanner_error("while parsing a quoted scalar", start_mark,
                  "did not find expected hexdecimal number")
              end
              value = (value << 4) &+ as_hex(k).to_u32
              k += 1
            end

            if (value >= 0xD800 && value <= 0xDFFF) || value > 0x10FFFF
              scanner_error("while parsing a quoted scalar", start_mark,
                "found invalid Unicode character escape code")
            end

            string.write_utf8(value)

            k = 0
            while k < code_length
              skip
              k += 1
            end
          end
        else
          read(string)
        end

        cache(2)
      end

      cache(1)
      break if byte == quote

      cache(1)
      while blank? || break?
        if blank?
          if leading_blanks
            skip
          else
            read(whitespaces)
          end
        else
          cache(2)
          if leading_blanks
            read_line(trailing_breaks)
          else
            whitespaces.clear
            read_line(leading_break)
            leading_blanks = true
          end
        end
        cache(1)
      end

      if leading_blanks
        if leading_break.first_byte == '\n'.ord
          if trailing_breaks.first_byte == 0
            string << ' '
          else
            string.join(trailing_breaks)
            trailing_breaks.clear
          end
          leading_break.clear
        else
          string.join(leading_break)
          string.join(trailing_breaks)
          leading_break.clear
          trailing_breaks.clear
        end
      else
        string.join(whitespaces)
        whitespaces.clear
      end
    end

    skip
    end_mark = mark

    Token.new(TokenKind::SCALAR, start_mark, end_mark, value: string.to_s,
      style: single ? ScalarStyle::SINGLE_QUOTED : ScalarStyle::DOUBLE_QUOTED)
  end

  # yaml_parser_scan_plain_scalar
  private def scan_plain_scalar : Token
    string = @string
    leading_break = @leading_break
    trailing_breaks = @trailing_breaks
    whitespaces = @whitespaces
    string.clear
    leading_break.clear
    trailing_breaks.clear
    whitespaces.clear

    leading_blanks = false
    indent = @indent + 1

    start_mark = end_mark = mark

    # Until a line break is folded into it, the value is the input from its
    # first to its last character, so with `#verbatim_input?` nothing is
    # copied to `string`: only where the value ends is tracked, and the
    # string is made from the input in one go.
    verbatim = verbatim_input?
    verbatim_start = verbatim_end = input_offset

    while true
      cache(4)

      if @column == 0 &&
         ((check?('-', 0) && check?('-', 1) && check?('-', 2)) ||
         (check?('.', 0) && check?('.', 1) && check?('.', 2))) &&
         blankz?(3)
        break
      end

      break if check?('#')

      until blankz?
        # Fast path: a run of characters that need none of the checks below
        # (no ':' or flow indicator, no pending whitespace to join) is
        # `READ` + `CACHE(2)` repeated.
        if !leading_blanks && whitespaces.empty?
          n = ascii_run(2) do |b|
            b > 0x20 && b != ':'.ord &&
              (@flow_level == 0 || !(b == ','.ord || b == '['.ord || b == ']'.ord || b == '{'.ord || b == '}'.ord))
          end
          if n > 0
            if verbatim
              skip_ascii(n)
              verbatim_end = input_offset
            else
              read_ascii(string, n)
            end
            end_mark = mark
            next
          end
        end

        c = byte
        if @flow_level != 0 && c == ':'.ord
          c1 = byte(1)
          if c1 == ','.ord || c1 == '?'.ord || c1 == '['.ord || c1 == ']'.ord ||
             c1 == '{'.ord || c1 == '}'.ord
            scanner_error("while scanning a plain scalar", start_mark, "found unexpected ':'")
          end
        end

        if (c == ':'.ord && blankz?(1)) ||
           (@flow_level != 0 &&
           (c == ','.ord || c == '['.ord || c == ']'.ord || c == '{'.ord || c == '}'.ord))
          break
        end

        if leading_blanks || !whitespaces.empty?
          if leading_blanks
            if verbatim
              write_input(string, verbatim_start, verbatim_end)
              verbatim = false
            end
            if leading_break.first_byte == '\n'.ord
              if trailing_breaks.first_byte == 0
                string << ' '
              else
                string.join(trailing_breaks)
                trailing_breaks.clear
              end
              leading_break.clear
            else
              string.join(leading_break)
              string.join(trailing_breaks)
              leading_break.clear
              trailing_breaks.clear
            end
            leading_blanks = false
          else
            # The whitespace is already part of the input between
            # `verbatim_start` and the next character.
            string.join(whitespaces) unless verbatim
            whitespaces.clear
          end
        end

        if verbatim
          skip
          verbatim_end = input_offset
        else
          read(string)
        end
        end_mark = mark
        cache(2)
      end

      break unless blank? || break?

      cache(1)
      while blank? || break?
        if blank?
          if leading_blanks && @column < indent && tab?
            scanner_error("while scanning a plain scalar", start_mark,
              "found a tab character that violates indentation")
          end
          if leading_blanks
            skip
          else
            read(whitespaces)
          end
        else
          cache(2)
          if leading_blanks
            read_line(trailing_breaks)
          else
            whitespaces.clear
            read_line(leading_break)
            leading_blanks = true
          end
        end
        cache(1)
      end

      break if @flow_level == 0 && @column < indent
    end

    value = verbatim ? input_to_s(verbatim_start, verbatim_end) : string.to_s
    token = Token.new(TokenKind::SCALAR, start_mark, end_mark, value: value,
      style: ScalarStyle::PLAIN)

    @simple_key_allowed = true if leading_blanks

    token
  end
end
