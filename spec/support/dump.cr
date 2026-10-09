# Canonical text dumps of everything observable through the public YAML API.
#
# This file is compiled twice: inside the spec process against cryaml, and in
# the oracle binary (`spec/support/oracle.cr`) against the stdlib's libyaml
# binding. Equal dumps mean equal observable behavior. It must therefore only
# use the public `YAML` API shared by both implementations.
module CryamlDump
  # Dumps are scrubbed to valid UTF-8 so they survive the JSON transport
  # from the oracle unchanged.
  def self.run(mode : String, input : String) : String
    String.build do |io|
      begin
        case mode
        when "events"    then events(io, input)
        when "events_io" then events(io, SlowIO.new(input))
        when "any"       then io << YAML.parse(input).inspect << '\n'
        when "any_all"   then io << YAML.parse_all(input).inspect << '\n'
        when "nodes"     then nodes(io, input)
        when "emit"      then emit(io, input)
        when "dump"      then dump(io, input)
        when "build"     then build(io, input)
        else                  raise "unknown mode #{mode}"
        end
      rescue ex : YAML::ParseException
        io << "!ParseException " << ex.message << " @" << ex.line_number << ':' << ex.column_number << '\n'
      rescue ex : YAML::Error
        io << "!" << ex.class << ' ' << ex.message << '\n'
      rescue ex
        # Non-YAML errors raised by the shared upper layers (for example
        # Time::Format::Error from the core schema) must match too.
        io << "!" << ex.class << ' ' << ex.message << '\n'
      end
    end.scrub
  end

  # Event stream as seen through `YAML::PullParser`.
  def self.events(io : IO, input : String | IO) : Nil
    parser = YAML::PullParser.new(input)
    loop do
      event(io, parser)
      break if parser.kind.stream_end?
      parser.read_next
    end
  end

  def self.event(io : IO, parser : YAML::PullParser) : Nil
    kind = parser.kind
    io << kind
    if anchor = parser.anchor
      io << " &" << anchor
    end
    case kind
    when .scalar?
      if tag = parser.tag
        io << " <" << tag << '>'
      end
      io << ' ' << parser.scalar_style << ' ' << parser.value.inspect
    when .sequence_start?
      if tag = parser.tag
        io << " <" << tag << '>'
      end
      io << ' ' << parser.sequence_style
    when .mapping_start?
      if tag = parser.tag
        io << " <" << tag << '>'
      end
      io << ' ' << parser.mapping_style
    else
      # no extra data
    end
    io << " (" << parser.start_line << ':' << parser.start_column
    io << '-' << parser.end_line << ':' << parser.end_column << ")\n"
  end

  # `YAML::Nodes` tree, including positions, styles, tags and anchors.
  def self.nodes(io : IO, input : String) : Nil
    YAML::Nodes.parse_all(input).each do |document|
      io << "DOC " << document.location << '\n'
      document.nodes.each { |node| node(io, node, 1) }
    end
  end

  def self.node(io : IO, node : YAML::Nodes::Node, depth : Int32) : Nil
    io << "  " * depth << node.class.name.split("::").last
    io << " &" << node.anchor if node.anchor
    io << " <" << node.tag << '>' if node.tag
    io << " " << node.location << '-' << node.end_line << ':' << node.end_column
    case node
    when YAML::Nodes::Scalar
      io << ' ' << node.style << ' ' << node.value.inspect << '\n'
    when YAML::Nodes::Sequence
      io << ' ' << node.style << '\n'
      node.nodes.each { |child| node(io, child, depth + 1) }
    when YAML::Nodes::Mapping
      io << ' ' << node.style << '\n'
      node.nodes.each { |child| node(io, child, depth + 1) }
    when YAML::Nodes::Alias
      io << " -> " << node.anchor << '\n'
    end
  end

  # Parses with the pull parser and replays every event into a
  # `YAML::Builder`, dumping the emitted text. Exercises the emitter on the
  # styles, tags and anchors found in the input.
  def self.emit(io : IO, input : String) : Nil
    output = IO::Memory.new
    parser = YAML::PullParser.new(input)
    builder = YAML::Builder.new(output)
    begin
      loop do
        case parser.kind
        when .stream_start?   then builder.start_stream
        when .stream_end?     then builder.end_stream
        when .document_start? then builder.start_document
        when .document_end?   then builder.end_document
        when .scalar?         then builder.scalar(parser.value, parser.anchor, parser.tag, parser.scalar_style)
        when .alias?          then builder.alias(parser.anchor.not_nil!)
        when .sequence_start? then builder.start_sequence(parser.anchor, parser.tag, parser.sequence_style)
        when .sequence_end?   then builder.end_sequence
        when .mapping_start?  then builder.start_mapping(parser.anchor, parser.tag, parser.mapping_style)
        when .mapping_end?    then builder.end_mapping
        else                       raise "unexpected #{parser.kind}"
        end
        break if parser.kind.stream_end?
        parser.read_next
      end
    ensure
      builder.flush
      io << output.to_s.inspect << '\n'
    end
  end

  # Interprets a line-based script of `YAML::Builder` calls and dumps the
  # emitted text (also when a call raises). One call per line:
  #
  #   stream_start | stream_end | doc_start implicit|explicit | doc_end
  #   seq_start STYLE ANCHOR TAG | seq_end | map_start STYLE ANCHOR TAG | map_end
  #   alias NAME | scalar STYLE ANCHOR TAG VALUE
  #
  # ANCHOR/TAG/NAME/VALUE are escaped with `build_escape`; ANCHOR/TAG `-` is nil.
  def self.build(io : IO, input : String) : Nil
    output = IO::Memory.new
    builder = YAML::Builder.new(output)
    begin
      input.each_line do |line|
        next if line.empty?
        fields = line.split(' ', 5)
        case fields[0]
        when "stream_start" then builder.start_stream
        when "stream_end"   then builder.end_stream
        when "doc_start"    then builder.start_document(implicit_start_indicator: fields[1] == "implicit")
        when "doc_end"      then builder.end_document
        when "seq_start"
          builder.start_sequence(build_field(fields[2]), build_field(fields[3]), YAML::SequenceStyle.parse(fields[1]))
        when "seq_end" then builder.end_sequence
        when "map_start"
          builder.start_mapping(build_field(fields[2]), build_field(fields[3]), YAML::MappingStyle.parse(fields[1]))
        when "map_end" then builder.end_mapping
        when "alias"   then builder.alias(build_unescape(fields[1]))
        when "scalar"
          builder.scalar(build_unescape(fields[4]), build_field(fields[2]), build_field(fields[3]), YAML::ScalarStyle.parse(fields[1]))
        else raise "unknown build call #{line}"
        end
      end
    ensure
      builder.flush
      io << output.to_s.inspect << '\n'
    end
  end

  # Escapes *string* as one space-free script field. Bytes that aren't valid
  # UTF-8 become `\x{HH}`, so scripts can carry any byte string.
  def self.build_escape(string : String) : String
    return %("") if string.empty?
    String.build do |str|
      reader = Char::Reader.new(string)
      while reader.has_next?
        char = reader.current_char
        if reader.error
          string.to_slice[reader.pos, reader.current_char_width].each do |byte|
            str << "\\x{" << byte.to_s(16) << '}'
          end
        else
          case char
          when ' '  then str << "\\s"
          when '\n' then str << "\\n"
          when '\t' then str << "\\t"
          when '\r' then str << "\\r"
          when '\\' then str << "\\\\"
          else
            if char.ord < 0x20 || char.ord == 0x7F || char == '"'
              str << "\\u{" << char.ord.to_s(16) << '}'
            else
              str << char
            end
          end
        end
        reader.next_char
      end
    end
  end

  def self.build_unescape(field : String) : String
    return "" if field == %("")
    io = IO::Memory.new
    reader = Char::Reader.new(field)
    while reader.has_next?
      char = reader.current_char
      if char == '\\'
        case escape = reader.next_char
        when 's' then io << ' '
        when 'n' then io << '\n'
        when 't' then io << '\t'
        when 'r' then io << '\r'
        when 'u', 'x'
          reader.next_char # {
          hex = String.build do |h|
            until reader.peek_next_char == '}'
              h << reader.next_char
            end
            reader.next_char
          end
          escape == 'u' ? io << hex.to_i(16).chr : io.write_byte(hex.to_u8(16))
        else io << escape
        end
      else
        io << char
      end
      reader.next_char
    end
    String.new(io.to_slice)
  end

  private def self.build_field(field : String) : String?
    field == "-" ? nil : build_unescape(field)
  end

  # Value API round trip: parse, dump with `to_yaml`, parse again.
  def self.dump(io : IO, input : String) : Nil
    yaml = YAML.parse(input).to_yaml
    io << yaml.inspect << '\n'
    io << YAML.parse(yaml).inspect << '\n'
  end

  # An IO handing out a few bytes per read, to exercise chunked input.
  class SlowIO < IO
    def initialize(string : String)
      @memory = IO::Memory.new(string)
      @step = 0
    end

    def read(slice : Bytes) : Int32
      @step = (@step % 7) + 1
      @memory.read(slice[0, Math.min(slice.size, @step * 997)])
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("read-only")
    end
  end
end
