#!/usr/bin/env bash
set -euo pipefail

(cd server && go test ./...)
(cd app && flutter analyze && flutter test)
bash tool/verify_godot_tests.sh
