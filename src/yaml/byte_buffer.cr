# :nodoc:
#
# Growable byte string used while scanning and emitting, the counterpart of
# libyaml's `yaml_string_t`.
#
# libyaml tests emptiness of some scratch strings with `string.start[0] == '\0'`
# and its `JOIN` macro rewinds the source string without zeroing it, so a
# joined string can still report a stale first byte. `#first_byte`, `#clear`
# and `#join` reproduce exactly that behavior.
class YAML::ByteBuffer
  getter size : Int32 = 0

  def initialize(capacity : Int32 = 16)
    @bytes = Bytes.new(Math.max(capacity, 16))
    # Highest index written since the last `clear`; everything at or after it
    # is known to be zero.
    @dirty = 0
  end

  def empty? : Bool
    @size == 0
  end

  # The byte at the start of the storage, ignoring `size` (libyaml's
  # `string.start[0]`).
  @[AlwaysInline]
  def first_byte : UInt8
    @bytes.to_unsafe[0]
  end

  @[AlwaysInline]
  def [](index : Int32) : UInt8
    @bytes.to_unsafe[index]
  end

  def to_unsafe : Pointer(UInt8)
    @bytes.to_unsafe
  end

  @[AlwaysInline]
  def <<(byte : UInt8) : self
    ensure_capacity(1)
    @bytes.to_unsafe[@size] = byte
    @size += 1
    @dirty = @size if @size > @dirty
    self
  end

  @[AlwaysInline]
  def <<(char : Char) : self
    self << char.ord.to_u8
  end

  def write(pointer : Pointer(UInt8), count : Int32) : self
    ensure_capacity(count)
    (@bytes.to_unsafe + @size).copy_from(pointer, count)
    @size += count
    @dirty = @size if @size > @dirty
    self
  end

  # Appends a single code point encoded as UTF-8.
  def write_utf8(value : UInt32) : self
    if value <= 0x7F
      self << value.to_u8
    elsif value <= 0x7FF
      self << (0xC0 | (value >> 6)).to_u8
      self << (0x80 | (value & 0x3F)).to_u8
    elsif value <= 0xFFFF
      self << (0xE0 | (value >> 12)).to_u8
      self << (0x80 | ((value >> 6) & 0x3F)).to_u8
      self << (0x80 | (value & 0x3F)).to_u8
    else
      self << (0xF0 | (value >> 18)).to_u8
      self << (0x80 | ((value >> 12) & 0x3F)).to_u8
      self << (0x80 | ((value >> 6) & 0x3F)).to_u8
      self << (0x80 | (value & 0x3F)).to_u8
    end
  end

  # libyaml `CLEAR`: rewinds and zeroes the storage.
  def clear : Nil
    if @dirty > 16
      @bytes.to_unsafe.clear(@dirty)
    elsif @dirty > 0
      # The storage is never smaller than 16 bytes; a constant size clears
      # without calling `memset`.
      @bytes.to_unsafe.clear(16)
    end
    @size = 0
    @dirty = 0
  end

  # libyaml `JOIN(self, other)`: appends *other* to `self`, then rewinds
  # *other* without zeroing it.
  def join(other : ByteBuffer) : Nil
    write(other.to_unsafe, other.size)
    other.rewind
  end

  protected def rewind : Nil
    @size = 0
  end

  def to_s : String
    String.new(@bytes.to_unsafe, @size)
  end

  def to_slice : Bytes
    @bytes[0, @size]
  end

  @[AlwaysInline]
  private def ensure_capacity(extra : Int32) : Nil
    needed = @size.to_i64 + extra
    grow(needed) if needed > @bytes.size
  end

  # Doubles the storage until *needed* bytes fit, up to the largest `Bytes`
  # (`Int32::MAX`). Beyond that a scalar couldn't become a `String` anyway.
  private def grow(needed : Int64) : Nil
    raise ArgumentError.new("YAML scalar too large") if needed > Int32::MAX
    capacity = Math.max(@bytes.size.to_i64 * 2, 16_i64)
    while capacity < needed
      capacity *= 2
    end
    bytes = Bytes.new(Math.min(capacity, Int32::MAX.to_i64).to_i32)
    bytes.to_unsafe.copy_from(@bytes.to_unsafe, @dirty)
    @bytes = bytes
  end
end
