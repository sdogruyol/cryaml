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
  # Capacities are one less than a power of two: bdwgc adds a byte to every
  # allocation (so that a pointer just past its end still points into it),
  # so these are what fill its size classes (15 bytes take 16, 16 would
  # take 32).
  INITIAL_CAPACITY = 15

  getter size : Int32 = 0
  # A pointer and a capacity rather than `Bytes` (whose read-only flag would
  # take 8 more bytes): 24 bytes per buffer instead of 32.
  @bytes : Pointer(UInt8)
  @capacity : Int32

  def initialize
    @capacity = INITIAL_CAPACITY
    # Zeroed, like everything `#grow` allocates.
    @bytes = Pointer(UInt8).malloc(INITIAL_CAPACITY)
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
    @bytes[0]
  end

  @[AlwaysInline]
  def [](index : Int32) : UInt8
    @bytes[index]
  end

  def to_unsafe : Pointer(UInt8)
    @bytes
  end

  @[AlwaysInline]
  def <<(byte : UInt8) : self
    ensure_capacity(1)
    @bytes[@size] = byte
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
    (@bytes + @size).copy_from(pointer, count)
    @size += count
    @dirty = @size if @size > @dirty
    self
  end

  # Appends a single code point encoded as UTF-8 (one capacity check for
  # its bytes, instead of one per byte).
  def write_utf8(value : UInt32) : self
    count = value <= 0x7F ? 1 : value <= 0x7FF ? 2 : value <= 0xFFFF ? 3 : 4
    ensure_capacity(count)
    p = @bytes + @size
    case count
    when 1
      p[0] = value.to_u8
    when 2
      p[0] = (0xC0 | (value >> 6)).to_u8
      p[1] = (0x80 | (value & 0x3F)).to_u8
    when 3
      p[0] = (0xE0 | (value >> 12)).to_u8
      p[1] = (0x80 | ((value >> 6) & 0x3F)).to_u8
      p[2] = (0x80 | (value & 0x3F)).to_u8
    else
      p[0] = (0xF0 | (value >> 18)).to_u8
      p[1] = (0x80 | ((value >> 12) & 0x3F)).to_u8
      p[2] = (0x80 | ((value >> 6) & 0x3F)).to_u8
      p[3] = (0x80 | (value & 0x3F)).to_u8
    end
    @size += count
    @dirty = @size if @size > @dirty
    self
  end

  # libyaml `CLEAR`: rewinds and zeroes the storage.
  def clear : Nil
    if @dirty > INITIAL_CAPACITY
      @bytes.clear(@dirty)
    elsif @dirty > 0
      # The storage is never smaller than INITIAL_CAPACITY; a constant size
      # clears without calling `memset`.
      @bytes.clear(INITIAL_CAPACITY)
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
    String.new(@bytes, @size)
  end

  def to_slice : Bytes
    Bytes.new(@bytes, @size)
  end

  @[AlwaysInline]
  private def ensure_capacity(extra : Int32) : Nil
    needed = @size.to_i64 + extra
    grow(needed) if needed > @capacity
  end

  # Doubles the storage (plus one, see INITIAL_CAPACITY) until *needed* bytes
  # fit, up to the largest `Bytes` (`Int32::MAX`, itself 2^31 - 1). Beyond
  # that a scalar couldn't become a `String` anyway.
  private def grow(needed : Int64) : Nil
    raise ArgumentError.new("YAML scalar too large") if needed > Int32::MAX
    capacity = @capacity.to_i64 * 2 + 1
    while capacity < needed
      capacity = capacity * 2 + 1
    end
    @capacity = capacity.to_i32
    bytes = Pointer(UInt8).malloc(@capacity)
    bytes.copy_from(@bytes, @dirty)
    @bytes = bytes
  end
end
