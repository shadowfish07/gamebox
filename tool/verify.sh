#!/usr/bin/env bash
set -euo pipefail

# Task 1 has no cross-runtime Android integration checks yet.
exec bash tool/verify_fast.sh
