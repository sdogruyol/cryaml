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
# * SCALAR: `value`, `style`
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
  getter major : Int32
  getter minor : Int32

  def initialize(@kind : TokenKind, @start_mark : Mark, @end_mark : Mark,
                 @value : String = "", @handle : String = "",
                 @style : ScalarStyle = ScalarStyle::ANY,
                 @major : Int32 = 0, @minor : Int32 = 0)
  end

  # Tag suffix (TAG tokens).
  def suffix : String
    @value
  end

  # Tag prefix (TAG_DIRECTIVE tokens).
  def prefix : String
    @value
  end
end
