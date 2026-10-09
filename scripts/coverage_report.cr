# Prints kcov's per-file line coverage for src/ and fails below the floors.
# Used by scripts/coverage.sh.
require "json"

# Room is left only for code the public API can't reach: emitter directives
# and canonical mode, defensive buffer growth, sticky-error re-raises.
FLOORS = {
  "yaml/scanner.cr"      => 99.0,
  "yaml/event_parser.cr" => 98.0,
  "yaml/reader.cr"       => 97.0,
  "yaml/emitter.cr"      => 94.0,
  "yaml/builder.cr"      => 100.0,
  "yaml/pull_parser.cr"  => 100.0,
}

report = JSON.parse(File.read(ARGV[0]))
failed = false
report["files"].as_a.each do |file|
  name = file["file"].as_s.split("/src/").last
  percent = file["percent_covered"].as_s.to_f
  floor = FLOORS[name]? || 0.0
  below = percent < floor
  failed ||= below
  printf("%-24s %6.2f%%  (%s/%s lines)%s\n", name, percent, file["covered_lines"], file["total_lines"],
    below ? "  below the #{floor}% floor" : "")
end
printf("total %.2f%%\n", report["percent_covered"].as_s.to_f)
exit(failed ? 1 : 0)
