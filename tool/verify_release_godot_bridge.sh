#!/usr/bin/env bash
set -euo pipefail

mapping_file="${1:-}"
if [[ -z "$mapping_file" || $# -ne 1 ]]; then
  echo "usage: $0 PATH_TO_R8_MAPPING" >&2
  exit 2
fi
if [[ ! -f "$mapping_file" ]]; then
  echo "Godot release mapping not found: $mapping_file" >&2
  exit 1
fi

assert_mapping_line() {
  local expected="$1"
  grep -Fx "$expected" "$mapping_file" >/dev/null || {
    echo "Godot JNI release mapping changed: missing '$expected'" >&2
    exit 1
  }
}

assert_mapping_line \
  'org.godotengine.godot.GodotIO -> org.godotengine.godot.GodotIO:'
assert_mapping_line \
  'org.godotengine.godot.nativeapi.GodotNativeBridge -> org.godotengine.godot.nativeapi.GodotNativeBridge:'

grep -E 'GodotRenderView getRenderView\(\):[0-9]+(:[0-9]+)? -> getRenderView$' \
  "$mapping_file" >/dev/null || {
  echo "Godot JNI release mapping renamed getRenderView" >&2
  exit 1
}
grep -E 'int openURI\(java\.lang\.String\):[0-9]+(:[0-9]+)? -> openURI$' \
  "$mapping_file" >/dev/null || {
  echo "Godot JNI release mapping renamed openURI" >&2
  exit 1
}

echo "Verified release Godot JNI bridge mapping: $mapping_file"
