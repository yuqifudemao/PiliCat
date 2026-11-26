#!/usr/bin/env bash
# Grant the test build microphone permission on the CI emulator as soon as it is installed.
set -euo pipefail
(
  while true; do
    adb -s emulator-5554 shell pm grant io.github.yuqifudemao.pilinara.debug android.permission.RECORD_AUDIO >/dev/null 2>&1 || true
    sleep 1
  done
) &
grant_pid=$!
trap 'kill "$grant_pid" 2>/dev/null || true' EXIT
flutter test --reporter expanded -d emulator-5554 integration_test/companion_track_test.dart
