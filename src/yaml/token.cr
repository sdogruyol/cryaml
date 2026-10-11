# :nodoc:
#
# Token types produced by `YAML::Scanner`, equivalent to libyaml's
# `yaml_token_type_t`.
enum YAML::TokenKind
  NONE
  STREAM_START
  STREAM_END
  VERSION_DIRECTIVE
  TAG_DIRECTIVE
  DOCUMENT_START
  DOCUMENT_END
  BLOCK_SEQUENCE_START
  BLOCK_MAPPING_START
  BLOCK_END
  FLOW_SEQUENCE_START
  FLOW_SEQUENCE_END
  FLOW_MAPPING_START
  FLOW_MAPPING_END
  BLOCK_ENTRY
  FLOW_ENTRY
  KEY
  VALUE
  ALIAS
  ANCHOR
  TAG
  SCALAR
end

# :nodoc:
#
# A scanner token, equivalent to libyaml's `yaml_token_t`.
#
# Field usage per kind:
# * ALIAS, ANCHOR: `value` (the name)
# * TAG: `handle`, `value` (the suffix)
# * TAG_DIRECTIVE: `handle`, `value` (the prefix)
# * SCALAR: `value`, `style`; or, for a value taken as it is from a `String`
#   input, `input_offset` and `input_bytesize` (see `Scanner#token_value`)
# * VERSION_DIRECTIVE: `major`, `minor`
struct YAML::Token
  # Declared in this order so that the 4-byte fields pair up: 80 bytes
  # instead of 88, and tokens are copied a lot.
  getter kind : TokenKind
  getter style : ScalarStyle
  getter start_mark : Mark
  getter end_mark : Mark
  getter value : String
  getter handle : String
  # Two numbers whose meaning depends on the kind (see the getters below).
  @number1 : Int32
  @number2 : Int32

  def initialize(@kind : TokenKind, @start_mark : Mark, @end_mark : Mark,
                 @value : String = "", @handle : String = "",
                 @style : ScalarStyle = ScalarStyle::ANY,
                 @number1 : Int32 = 0, @number2 : Int32 = 0)
  end

  # A SCALAR token whose value is the ASCII text of *bytesize* (> 0) bytes
  # at *offset* in the `String` input. The string is made only if it's
  # asked for (`Scanner#token_value`), so a `PullParser` walking events
  # without reading their values allocates nothing for them.
  def self.input_scalar(start_mark : Mark, end_mark : Mark, offset : Int32, bytesize : Int32, style : ScalarStyle) : self
    new(TokenKind::SCALAR, start_mark, end_mark, style: style, number1: offset, number2: bytesize)
  end

  def self.version_directive(start_mark : Mark, end_mark : Mark, major : Int32, minor : Int32) : self
    new(TokenKind::VERSION_DIRECTIVE, start_mark, end_mark, number1: major, number2: minor)
  end

  # Tag suffix (TAG tokens).
  def suffix : String
    @value
  end

  # Tag prefix (TAG_DIRECTIVE tokens).
  def prefix : String
    @value
  end

  # VERSION_DIRECTIVE tokens.
  def major : Int32
    @number1
  end

  def minor : Int32
    @number2
  end

  # Where a SCALAR's value lies in the `String` input when it's taken from
  # there; `input_bytesize` is 0 otherwise, and then the value is `value`.
  def input_offset : Int32
    @number1
  end

  def input_bytesize : Int32
    @number2
  end
end
