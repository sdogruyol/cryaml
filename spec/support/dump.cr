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
        else                  raise "unknown mode #{mode}"
        end
      rescue ex : YAML::ParseException
        io << "!ParseException " << ex.message << " @" << ex.line_number << ':' << ex.column_number << '\n'
      rescue ex : YAML::Error
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
