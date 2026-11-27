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
speech_fixture=$(ffmpeg -hide_banner -loglevel error -f lavfi -i 'sine=frequency=440:duration=0.8' -codec:a libmp3lame -b:a 32k -f mp3 pipe:1 | base64 -w0)
flutter test --dart-define="VOICE_TEST_MP3=$speech_fixture" --reporter expanded -d emulator-5554 integration_test/companion_track_test.dart
