# :nodoc:
#
# Character classification on UTF-8 byte buffers, mirroring the `IS_*_AT`
# macros of libyaml's `yaml_private.h`. Offsets are byte offsets from *p*.
# `o &+ 1` and `o &+ 2` (no overflow check, which every inlined copy would
# carry) only follow a lead byte at *o*: the bytes after it, or the NUL
# after the buffer, are at offsets within the buffer's `Int32` size.
module YAML::Chars
  extend self

  @[AlwaysInline]
  def alpha?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    c = p[o]
    (c >= '0'.ord && c <= '9'.ord) || (c >= 'A'.ord && c <= 'Z'.ord) ||
      (c >= 'a'.ord && c <= 'z'.ord) || c == '_'.ord || c == '-'.ord
  end

  @[AlwaysInline]
  def digit?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    c = p[o]
    c >= '0'.ord && c <= '9'.ord
  end

  @[AlwaysInline]
  def as_digit(p : Pointer(UInt8), o : Int32 = 0) : Int32
    p[o].to_i32 - '0'.ord
  end

  @[AlwaysInline]
  def hex?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    c = p[o]
    (c >= '0'.ord && c <= '9'.ord) || (c >= 'A'.ord && c <= 'F'.ord) ||
      (c >= 'a'.ord && c <= 'f'.ord)
  end

  @[AlwaysInline]
  def as_hex(p : Pointer(UInt8), o : Int32 = 0) : Int32
    c = p[o].to_i32
    if c >= 'A'.ord && c <= 'F'.ord
      c - 'A'.ord + 10
    elsif c >= 'a'.ord && c <= 'f'.ord
      c - 'a'.ord + 10
    else
      c - '0'.ord
    end
  end

  @[AlwaysInline]
  def ascii?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    p[o] <= 0x7F
  end

  @[AlwaysInline]
  def printable?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    c = p[o]
    c == 0x0A ||
      (c >= 0x20 && c <= 0x7E) ||
      (c == 0xC2 && p[o &+ 1] >= 0xA0) ||
      (c > 0xC2 && c < 0xED) ||
      (c == 0xED && p[o &+ 1] < 0xA0) ||
      c == 0xEE ||
      (c == 0xEF &&
        !(p[o &+ 1] == 0xBB && p[o &+ 2] == 0xBF) &&
        !(p[o &+ 1] == 0xBF && (p[o &+ 2] == 0xBE || p[o &+ 2] == 0xBF)))
  end

  @[AlwaysInline]
  def z?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    p[o] == 0
  end

  @[AlwaysInline]
  def bom?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    p[o] == 0xEF && p[o &+ 1] == 0xBB && p[o &+ 2] == 0xBF
  end

  @[AlwaysInline]
  def space?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    p[o] == ' '.ord
  end

  @[AlwaysInline]
  def tab?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    p[o] == '\t'.ord
  end

  @[AlwaysInline]
  def blank?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    c = p[o]
    c == ' '.ord || c == '\t'.ord
  end

  @[AlwaysInline]
  def break?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    c = p[o]
    c == '\r'.ord || c == '\n'.ord ||
      (c == 0xC2 && p[o &+ 1] == 0x85) ||
      (c == 0xE2 && p[o &+ 1] == 0x80 && (p[o &+ 2] == 0xA8 || p[o &+ 2] == 0xA9))
  end

  @[AlwaysInline]
  def crlf?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    p[o] == '\r'.ord && p[o &+ 1] == '\n'.ord
  end

  @[AlwaysInline]
  def breakz?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    break?(p, o) || z?(p, o)
  end

  @[AlwaysInline]
  def blankz?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    blank?(p, o) || breakz?(p, o)
  end

  # Byte length of the UTF-8 sequence starting at *o* (0 if invalid lead).
  @[AlwaysInline]
  def width(p : Pointer(UInt8), o : Int32 = 0) : Int32
    c = p[o]
    if c & 0x80 == 0x00
      1
    elsif c & 0xE0 == 0xC0
      2
    elsif c & 0xF0 == 0xE0
      3
    elsif c & 0xF8 == 0xF0
      4
    else
      0
    end
  end

  # SWAR ("SIMD within a register"): the fast paths look at eight bytes at a
  # time, loaded into a UInt64. The masks below set the high bit (0x80) of
  # every byte in a class, and are zero exactly when no byte is. Subtracting
  # can borrow, and adding can carry, from a flagged byte into the next more
  # significant one, which may then be flagged as well. On little-endian
  # targets that is a later byte in memory, so the first flagged byte is
  # exact; on big-endian ones it is an earlier byte, so a run can only end
  # early and the caller's per-byte path takes over from there.
  SWAR_ONES = 0x0101010101010101_u64
  SWAR_HIGH = 0x8080808080808080_u64

  # The eight bytes at *p*, at any alignment.
  @[AlwaysInline]
  def load_word(p : Pointer(UInt8)) : UInt64
    word = uninitialized UInt64
    pointerof(word).as(Pointer(UInt8)).copy_from(p, 8)
    word
  end

  # The bytes of *word* with the high bit set (not ASCII).
  @[AlwaysInline]
  def non_ascii_mask(word : UInt64) : UInt64
    word & SWAR_HIGH
  end

  # The ASCII bytes of *word* below *byte* (at most 0x80): they borrow when
  # *byte* is subtracted.
  @[AlwaysInline]
  def below_mask(word : UInt64, byte : UInt8) : UInt64
    (word &- byte.to_u64 &* SWAR_ONES) & ~word & SWAR_HIGH
  end

  # The bytes of *word* equal to *byte*: zero after the XOR, so they borrow
  # when 1 is subtracted.
  @[AlwaysInline]
  def equal_mask(word : UInt64, byte : UInt8) : UInt64
    x = word ^ (byte.to_u64 &* SWAR_ONES)
    (x &- SWAR_ONES) & ~x & SWAR_HIGH
  end

  # Number of zero bytes, in memory order, before the first nonzero one of
  # the nonzero *word* (for a mask: before the first flagged byte).
  @[AlwaysInline]
  def zero_bytes_before(word : UInt64) : Int32
    # `IO::ByteFormat::SystemEndian` is always `LittleEndian` in Crystal 1.21,
    # so test the byte order directly; LLVM folds this to a constant.
    if 1_u16.unsafe_as(StaticArray(UInt8, 2))[0] == 1
      word.trailing_zeros_count.to_i32 // 8
    else
      word.leading_zeros_count.to_i32 // 8
    end
  end
end
