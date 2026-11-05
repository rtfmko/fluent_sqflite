#!/bin/bash
# Runs `flutter test` in a synced copy of this checkout, so several test runs (parallel agents) do not fight over
# build/native_assets/windows/sqlite3.dll. Edit files in the checkout, never in the copy.
#
# Usage: bash tool/mirror_test.sh <name> [flutter test args...]
#   copy:     ${FLUENT_MIRRORS:-$TMPDIR/fluent_sqflite_mirrors}/<name> (own build folder)
#   limit:    10 minutes (hung tests are killed, never waited for)
#   coverage: pass --coverage; the result is <copy>/coverage/lcov.info
set -u
NAME="${1:?usage: mirror_test.sh <name> [flutter test args...]}"; shift
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${FLUENT_MIRRORS:-${TMPDIR:-/tmp}/fluent_sqflite_mirrors}"
COPY="$BASE/$NAME"
mkdir -p "$COPY"
if command -v robocopy > /dev/null 2>&1; then
  MSYS_NO_PATHCONV=1 robocopy "$(cygpath -w "$ROOT")" "$(cygpath -w "$COPY")" /MIR /XD build .dart_tool .git .idea coverage /NFL /NDL /NJH /NJS > /dev/null
else
  rsync -a --delete --exclude build --exclude .dart_tool --exclude .git --exclude .idea --exclude coverage "$ROOT/" "$COPY/"
fi
cd "$COPY" || exit 1
if [ ! -f .dart_tool/package_config.json ]; then timeout 300 fvm flutter pub get > /dev/null 2>&1; fi
timeout 600 fvm flutter test "$@" 2>&1 | grep -v -E "^  (package|dart)"
echo "exit: ${PIPESTATUS[0]}"
