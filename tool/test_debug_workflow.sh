#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
workflow="$ROOT_DIR/.github/workflows/debug.yml"
readonly workflow

require_line() {
  local expected="$1"
  local description="$2"
  if ! grep -F -- "$expected" "$workflow" >/dev/null; then
    printf 'Debug workflow is missing %s\n' "$description" >&2
    exit 1
  fi
}

require_line '  push:' 'push trigger'
require_line "      - 'app/**'" 'application path filter'
require_line '  pull_request:' 'pull request trigger'
require_line '  workflow_dispatch:' 'manual trigger'
require_line '      api_base_url:' 'manual API URL input'
require_line '  contents: read' 'read-only default permissions'
require_line "'debug-apk-publish'" 'serialized trusted publication group'
require_line "format('debug-apk-build-{0}', github.ref)" 'isolated untrusted build group'
require_line '  build:' 'untrusted build job'
require_line '          persist-credentials: false' 'credential-free checkout'
require_line 'uses: actions/upload-artifact@v7' 'temporary artifact upload'
require_line 'retention-days: 14' 'PR artifact retention'
require_line '  publish:' 'trusted publish job'
require_line "github.ref == format('refs/heads/{0}', github.event.repository.default_branch)" 'default-ref publication guard'
require_line '      contents: write' 'publish-only write permission'
require_line '          GAMEBOX_REQUIRE_RELEASE_SIGNING: "true"' 'publish-only stable signing requirement'
require_line 'Keep the tag as the stable release identity' 'stable rolling release behavior'
if grep -F '      - main' "$workflow" >/dev/null; then
  printf 'Debug workflow still restricts push triggers to main\n' >&2
  exit 1
fi
build_job="$(awk '/^  build:/{capture=1} /^  publish:/{capture=0} capture' "$workflow")"
publish_job="$(awk '/^  publish:/{capture=1} capture' "$workflow")"
if grep -Eq 'ANDROID_(KEYSTORE|STORE|KEY|PASSWORD)|secrets\.|GH_TOKEN|contents: write' <<<"$build_job"; then
  printf 'Untrusted debug build job can access signing secrets or write credentials\n' >&2
  exit 1
fi
if ! grep -F 'secrets.ANDROID_KEYSTORE_BASE64' <<<"$publish_job" >/dev/null \
    || ! grep -F 'GH_TOKEN: ${{ github.token }}' <<<"$publish_job" >/dev/null; then
  printf 'Trusted publish job is missing stable signing or release credentials\n' >&2
  exit 1
fi
if grep -F 'update_debug_tag' "$workflow" >/dev/null; then
  printf 'Debug workflow still requires moving the rolling tag per branch\n' >&2
  exit 1
fi

printf 'PASS debug workflow isolates untrusted artifacts from trusted release publication\n'
