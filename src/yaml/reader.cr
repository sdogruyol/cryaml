# :nodoc:
#
# Input decoder: a port of libyaml's `reader.c` plus the buffer-access macros
# of `scanner.c` (`CACHE`, `SKIP`, `SKIP_LINE`, `READ`, `READ_LINE`).
#
# Input is read in raw chunks of `RAW_BUFFER_SIZE` bytes, validated and
# decoded (UTF-8, or UTF-16 when a BOM says so) into `@buffer`. Exactly like
# libyaml, a whole raw chunk is validated at a time, so encoding errors are
# reported at the same moment of the event stream as with libyaml.
#
# Only the bytes in `@buffer[@pos, @last)` are valid; `@unread` counts the
# characters there. Once the input is exhausted a NUL byte is appended, which
# the scanner uses as the end-of-stream marker (`IS_Z`). The buffer carries
# zero padding so look-ahead past the NUL never reads out of bounds.
class YAML::Reader
  RAW_BUFFER_SIZE = 16384
  BUFFER_SIZE     = RAW_BUFFER_SIZE * 3
  PADDING         = 16

  private enum Encoding
    NONE
    UTF8
    UTF16LE
    UTF16BE
  end

  # Raw input: a window into the input string, or a chunk buffer filled from
  # an IO. `@raw_pos...@raw_last` are the bytes read but not yet decoded.
  @raw : Pointer(UInt8)
  @raw_pos = 0
  @raw_last = 0
  @raw_buffer : Bytes?
  # Keeps the input string alive while `@raw` points into it.
  @input_string : String?
  @io : IO?
  @string_size = 0
  @eof = false
  @encoding = Encoding::NONE

  # Decoded UTF-8 buffer.
  @buffer : Bytes
  @pos = 0
  @last = 0
  @unread = 0
  # Whether `@buffer` is the input string itself. UTF-8 decodes to the same
  # bytes, so for a `String` in UTF-8 validating each chunk where it lies
  # stands in for copying it: `@pos` and `@last` are then offsets into the
  # string, and nothing ever moves. When the input ends, the last few unread
  # characters move to a small buffer of their own that can carry the final
  # NUL and the zero padding, and decoding continues as for any other input.
  @in_place = false
  # Whether every decoded byte is the input byte at `@buffer_offset` plus its
  # index in `@buffer` (a `String` in UTF-8, in place or not), so that the
  # scanner can take values straight from the input (`#input_offset`).
  @verbatim_input = false
  @buffer_offset = 0

  # Current position (libyaml `parser->mark`).
  @index = 0_i64
  @line = 0_i64
  @column = 0_i64

  def initialize(input : String | IO)
    case input
    in String
      # The buffer is chosen by `#determine_encoding`.
      @buffer = Bytes.empty
      @input_string = input
      @raw = input.to_unsafe
      @string_size = input.bytesize
    in IO
      @buffer = Bytes.new(BUFFER_SIZE + PADDING)
      raw_buffer = Bytes.new(RAW_BUFFER_SIZE + PADDING)
      @raw_buffer = raw_buffer
      @raw = raw_buffer.to_unsafe
      @io = input
    end
  end

  # The current position.
  @[AlwaysInline]
  def mark : Mark
    Mark.new(@index, @line, @column)
  end

  # Raises a `ParseException` the way `YAML::PullParser` reports libyaml
  # errors: 1-based problem position, plus an optional context.
  def syntax_error(problem : String, problem_mark : Mark, context : String? = nil, context_mark : Mark = Mark.new) : NoReturn
    context_info = context ? {context, context_mark.line + 1, context_mark.column + 1} : nil
    raise ParseException.new(problem, problem_mark.line + 1, problem_mark.column + 1, context_info)
  end

  # libyaml `CACHE(parser, length)`: makes sure at least *length* characters
  # (counting the final NUL) are decoded, unless the input ends earlier.
  @[AlwaysInline]
  def cache(length : Int32) : Nil
    update_buffer(length) if @unread < length
  end

  # Byte at *offset* from the current position.
  @[AlwaysInline]
  def byte(offset : Int32 = 0) : UInt8
    @buffer.to_unsafe[@pos &+ offset]
  end

  # Pointer to the current position.
  @[AlwaysInline]
  def pointer : Pointer(UInt8)
    @buffer.to_unsafe + @pos
  end

  # Whether the decoded characters are the input's own bytes, so that a value
  # made of consecutive characters can be taken from the input directly.
  @[AlwaysInline]
  def verbatim_input? : Bool
    @verbatim_input
  end

  # Offset in the input string of the current position (when
  # `#verbatim_input?`).
  @[AlwaysInline]
  def input_offset : Int32
    @buffer_offset &+ @pos
  end

  # The input between two `#input_offset`s, as a new string of *size*
  # characters (the bytes were validated as they were decoded). Knowing the
  # size spares `String#size` a pass over the bytes, and the code that
  # resolves scalars (`YAML::Schema::Core`) asks for it.
  @[AlwaysInline]
  def input_to_s(start : Int32, finish : Int32, size : Int32) : String
    String.new(@raw + start, finish &- start, size)
  end

  # Appends the input between two `#input_offset`s to *string*.
  @[AlwaysInline]
  def write_input(string : ByteBuffer, start : Int32, finish : Int32) : Nil
    string.write(@raw + start, finish &- start)
  end

  @[AlwaysInline]
  def check?(char : Char, offset : Int32 = 0) : Bool
    byte(offset) == char.ord
  end

  {% for name in %w(alpha? digit? hex? z? bom? space? tab? blank? break? crlf? breakz? blankz?) %}
    @[AlwaysInline]
    def {{name.id}}(offset : Int32 = 0) : Bool
      Chars.{{name.id}}(@buffer.to_unsafe + @pos, offset)
    end
  {% end %}

  @[AlwaysInline]
  def as_digit(offset : Int32 = 0) : Int32
    Chars.as_digit(@buffer.to_unsafe + @pos, offset)
  end

  @[AlwaysInline]
  def as_hex(offset : Int32 = 0) : Int32
    Chars.as_hex(@buffer.to_unsafe + @pos, offset)
  end

  @[AlwaysInline]
  def width(offset : Int32 = 0) : Int32
    Chars.width(@buffer.to_unsafe + @pos, offset)
  end

  # The primitives below advance the position with wrapping arithmetic
  # (`&+`, `&-`), which skips the overflow checks of `+` and `-`: offsets
  # stay within the buffer (an `Int32` size), `@unread` within its
  # character count, and the `Int64` index, line and column count the
  # characters of the input.

  # libyaml `SKIP`: advances one character.
  @[AlwaysInline]
  def skip : Nil
    @index &+= 1
    @column &+= 1
    @unread &-= 1
    @pos &+= width
  end

  # libyaml `SKIP_LINE`: advances over a line break (CR LF counts as one).
  @[AlwaysInline]
  def skip_line : Nil
    if crlf?
      @index &+= 2
      @column = 0_i64
      @line &+= 1
      @unread &-= 2
      @pos &+= 2
    elsif break?
      @index &+= 1
      @column = 0_i64
      @line &+= 1
      @unread &-= 1
      @pos &+= width
    end
  end

  # libyaml `READ`: copies one character into *string* and advances.
  @[AlwaysInline]
  def read(string : ByteBuffer) : Nil
    w = width
    if w == 1
      string << byte
    else
      string.write(pointer, w)
    end
    @pos &+= w
    @index &+= 1
    @column &+= 1
    @unread &-= 1
  end

  # Number of characters at the current position (at most *max*) that are
  # ASCII, satisfy the block, and can be consumed while *keep* characters
  # stay decoded.
  #
  # Scanner loops of the form `while <cond>; SKIP or READ; CACHE(keep); end`
  # use it to consume such a run at once: within the run every `CACHE(keep)`
  # would find the buffer full enough and do nothing, so the buffer is
  # refilled at exactly the same characters as one at a time.
  @[AlwaysInline]
  def ascii_run(keep : Int32, max : Int32 = Int32::MAX, &) : Int32
    p = pointer
    limit = Math.min(@unread &- keep, max)
    n = 0
    while n < limit
      b = p[n]
      break unless b < 0x80 && yield b
      n &+= 1
    end
    n
  end

  # `#ascii_run` for a run of spaces, eight bytes at a time: indentation is
  # a large part of most YAML.
  @[AlwaysInline]
  def space_run(keep : Int32, max : Int32 = Int32::MAX) : Int32
    p = pointer
    limit = Math.min(@unread &- keep, max)
    n = 0
    # Every character takes at least one byte, so while at least eight more
    # characters are allowed the next eight bytes are decoded.
    while n &+ 8 <= limit
      # Zero exactly in the bytes that are spaces.
      other = Chars.load_word(p + n) ^ (' '.ord.to_u64 &* Chars::SWAR_ONES)
      return n &+ Chars.zero_bytes_before(other) if other != 0
      n &+= 8
    end
    while n < limit && p[n] == ' '.ord
      n &+= 1
    end
    n
  end

  # *count* times `SKIP` over ASCII characters (see `#ascii_run`).
  @[AlwaysInline]
  def skip_ascii(count : Int32) : Nil
    @index &+= count
    @column &+= count
    @unread &-= count
    @pos &+= count
  end

  # *count* times `READ` of ASCII characters (see `#ascii_run`).
  @[AlwaysInline]
  def read_ascii(string : ByteBuffer, count : Int32) : Nil
    string.write(pointer, count)
    skip_ascii(count)
  end

  # libyaml `READ_LINE`: copies a line break into *string* (normalizing CR,
  # LF, CR LF and NEL to LF; LS and PS are kept) and advances.
  @[AlwaysInline]
  def read_line(string : ByteBuffer) : Nil
    if check?('\r') && check?('\n', 1)
      string << '\n'
      @pos &+= 2
      @index &+= 2
      @column = 0_i64
      @line &+= 1
      @unread &-= 2
    elsif check?('\r') || check?('\n')
      string << '\n'
      @pos &+= 1
      @index &+= 1
      @column = 0_i64
      @line &+= 1
      @unread &-= 1
    elsif byte == 0xC2 && byte(1) == 0x85
      string << '\n'
      @pos &+= 2
      @index &+= 1
      @column = 0_i64
      @line &+= 1
      @unread &-= 1
    elsif byte == 0xE2 && byte(1) == 0x80 && (byte(2) == 0xA8 || byte(2) == 0xA9)
      string.write(pointer, 3)
      @pos &+= 3
      @index &+= 1
      @column = 0_i64
      @line &+= 1
      @unread &-= 1
    end
  end

  # libyaml `yaml_parser_update_buffer`.
  def update_buffer(length : Int32) : Nil
    return if @eof && @raw_pos == @raw_last
    return if @unread >= length

    determine_encoding if @encoding.none?
    return update_buffer_in_place(length) if @in_place

    # Move the unread characters to the beginning of the buffer.
    if 0 < @pos < @last
      size = @last - @pos
      @buffer.to_unsafe.move_from(@buffer.to_unsafe + @pos, size)
      @pos = 0
      @last = size
    elsif @pos == @last
      @pos = 0
      @last = 0
    end

    first = true
    while @unread < length
      update_raw_buffer if !first || @raw_pos == @raw_last
      first = false

      decode_raw_buffer

      if @eof
        ensure_buffer_capacity(1)
        @buffer.to_unsafe[@last] = 0_u8
        @last += 1
        @unread += 1
        # Keep the padding after the NUL zeroed even if stale bytes remain
        # from a previous, longer fill.
        (@buffer.to_unsafe + @last).clear(PADDING - 1)
        return
      end
    end
  end

  # `#update_buffer` while `@buffer` is the input string: the same chunks are
  # validated at the same moments, without moving or copying anything.
  private def update_buffer_in_place(length : Int32) : Nil
    first = true
    while @unread < length
      update_raw_buffer if !first || @raw_pos == @raw_last
      first = false

      decode_utf8(copy: false)

      if @eof
        # The string's memory ends right after its last character, so the
        # unread characters (fewer than `length`) move to a buffer that has
        # room for the NUL and the padding after them (`Bytes.new` zeroes).
        size = @last - @pos
        buffer = Bytes.new(size + 1 + PADDING)
        buffer.to_unsafe.copy_from(@buffer.to_unsafe + @pos, size)
        @buffer = buffer
        @buffer_offset = @pos
        @pos = 0
        @last = size + 1
        @unread += 1
        @in_place = false
        return
      end
    end
  end

  # Reader errors are positioned at line 1, column 1, as libyaml's binding
  # reports them. The scanner keeps raising the stored error afterwards.
  private def reader_error(problem : String) : NoReturn
    raise ParseException.new(problem, 1, 1)
  end

  private def determine_encoding : Nil
    while !@eof && @raw_last - @raw_pos < 3
      update_raw_buffer
    end

    raw = @raw + @raw_pos
    available = @raw_last - @raw_pos
    if available >= 2 && raw[0] == 0xFF && raw[1] == 0xFE
      @encoding = Encoding::UTF16LE
      @raw_pos += 2
    elsif available >= 2 && raw[0] == 0xFE && raw[1] == 0xFF
      @encoding = Encoding::UTF16BE
      @raw_pos += 2
    elsif available >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF
      @encoding = Encoding::UTF8
      @raw_pos += 3
    else
      @encoding = Encoding::UTF8
    end

    if @input_string
      if @encoding.utf8?
        @in_place = true
        @verbatim_input = true
        @buffer = Bytes.new(@raw, @string_size, read_only: true)
        @pos = @last = @raw_pos
      else
        # A small document never needs the full-size buffer: one raw chunk
        # is at most the whole string, and decoding grows by at most 3/2.
        size = @string_size < BUFFER_SIZE // 2 ? @string_size * 2 + 64 : BUFFER_SIZE
        @buffer = Bytes.new(size + PADDING)
      end
    end
  end

  # libyaml `yaml_parser_update_raw_buffer`.
  private def update_raw_buffer : Nil
    # The raw buffer is full.
    return if @raw_last - @raw_pos == RAW_BUFFER_SIZE
    return if @eof

    if io = @io
      # Move the remaining bytes to the beginning of the chunk buffer.
      remaining = @raw_last - @raw_pos
      if @raw_pos > 0 && remaining > 0
        @raw.move_from(@raw + @raw_pos, remaining)
      end
      @raw_pos = 0
      @raw_last = remaining
      size_read = io.read(Slice.new(@raw + @raw_last, RAW_BUFFER_SIZE - @raw_last))
    else
      # Widen the window over the input string by up to a chunk.
      size_read = Math.min(RAW_BUFFER_SIZE - (@raw_last - @raw_pos), @string_size - @raw_last)
    end

    @raw_last += size_read
    @eof = true if size_read == 0
  end

  # Decodes all complete characters of the raw buffer into `@buffer`.
  private def decode_raw_buffer : Nil
    raw_unread = @raw_last - @raw_pos
    return if raw_unread == 0

    # UTF-8 output is never longer than 3/2 of UTF-16 input, and equal in
    # size for UTF-8 input.
    ensure_buffer_capacity(raw_unread * 2)

    if @encoding.utf8?
      decode_utf8
    else
      decode_utf16
    end
  end

  # Validates the complete characters of the raw buffer and, if *copy*,
  # copies them to `@buffer` (without, `@buffer` is the raw input itself).
  private def decode_utf8(copy : Bool = true) : Nil
    raw = @raw
    out = @buffer.to_unsafe
    pos = @raw_pos
    last = @raw_last
    out_pos = @last
    unread = @unread

    while pos < last
      # Fast path: copy the printable ASCII characters (0x20..0x7E) among
      # the next eight bytes, up to the first other byte, which is then
      # decoded below.
      if last - pos >= 8
        mask = non_printable_ascii_mask(Chars.load_word(raw + pos))
        good = mask == 0 ? 8 : Chars.zero_bytes_before(mask)
        (out + out_pos).copy_from(raw + pos, 8) if copy
        out_pos &+= good
        pos &+= good
        unread &+= good
        next if mask == 0
      end

      octet = raw[pos]

      # Fast path for printable ASCII, tab, LF and CR.
      if octet < 0x80
        unless (octet >= 0x20 && octet <= 0x7E) || octet == 0x0A || octet == 0x0D || octet == 0x09
          sync_decode_state(pos, out_pos, unread)
          reader_error("control characters are not allowed")
        end
        out[out_pos] = octet if copy
        out_pos += 1
        pos += 1
        unread += 1
        next
      end

      width = octet & 0xE0 == 0xC0 ? 2 : octet & 0xF0 == 0xE0 ? 3 : octet & 0xF8 == 0xF0 ? 4 : 0
      if width == 0
        sync_decode_state(pos, out_pos, unread)
        reader_error("invalid leading UTF-8 octet")
      end

      if width > last - pos
        sync_decode_state(pos, out_pos, unread)
        reader_error("incomplete UTF-8 octet sequence") if @eof
        # Incomplete character: wait for more raw input.
        return
      end

      value = (width == 2 ? octet & 0x1F : width == 3 ? octet & 0x0F : octet & 0x07).to_u32
      k = 1
      while k < width
        trailing = raw[pos + k]
        if trailing & 0xC0 != 0x80
          sync_decode_state(pos, out_pos, unread)
          reader_error("invalid trailing UTF-8 octet")
        end
        value = (value << 6) + (trailing & 0x3F)
        k += 1
      end

      unless (width == 2 && value >= 0x80) || (width == 3 && value >= 0x800) || (width == 4 && value >= 0x10000)
        sync_decode_state(pos, out_pos, unread)
        reader_error("invalid length of a UTF-8 sequence")
      end

      if (value >= 0xD800 && value <= 0xDFFF) || value > 0x10FFFF
        sync_decode_state(pos, out_pos, unread)
        reader_error("invalid Unicode character")
      end

      unless allowed?(value)
        sync_decode_state(pos, out_pos, unread)
        reader_error("control characters are not allowed")
      end

      (out + out_pos).copy_from(raw + pos, width) if copy
      out_pos += width
      pos += width
      unread += 1
    end

    sync_decode_state(pos, out_pos, unread)
  end

  # The bytes of *word* outside 0x20..0x7E (see the SWAR notes in `Chars`):
  # those with the high bit set, those that reach 0x80 when 1 is added (0x7F),
  # and those below 0x20.
  @[AlwaysInline]
  private def non_printable_ascii_mask(word : UInt64) : UInt64
    Chars.non_ascii_mask(word | (word &+ Chars::SWAR_ONES)) | Chars.below_mask(word, 0x20)
  end

  @[AlwaysInline]
  private def sync_decode_state(pos, out_pos, unread) : Nil
    @raw_pos = pos
    @last = out_pos
    @unread = unread
  end

  private def decode_utf16 : Nil
    low, high = @encoding.utf16_le? ? {0, 1} : {1, 0}

    while @raw_pos < @raw_last
      raw = @raw + @raw_pos
      raw_unread = @raw_last - @raw_pos

      if raw_unread < 2
        reader_error("incomplete UTF-16 character") if @eof
        return
      end

      value = raw[low].to_u32 + (raw[high].to_u32 << 8)

      if value & 0xFC00 == 0xDC00
        reader_error("unexpected low surrogate area")
      end

      if value & 0xFC00 == 0xD800
        width = 4
        if raw_unread < 4
          reader_error("incomplete UTF-16 surrogate pair") if @eof
          return
        end
        value2 = raw[low + 2].to_u32 + (raw[high + 2].to_u32 << 8)
        if value2 & 0xFC00 != 0xDC00
          reader_error("expected low surrogate area")
        end
        value = 0x10000_u32 + ((value & 0x3FF) << 10) + (value2 & 0x3FF)
      else
        width = 2
      end

      reader_error("control characters are not allowed") unless allowed?(value)

      @raw_pos += width
      write_utf8(value)
      @unread += 1
    end
  end

  @[AlwaysInline]
  private def allowed?(value : UInt32) : Bool
    value == 0x09 || value == 0x0A || value == 0x0D ||
      (value >= 0x20 && value <= 0x7E) ||
      value == 0x85 || (value >= 0xA0 && value <= 0xD7FF) ||
      (value >= 0xE000 && value <= 0xFFFD) ||
      (value >= 0x10000 && value <= 0x10FFFF)
  end

  private def write_utf8(value : UInt32) : Nil
    out = @buffer.to_unsafe
    if value <= 0x7F
      out[@last] = value.to_u8
      @last += 1
    elsif value <= 0x7FF
      out[@last] = (0xC0 + (value >> 6)).to_u8
      out[@last + 1] = (0x80 + (value & 0x3F)).to_u8
      @last += 2
    elsif value <= 0xFFFF
      out[@last] = (0xE0 + (value >> 12)).to_u8
      out[@last + 1] = (0x80 + ((value >> 6) & 0x3F)).to_u8
      out[@last + 2] = (0x80 + (value & 0x3F)).to_u8
      @last += 3
    else
      out[@last] = (0xF0 + (value >> 18)).to_u8
      out[@last + 1] = (0x80 + ((value >> 12) & 0x3F)).to_u8
      out[@last + 2] = (0x80 + ((value >> 6) & 0x3F)).to_u8
      out[@last + 3] = (0x80 + (value & 0x3F)).to_u8
      @last += 4
    end
  end

  # The decoded buffer only ever holds a few unread characters plus one raw
  # chunk, so this never grows in practice; it guards the invariant.
  private def ensure_buffer_capacity(extra : Int32) : Nil
    needed = @last + extra + PADDING
    return if needed <= @buffer.size
    buffer = Bytes.new(Math.max(needed, @buffer.size * 2))
    buffer.to_unsafe.copy_from(@buffer.to_unsafe, @last)
    @buffer = buffer
  end
end
