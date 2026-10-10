# :nodoc:
#
# Character classification on UTF-8 byte buffers, mirroring the `IS_*_AT`
# macros of libyaml's `yaml_private.h`. Offsets are byte offsets from *p*.
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
      (c == 0xC2 && p[o + 1] >= 0xA0) ||
      (c > 0xC2 && c < 0xED) ||
      (c == 0xED && p[o + 1] < 0xA0) ||
      c == 0xEE ||
      (c == 0xEF &&
        !(p[o + 1] == 0xBB && p[o + 2] == 0xBF) &&
        !(p[o + 1] == 0xBF && (p[o + 2] == 0xBE || p[o + 2] == 0xBF)))
  end

  @[AlwaysInline]
  def z?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    p[o] == 0
  end

  @[AlwaysInline]
  def bom?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    p[o] == 0xEF && p[o + 1] == 0xBB && p[o + 2] == 0xBF
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
      (c == 0xC2 && p[o + 1] == 0x85) ||
      (c == 0xE2 && p[o + 1] == 0x80 && (p[o + 2] == 0xA8 || p[o + 2] == 0xA9))
  end

  @[AlwaysInline]
  def crlf?(p : Pointer(UInt8), o : Int32 = 0) : Bool
    p[o] == '\r'.ord && p[o + 1] == '\n'.ord
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
end
