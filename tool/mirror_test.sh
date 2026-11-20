#!/bin/bash
# Runs `flutter test` in a synced copy of this checkout, so several test runs (parallel agents) do not fight over
# build/native_assets/windows/sqlite3.dll. Edit files in the checkout, never in the copy.
#
# Usage: bash tool/mirror_test.sh <name> [flutter test args...]
#   copy:     ${FLUENT_MIRRORS:-<checkout>/.mirrors}/<name> (own build folder; .mirrors is git-ignored and never copied)
#   files:    the test databases live in <copy>/build/fluent_test_dbs (FLUENT_TEST_TMP), on the checkout's disk, not in
#             the system temporary folder
#   limit:    10 minutes (hung tests are killed, never waited for); FLUENT_TIME_LIMIT=<seconds> for long fuzz runs
#   coverage: pass --coverage; the result is <copy>/coverage/lcov.info
#   stress:   test/stress writes its report to <checkout>/.mirrors/stress_<name>_<date-time>.md (FLUENT_STRESS_REPORT)
set -u
NAME="${1:?usage: mirror_test.sh <name> [flutter test args...]}"; shift
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${FLUENT_MIRRORS:-$ROOT/.mirrors}"
COPY="$BASE/$NAME"
mkdir -p "$COPY"
if command -v robocopy > /dev/null 2>&1; then
  MSYS_NO_PATHCONV=1 robocopy "$(cygpath -w "$ROOT")" "$(cygpath -w "$COPY")" /MIR /XD build .dart_tool .git .idea .mirrors coverage /NFL /NDL /NJH /NJS > /dev/null
else
  rsync -a --delete --exclude build --exclude .dart_tool --exclude .git --exclude .idea --exclude .mirrors --exclude coverage "$ROOT/" "$COPY/"
fi
cd "$COPY" || exit 1
# macOS has no `timeout` unless coreutils is installed (then it may be `gtimeout`).
TIMEOUT="$(command -v timeout || command -v gtimeout)" || { echo "mirror_test.sh: needs timeout (macOS: brew install coreutils)"; exit 2; }
export FLUENT_TEST_TMP="${FLUENT_TEST_TMP:-$COPY/build/fluent_test_dbs}"
# Stress tests (test/stress) write their Markdown report here: one file per run, next to the copies.
WIN_BASE="$BASE"; command -v cygpath > /dev/null 2>&1 && WIN_BASE="$(cygpath -m "$BASE")"
export FLUENT_STRESS_REPORT="${FLUENT_STRESS_REPORT:-$WIN_BASE/stress_${NAME}_$(date +%Y%m%d-%H%M%S).md}"
if [ ! -f .dart_tool/package_config.json ]; then "$TIMEOUT" 300 fvm flutter pub get > /dev/null 2>&1; fi
"$TIMEOUT" "${FLUENT_TIME_LIMIT:-600}" fvm flutter test "$@" 2>&1 | grep -v -E "^  (package|dart)"
echo "exit: ${PIPESTATUS[0]}"
