# One benchmark binary per implementation:
#
#   crystal build --release bench/bench.cr -o bin/bench-cryaml
#   crystal build --release -Dstdlib_yaml bench/bench.cr -o bin/bench-stdlib
#
# `bench/run.cr` builds both and prints the comparison. Run a binary directly
# with `--json` for machine-readable output, or `--rss WORKLOAD OPERATION` to
# measure the peak RSS of one workload in a fresh process.
{% if flag?(:stdlib_yaml) %}
  require "yaml"
{% else %}
  require "../src/cryaml"
{% end %}
require "json"
require "./inputs"

IMPL       = {{ flag?(:stdlib_yaml) ? "stdlib (libyaml)" : "cryaml" }}
OPERATIONS = %w(parse pull nodes dump)

def run_operation(operation : String, input : String, value : YAML::Any) : Nil
  case operation
  when "parse"
    YAML.parse_all(input)
  when "pull"
    # Raw tokenizer + parser throughput: walk every event.
    parser = YAML::PullParser.new(input)
    until parser.kind.stream_end?
      parser.read_next
    end
  when "nodes"
    YAML::Nodes.parse_all(input)
  when "dump"
    value.to_yaml
  else
    raise "unknown operation #{operation}"
  end
end

def document_value(input : String) : YAML::Any
  YAML::Any.new(YAML.parse_all(input))
end

# Peak resident set size in KiB (benchmark tooling only; the library itself
# never calls into C). On Linux, getrusage's ru_maxrss survives execve, so it
# would report the launching process's peak if that was higher; VmHWM is this
# process's own.
def peak_rss_kb : Int64?
  {% if flag?(:linux) %}
    File.each_line("/proc/self/status") do |line|
      return line.split[1].to_i64 if line.starts_with?("VmHWM:")
    end
    nil
  {% elsif flag?(:unix) %}
    return unless LibC.getrusage(LibC::RUSAGE_SELF, out usage) == 0
    # ru_maxrss is in bytes on macOS, KiB elsewhere.
    {% if flag?(:darwin) %} usage.ru_maxrss.to_i64 // 1024 {% else %} usage.ru_maxrss.to_i64 {% end %}
  {% end %}
end

if ARGV[0]? == "--libyaml-version"
  puts YAML.libyaml_version
  exit
end

if ARGV[0]? == "--rss"
  name = ARGV[1]
  operation = ARGV[2]
  input = BenchInputs.all.find! { |entry| entry[0] == name }[1]
  value = document_value(input)
  before = peak_rss_kb
  5.times { run_operation(operation, input, value) }
  puts({rss_kb: peak_rss_kb, baseline_kb: before}.to_json)
  exit
end

results = [] of NamedTuple(workload: String, bytes: Int32, operation: String, ops_per_sec: Float64, mb_per_sec: Float64, alloc_bytes_per_op: Float64)

BenchInputs.all.each do |name, input|
  value = document_value(input)
  OPERATIONS.each do |operation|
    # Warm up, then run for at least ~0.5s. The deep document exceeds
    # Builder#max_nesting (99) in both implementations, so it can't be dumped.
    begin
      run_operation(operation, input, value)
    rescue ex : YAML::Error
      raise ex unless operation == "dump"
      next
    end
    iterations = 0
    GC.collect
    allocated_before = GC.stats.total_bytes
    start = Time.instant
    elapsed = Time::Span.zero
    while elapsed < 0.5.seconds || iterations < 3
      run_operation(operation, input, value)
      iterations += 1
      elapsed = Time.instant - start
    end
    allocated = GC.stats.total_bytes - allocated_before
    seconds = elapsed.total_seconds
    results << {
      workload:           name,
      bytes:              input.bytesize,
      operation:          operation,
      ops_per_sec:        iterations / seconds,
      mb_per_sec:         input.bytesize * iterations / seconds / 1_000_000,
      alloc_bytes_per_op: allocated.to_f / iterations,
    }
  end
end

if ARGV.includes?("--json")
  puts({impl: IMPL, results: results}.to_json)
else
  puts IMPL
  results.each do |r|
    printf("%-28s %-6s %10.1f ops/s %8.2f MB/s %12.0f B/op\n",
      r[:workload], r[:operation], r[:ops_per_sec], r[:mb_per_sec], r[:alloc_bytes_per_op])
  end
end
