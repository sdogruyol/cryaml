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
  property kind : EventKind
  property start_mark : Mark
  property end_mark : Mark
  property version_directive : {Int32, Int32}?
  property tag_directives : Array({String, String})?
  property? implicit : Bool
  property anchor : String?
  property tag : String?
  property value : String
  property? plain_implicit : Bool
  property? quoted_implicit : Bool
  property scalar_style : ScalarStyle
  property sequence_style : SequenceStyle
  property mapping_style : MappingStyle

  def initialize(@kind : EventKind = EventKind::NONE,
                 @start_mark : Mark = Mark.new, @end_mark : Mark = Mark.new,
                 *,
                 @version_directive = nil, @tag_directives = nil,
                 @implicit = false, @anchor = nil, @tag = nil, @value = "",
                 @plain_implicit = false, @quoted_implicit = false,
                 @scalar_style = ScalarStyle::ANY,
                 @sequence_style = SequenceStyle::ANY,
                 @mapping_style = MappingStyle::ANY)
  end
end
