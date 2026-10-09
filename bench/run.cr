# Builds the benchmark for both implementations (release mode), runs them and
# prints Markdown tables: throughput, Crystal heap allocations, peak RSS.
#
#   crystal run bench/run.cr
#
# Needs libyaml installed for the stdlib side. Set CRYAML_LIBYAML_PREFIX to
# link a specific libyaml build (Crystal's macOS tarball bundles an older one).
require "json"
require "./inputs"

ROOT = File.expand_path("..", __DIR__)
BIN  = File.join(ROOT, "bin")

record Result, workload : String, bytes : Int32, operation : String,
  ops_per_sec : Float64, mb_per_sec : Float64, alloc_bytes_per_op : Float64 do
  include JSON::Serializable
end

def build(output : String, flags : Array(String)) : Nil
  args = ["build", "--release", "--no-debug", File.join(ROOT, "bench", "bench.cr"), "-o", output] + flags
  STDERR.puts "crystal #{args.join(' ')}"
  status = Process.run("crystal", args, output: STDERR, error: STDERR)
  abort "build failed" unless status.success?
end

def results(binary : String) : Array(Result)
  output = Process.run(binary, ["--json"]) { |process| process.output.gets_to_end }
  Array(Result).from_json(JSON.parse(output)["results"].to_json)
end

def peak_rss(binary : String, workload : String, operation : String) : Int64?
  output = Process.run(binary, ["--rss", workload, operation]) { |process| process.output.gets_to_end }
  JSON.parse(output)["rss_kb"].as_i64?
end

def libyaml_version(binary : String) : String
  Process.run(binary, ["--libyaml-version"]) { |process| process.output.gets_to_end.strip }
end

Dir.mkdir_p(BIN)
cryaml_bin = File.join(BIN, "bench-cryaml")
stdlib_bin = File.join(BIN, "bench-stdlib")
build(cryaml_bin, [] of String)
stdlib_flags = ["-Dstdlib_yaml"]
if prefix = ENV["CRYAML_LIBYAML_PREFIX"]?.presence
  lib_dir = File.join(prefix, "lib")
  stdlib_flags << "--link-flags" << "-L#{lib_dir} -Wl,-rpath,#{lib_dir}"
end
build(stdlib_bin, stdlib_flags)

puts "Crystal #{Crystal::VERSION}, #{{{ flag?(:darwin) ? "macOS" : flag?(:win32) ? "Windows" : "Linux" }}} " \
     "#{{{ flag?(:aarch64) ? "aarch64" : "x86_64" }}}, stdlib side on libyaml #{libyaml_version(stdlib_bin)}\n\n"

STDERR.puts "running stdlib..."
stdlib = results(stdlib_bin)
STDERR.puts "running cryaml..."
cryaml = results(cryaml_bin)

puts "## Throughput (higher is better)\n\n"
puts "| Workload | Operation | stdlib (libyaml) MB/s | cryaml MB/s | cryaml / stdlib |"
puts "| --- | --- | ---: | ---: | ---: |"
stdlib.zip(cryaml) do |s, c|
  puts "| #{s.workload} | #{s.operation} | #{s.mb_per_sec.round(2)} | #{c.mb_per_sec.round(2)} | #{(c.mb_per_sec / s.mb_per_sec).round(2)}x |"
end

puts "\n## Crystal heap allocated per operation\n\n"
puts "libyaml's own buffers are malloc'ed outside the GC and not counted here; peak RSS below includes them.\n\n"
puts "| Workload | Operation | stdlib KB/op | cryaml KB/op |"
puts "| --- | --- | ---: | ---: |"
stdlib.zip(cryaml) do |s, c|
  puts "| #{s.workload} | #{s.operation} | #{(s.alloc_bytes_per_op / 1024).round(1)} | #{(c.alloc_bytes_per_op / 1024).round(1)} |"
end

puts "\n## Peak RSS, `YAML.parse_all` x5 in a fresh process (lower is better)\n\n"
puts "| Workload | stdlib (libyaml) MB | cryaml MB |"
puts "| --- | ---: | ---: |"

def mb(kb : Int64?) : String
  kb ? (kb / 1024.0).round(1).to_s : "n/a"
end

BenchInputs.all.each do |name, _|
  puts "| #{name} | #{mb(peak_rss(stdlib_bin, name, "parse"))} | #{mb(peak_rss(cryaml_bin, name, "parse"))} |"
end
