require "json"
require "base64"
require "./dump"

# Differential testing against the stdlib's libyaml-backed `YAML`.
#
# Cases are collected, written to a JSON bundle, dumped by the oracle binary
# (compiled from `oracle.cr` with `require "yaml"`), and compared with the
# same dump produced in-process by cryaml.
module Differential
  record Case, name : String, mode : String, input : String

  ROOT       = File.expand_path("../..", __DIR__)
  CACHE_DIR  = File.join(ROOT, ".cache")
  ORACLE_BIN = File.join(CACHE_DIR, "oracle")

  # Builds the oracle binary unless an up-to-date one exists.
  def self.oracle_binary : String
    sources = {File.join(__DIR__, "oracle.cr"), File.join(__DIR__, "dump.cr")}
    if File.exists?(ORACLE_BIN)
      built = File.info(ORACLE_BIN).modification_time
      return ORACLE_BIN if sources.all? { |src| File.info(src).modification_time < built }
    end
    Dir.mkdir_p(CACHE_DIR)
    status = Process.run("crystal", ["build", sources[0], "-o", ORACLE_BIN, "--no-debug"],
      output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
    raise "failed to build the libyaml oracle (is libyaml installed?)" unless status.success?
    ORACLE_BIN
  end

  def self.key(c : Case) : String
    "#{c.mode} #{c.name}"
  end

  # Runs the oracle on *cases*, returning `key` => dump.
  def self.oracle(cases : Array(Case)) : Hash(String, String)
    Dir.mkdir_p(CACHE_DIR)
    bundle = File.tempfile("bundle", ".json", dir: CACHE_DIR)
    begin
      bundle.print(cases.map { |c| {name: key(c), mode: c.mode, input: Base64.strict_encode(c.input)} }.to_json)
      bundle.close
      output = IO::Memory.new
      # The libyaml binding's PullParser forms a finalizer cycle when reading
      # from an IO, so Boehm prints a "Finalization cycle" warning per parse.
      # Only show the oracle's stderr when it fails.
      errors = IO::Memory.new
      status = Process.run(oracle_binary, [bundle.path], output: output, error: errors)
      raise "oracle failed:\n#{errors}" unless status.success?
      Hash(String, String).from_json(output.to_s)
    ensure
      bundle.delete
    end
  end

  # Defines one `it` per case comparing cryaml with the oracle.
  def self.compare(cases : Array(Case)) : Nil
    expected = oracle(cases)
    cases.each do |c|
      it "#{c.mode}: #{c.name}" do
        CryamlDump.run(c.mode, c.input).should eq(expected[key(c)])
      end
    end
  end
end
