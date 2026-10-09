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
  @offset = 0_i64

  # Decoded UTF-8 buffer.
  @buffer : Bytes
  @pos = 0
  @last = 0
  @unread = 0

  # Current position (libyaml `parser->mark`).
  @index = 0_i64
  @line = 0_i64
  @column = 0_i64

  @reader_error : ParseException? = nil

  def initialize(input : String | IO)
    case input
    in String
      # A small document never needs the full-size buffer: one raw chunk is
      # at most the whole string, and decoding grows by at most 3/2.
      @buffer = Bytes.new(Math.min(BUFFER_SIZE, input.bytesize * 2 + 64) + PADDING)
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
    @buffer.to_unsafe[@pos + offset]
  end

  # Pointer to the current position.
  @[AlwaysInline]
  def pointer : Pointer(UInt8)
    @buffer.to_unsafe + @pos
  end

  @[AlwaysInline]
  def check?(char : Char, offset : Int32 = 0) : Bool
    byte(offset) == char.ord
  end

  {% for name in %w(alpha? digit? hex? ascii? printable? z? bom? space? tab? blank? break? crlf? breakz? spacez? blankz?) %}
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

  # libyaml `SKIP`: advances one character.
  @[AlwaysInline]
  def skip : Nil
    @index += 1
    @column += 1
    @unread -= 1
    @pos += width
  end

  # libyaml `SKIP_LINE`: advances over a line break (CR LF counts as one).
  @[AlwaysInline]
  def skip_line : Nil
    if crlf?
      @index += 2
      @column = 0_i64
      @line += 1
      @unread -= 2
      @pos += 2
    elsif break?
      @index += 1
      @column = 0_i64
      @line += 1
      @unread -= 1
      @pos += width
    end
  end

  # libyaml `READ`: copies one character into *string* and advances.
  @[AlwaysInline]
  def read(string : ByteBuffer) : Nil
    w = width
    string.write(pointer, w)
    @pos += w
    @index += 1
    @column += 1
    @unread -= 1
  end

  # libyaml `READ_LINE`: copies a line break into *string* (normalizing CR,
  # LF, CR LF and NEL to LF; LS and PS are kept) and advances.
  @[AlwaysInline]
  def read_line(string : ByteBuffer) : Nil
    if check?('\r') && check?('\n', 1)
      string << '\n'
      @pos += 2
      @index += 2
      @column = 0_i64
      @line += 1
      @unread -= 2
    elsif check?('\r') || check?('\n')
      string << '\n'
      @pos += 1
      @index += 1
      @column = 0_i64
      @line += 1
      @unread -= 1
    elsif byte == 0xC2 && byte(1) == 0x85
      string << '\n'
      @pos += 2
      @index += 1
      @column = 0_i64
      @line += 1
      @unread -= 1
    elsif byte == 0xE2 && byte(1) == 0x80 && (byte(2) == 0xA8 || byte(2) == 0xA9)
      string.write(pointer, 3)
      @pos += 3
      @index += 1
      @column = 0_i64
      @line += 1
      @unread -= 1
    end
  end

  # libyaml `yaml_parser_update_buffer`.
  def update_buffer(length : Int32) : Nil
    if error = @reader_error
      raise error
    end

    return if @eof && @raw_pos == @raw_last
    return if @unread >= length

    determine_encoding if @encoding.none?

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

  private def reader_error(problem : String) : NoReturn
    error = ParseException.new(problem, 1, 1)
    @reader_error = error
    raise error
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
      @offset += 2
    elsif available >= 2 && raw[0] == 0xFE && raw[1] == 0xFF
      @encoding = Encoding::UTF16BE
      @raw_pos += 2
      @offset += 2
    elsif available >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF
      @encoding = Encoding::UTF8
      @raw_pos += 3
      @offset += 3
    else
      @encoding = Encoding::UTF8
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

  private def decode_utf8 : Nil
    raw = @raw
    out = @buffer.to_unsafe
    pos = @raw_pos
    last = @raw_last
    out_pos = @last
    unread = @unread
    offset = @offset

    while pos < last
      octet = raw[pos]

      # Fast path for printable ASCII, tab, LF and CR.
      if octet < 0x80
        unless (octet >= 0x20 && octet <= 0x7E) || octet == 0x0A || octet == 0x0D || octet == 0x09
          sync_decode_state(pos, out_pos, unread, offset)
          reader_error("control characters are not allowed")
        end
        out[out_pos] = octet
        out_pos += 1
        pos += 1
        offset += 1
        unread += 1
        next
      end

      width = octet & 0xE0 == 0xC0 ? 2 : octet & 0xF0 == 0xE0 ? 3 : octet & 0xF8 == 0xF0 ? 4 : 0
      if width == 0
        sync_decode_state(pos, out_pos, unread, offset)
        reader_error("invalid leading UTF-8 octet")
      end

      if width > last - pos
        sync_decode_state(pos, out_pos, unread, offset)
        reader_error("incomplete UTF-8 octet sequence") if @eof
        # Incomplete character: wait for more raw input.
        return
      end

      value = (width == 2 ? octet & 0x1F : width == 3 ? octet & 0x0F : octet & 0x07).to_u32
      k = 1
      while k < width
        trailing = raw[pos + k]
        if trailing & 0xC0 != 0x80
          sync_decode_state(pos, out_pos, unread, offset)
          reader_error("invalid trailing UTF-8 octet")
        end
        value = (value << 6) + (trailing & 0x3F)
        k += 1
      end

      unless (width == 2 && value >= 0x80) || (width == 3 && value >= 0x800) || (width == 4 && value >= 0x10000)
        sync_decode_state(pos, out_pos, unread, offset)
        reader_error("invalid length of a UTF-8 sequence")
      end

      if (value >= 0xD800 && value <= 0xDFFF) || value > 0x10FFFF
        sync_decode_state(pos, out_pos, unread, offset)
        reader_error("invalid Unicode character")
      end

      unless allowed?(value)
        sync_decode_state(pos, out_pos, unread, offset)
        reader_error("control characters are not allowed")
      end

      (out + out_pos).copy_from(raw + pos, width)
      out_pos += width
      pos += width
      offset += width
      unread += 1
    end

    sync_decode_state(pos, out_pos, unread, offset)
  end

  @[AlwaysInline]
  private def sync_decode_state(pos, out_pos, unread, offset) : Nil
    @raw_pos = pos
    @last = out_pos
    @unread = unread
    @offset = offset
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
      @offset += width
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
