#!/bin/bash
# Splits a big fuzz run into slices of seeds and runs them at once, each in its own mirror (tool/mirror_test.sh), so
# they do not fight over the SQLite DLL. Slices never overlap: slice i runs the sequences
# FROM + i * chunk .. FROM + (i + 1) * chunk - 1 of every random test (FLUENT_FUZZ_FROM / FLUENT_FUZZ).
#
# Usage: bash tool/fuzz_parallel.sh <total> <shards> [from] [test files...]
#   bash tool/fuzz_parallel.sh 20000 6                 # sequences 0 .. 19999, six processes
#   bash tool/fuzz_parallel.sh 20000 6 20000           # the next 20000 (another machine, another night)
#   bash tool/fuzz_parallel.sh 5000 4 0 test/regressions/chaos_test.dart
#
# Files: the random tests (every file that calls fuzzSeeds) unless given. Logs: .mirrors/fuzz_<i>.log, a summary at the
# end. Time limit per slice: FLUENT_TIME_LIMIT (default 24 h). Shards: about half the CPU threads — the chaos tests
# wait on timers (20 s limits), an overloaded machine reports hangs that are only slowness.
set -u
TOTAL="${1:?usage: fuzz_parallel.sh <total> <shards> [from] [test files...]}"
SHARDS="${2:?usage: fuzz_parallel.sh <total> <shards> [from] [test files...]}"
FROM="${3:-0}"
shift $(( $# < 3 ? $# : 3 ))
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ $# -gt 0 ]; then
  FILES=("$@")
else
  FILES=()
  while IFS= read -r f; do FILES+=("$f"); done < <(cd "$ROOT" && grep -rl "fuzzSeeds(" test --include='*_test.dart' | sort) # bash 3 (macOS): no mapfile
fi
# A multiple of 5: tests that run a fifth of the sequences (share: 5) get whole, non-overlapping slices too.
CHUNK=$(( (TOTAL + SHARDS - 1) / SHARDS ))
CHUNK=$(( (CHUNK + 4) / 5 * 5 ))
LOGS="${FLUENT_MIRRORS:-$ROOT/.mirrors}"
mkdir -p "$LOGS"
export FLUENT_TIME_LIMIT="${FLUENT_TIME_LIMIT:-86400}"

echo "fuzz: sequences $FROM .. $(( FROM + CHUNK * SHARDS - 1 )) in $SHARDS slices of $CHUNK; ${#FILES[@]} file(s); logs in $LOGS/fuzz_<i>.log"
PIDS=()
for (( i = 0; i < SHARDS; i++ )); do
  START=$(( FROM + i * CHUNK ))
  ( FLUENT_FUZZ=$CHUNK FLUENT_FUZZ_FROM=$START bash "$ROOT/tool/mirror_test.sh" "fuzz_$i" "${FILES[@]}" > "$LOGS/fuzz_$i.log" 2>&1 ) &
  PIDS+=($!)
  echo "  slice $i: $START .. $(( START + CHUNK - 1 )) (pid $!)"
done

FAILED=0
for (( i = 0; i < SHARDS; i++ )); do
  wait "${PIDS[$i]}"
  LOG="$LOGS/fuzz_$i.log"
  CODE="$(grep -E '^exit: ' "$LOG" | tail -1)"
  echo "slice $i: ${CODE:-no exit line} — $(grep -E '^[0-9:]+ \+[0-9]+' "$LOG" | tail -1 | grep -oE '\+[0-9]+( ~[0-9]+)?( -[0-9]+)?' | head -1)"
  if [ "$CODE" != "exit: 0" ]; then
    FAILED=1
    sed -n '/^Failing tests:/,$p' "$LOG" | grep -v '^exit: '
  fi
done
exit $FAILED
