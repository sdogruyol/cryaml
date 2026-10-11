# :nodoc:
#
# A position in the input stream. All fields are zero-based; `index` and
# `column` count characters, not bytes (same as libyaml's `yaml_mark_t`).
struct YAML::Mark
  getter index : Int64
  getter line : Int64
  getter column : Int64

  def initialize(@index : Int64 = 0_i64, @line : Int64 = 0_i64, @column : Int64 = 0_i64)
  end
end

# :nodoc:
#
# A parsing/emitting event, equivalent to libyaml's `yaml_event_t`.
#
# Field usage per kind:
# * DOCUMENT_START: `version_directive`, `tag_directives`, `implicit`
# * DOCUMENT_END: `implicit`
# * ALIAS: `anchor`
# * SCALAR: `anchor`, `tag`, `value`, `plain_implicit`, `quoted_implicit`, `scalar_style`
# * SEQUENCE_START: `anchor`, `tag`, `implicit`, `sequence_style`
# * MAPPING_START: `anchor`, `tag`, `implicit`, `mapping_style`
struct YAML::Event
  # `implicit` is declared with the other flags, so that they share their
  # padding: 120 bytes instead of 128.
  property kind : EventKind = EventKind::NONE
  property start_mark : Mark = Mark.new
  property end_mark : Mark = Mark.new
  property version_directive : {Int32, Int32}? = nil
  property tag_directives : Array({String, String})? = nil
  property anchor : String? = nil
  property tag : String? = nil
  property value : String = ""
  property? implicit : Bool = false
  property? plain_implicit : Bool = false
  property? quoted_implicit : Bool = false
  property scalar_style : ScalarStyle = ScalarStyle::ANY
  property sequence_style : SequenceStyle = SequenceStyle::ANY
  property mapping_style : MappingStyle = MappingStyle::ANY

  # The other fields are set one by one: a constructor taking them as
  # keyword arguments would be compiled once for each combination of
  # arguments it is called with.
  def initialize
  end

  def initialize(@kind : EventKind)
  end

  def initialize(@kind : EventKind, @start_mark : Mark, @end_mark : Mark)
  end
end
