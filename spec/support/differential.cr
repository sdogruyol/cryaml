require "json"
require "base64"
require "./dump"

# Differential testing against the stdlib's libyaml-backed `YAML`.
#
# Every case is dumped by cryaml in process (`CryamlDump.run`) and compared
# with libyaml 0.2.5's dump of the same case. libyaml's dumps come from one of
# two places, selected with `CRYAML_ORACLE`:
#
# * unset (default): `spec/fixtures/golden/<suite>.json`, recorded from the
#   oracle. No libyaml needed, so this runs on every platform.
# * `CRYAML_ORACLE=1`: the live oracle binary (`oracle.cr` compiled with
#   `require "yaml"`). Also checks that the golden file is up to date.
# * `CRYAML_ORACLE=update`: the live oracle, and rewrites the golden file.
#
# The oracle must link libyaml 0.2.5 exactly: other releases differ (Crystal's
# own macOS build bundles an older libyaml), and the golden files are 0.2.5.
module Differential
  record Case, name : String, mode : String, input : String

  LIBYAML_VERSION = "0.2.5"
  ROOT            = File.expand_path("../..", __DIR__)
  CACHE_DIR       = File.join(ROOT, ".cache")
  GOLDEN_DIR      = File.join(ROOT, "spec", "fixtures", "golden")
  VERSION_KEY     = "__libyaml_version__"

  def self.oracle_mode : String?
    ENV["CRYAML_ORACLE"]?.presence
  end

  # Raised when a dump server dies or runs out of time; the fuzzer bisects
  # the batch to find the case responsible.
  class ServerFailure < Exception
  end

  # Builds a dump server (`oracle.cr`) unless an up-to-date one exists:
  # against the stdlib's libyaml binding by default, against cryaml with
  # *cryaml*. Set `CRYAML_LIBYAML_PREFIX` to link a libyaml 0.2.5 installed
  # under that prefix instead of the system one.
  def self.oracle_binary(*, cryaml : Bool = false, release : Bool = false) : String
    name = "oracle#{cryaml ? "-cryaml" : ""}#{release ? "-release" : ""}"
    binary = File.join(CACHE_DIR, {% if flag?(:win32) %}"#{name}.exe"{% else %}name{% end %})
    sources = [File.join(__DIR__, "oracle.cr"), File.join(__DIR__, "dump.cr")]
    sources.concat(Dir.glob(File.join(ROOT, "src", "**", "*.cr"))) if cryaml
    if File.exists?(binary)
      built = File.info(binary).modification_time
      return binary if sources.all? { |src| File.info(src).modification_time < built }
    end
    Dir.mkdir_p(CACHE_DIR)
    args = ["build", sources[0], "-o", binary, "--no-debug"]
    args << "--release" if release
    if cryaml
      args << "-Dcryaml"
    elsif prefix = ENV["CRYAML_LIBYAML_PREFIX"]?.presence
      lib_dir = File.join(prefix, "lib")
      args << "--link-flags" << "-L#{lib_dir} -Wl,-rpath,#{lib_dir}"
    end
    status = Process.run("crystal", args, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
    raise "failed to build #{binary} (is libyaml installed?)" unless status.success?
    binary
  end

  def self.key(c : Case) : String
    "#{c.mode} #{c.name}"
  end

  # Runs the libyaml oracle on *cases*, returning `key` => dump. Raises
  # unless the oracle links libyaml 0.2.5.
  def self.oracle(cases : Array(Case)) : Hash(String, String)
    run_server(oracle_binary, cases)
  end

  # Runs a dump server built by `oracle_binary` on *cases*. Raises
  # `ServerFailure` if it crashes or takes longer than *timeout*.
  def self.run_server(binary : String, cases : Array(Case), timeout : Time::Span? = nil) : Hash(String, String)
    Dir.mkdir_p(CACHE_DIR)
    bundle = File.tempfile("bundle", ".json", dir: CACHE_DIR)
    begin
      bundle.print(cases.map { |c| {name: key(c), mode: c.mode, input: Base64.strict_encode(c.input)} }.to_json)
      bundle.close
      output = IO::Memory.new
      # The libyaml binding's PullParser forms a finalizer cycle when reading
      # from an IO, so Boehm prints a "Finalization cycle" warning per parse.
      # Only show the server's stderr when it fails.
      errors = IO::Memory.new
      process = Process.new(binary, [bundle.path], output: output, error: errors)
      done = Channel(Process::Status).new(1)
      spawn { done.send(process.wait) }
      status =
        if timeout
          select
          when finished = done.receive
            finished
          when timeout(timeout)
            process.terminate(graceful: false)
            done.receive
            raise ServerFailure.new("#{binary} timed out after #{timeout}")
          end
        else
          done.receive
        end
      raise ServerFailure.new("#{binary} failed:\n#{errors.to_s[0, 2000]}") unless status.success?
      result = Hash(String, String).from_json(output.to_s)
      version = result.delete(VERSION_KEY)
      unless version == LIBYAML_VERSION
        raise "the oracle links libyaml #{version}, but #{LIBYAML_VERSION} is required " \
              "(build libyaml #{LIBYAML_VERSION} and set CRYAML_LIBYAML_PREFIX)"
      end
      result
    ensure
      bundle.delete
    end
  end

  def self.golden_path(suite : String) : String
    File.join(GOLDEN_DIR, "#{suite}.json")
  end

  def self.read_golden(suite : String) : Hash(String, String)
    path = golden_path(suite)
    return {} of String => String unless File.exists?(path)
    Hash(String, String).from_json(File.read(path))
  end

  # One entry per line, sorted, so regenerations diff cleanly.
  def self.write_golden(suite : String, dumps : Hash(String, String)) : Nil
    Dir.mkdir_p(GOLDEN_DIR)
    File.open(golden_path(suite), "w") do |file|
      file << "{\n"
      dumps.keys.sort!.each_with_index do |name, i|
        file << "  " << name.to_json << ": " << dumps[name].to_json
        file << (i == dumps.size - 1 ? "\n" : ",\n")
      end
      file << "}\n"
    end
  end

  # Defines one `it` per case comparing cryaml with libyaml's dump.
  def self.compare(suite : String, cases : Array(Case)) : Nil
    expected =
      case mode = oracle_mode
      when nil
        read_golden(suite)
      when "1", "update"
        live = oracle(cases)
        write_golden(suite, live) if mode == "update"
        golden = read_golden(suite)
        it "#{suite}: golden file matches libyaml #{LIBYAML_VERSION}" do
          stale = cases.map { |c| key(c) }.reject { |k| golden[k]? == live[k] }
          fail "#{stale.size} stale golden entries (run with CRYAML_ORACLE=update): #{stale.first(5)}" unless stale.empty?
        end
        live
      else
        raise "CRYAML_ORACLE must be unset, 1 or update (got #{mode.inspect})"
      end

    cases.each do |c|
      it "#{c.mode}: #{c.name}" do
        want = expected[key(c)]?
        fail "no recorded libyaml output for this case; run with CRYAML_ORACLE=update" unless want
        CryamlDump.run(c.mode, c.input).should eq(want)
      end
    end
  end
end
