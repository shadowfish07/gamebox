#!/usr/bin/env bash
set -euo pipefail

(cd server && go test ./...)
(cd app && flutter analyze && flutter test)
(
  cd app/android
  if command -v /usr/libexec/java_home >/dev/null 2>&1; then
    export JAVA_HOME
    JAVA_HOME="$(/usr/libexec/java_home -v 17)"
  fi
  ./gradlew :app:testDebugUnitTest
)
bash tool/verify_godot_tests.sh
bash tool/test_android_smoke_log.sh
