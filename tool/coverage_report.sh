#!/bin/bash
# Coverage of lib/ per file, from an lcov file, plus the uncovered line ranges (input for the coverage map).
#
# Usage:
#   bash tool/mirror_test.sh coverage --coverage          # runs the suite in a copy, writes <copy>/coverage/lcov.info
#   bash tool/coverage_report.sh [lcov.info] [out dir]    # default: the copy above, out dir .coverage/
#
# Writes <out>/summary.txt (files sorted by line coverage, lowest first) and <out>/uncovered.txt
# ("<file>: 12-15, 40, 88-90"), and prints the summary.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${FLUENT_MIRRORS:-$ROOT/.mirrors}"
LCOV="${1:-$BASE/coverage/coverage/lcov.info}"
OUT="${2:-$ROOT/.coverage}"
[ -f "$LCOV" ] || { echo "no lcov file at $LCOV (run: bash tool/mirror_test.sh coverage --coverage)"; exit 1; }
mkdir -p "$OUT"
awk -v summary="$OUT/summary.txt" -v uncovered="$OUT/uncovered.txt" '
  function flush() {
    if (file == "") return
    pct = total ? 100 * hit / total : 100
    printf "%6.1f%%  %5d/%-5d  %s\n", pct, hit, total, file >> summary
    ranges = ""; start = -1; prev = -1
    n = split(miss, lines, " ")
    for (i = 1; i <= n; i++) {
      l = lines[i] + 0
      if (start < 0) { start = l; prev = l; continue }
      if (l == prev + 1) { prev = l; continue }
      ranges = ranges (ranges == "" ? "" : ", ") (start == prev ? start : start "-" prev)
      start = l; prev = l
    }
    if (start >= 0) ranges = ranges (ranges == "" ? "" : ", ") (start == prev ? start : start "-" prev)
    if (ranges != "") print file ": " ranges >> uncovered
  }
  BEGIN { printf "" > summary; printf "" > uncovered }
  /^SF:/ { flush(); file = substr($0, 4); gsub(/\\/, "/", file); sub(/.*\/lib\//, "lib/", file); hit = 0; total = 0; miss = "" }
  /^DA:/ { split(substr($0, 4), d, ","); total++; if (d[2] > 0) hit++; else miss = miss " " d[1] }
  /^end_of_record/ { flush(); file = "" }
' "$LCOV"
sort -n -o "$OUT/summary.txt" "$OUT/summary.txt"
cat "$OUT/summary.txt"
echo "uncovered ranges: $OUT/uncovered.txt"
