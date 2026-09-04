#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
build_workflow="$ROOT_DIR/.github/workflows/debug.yml"
readonly build_workflow
comment_workflow="$ROOT_DIR/.github/workflows/debug-pr-comment.yml"
readonly comment_workflow

require_line() {
  local file="$1"
  local expected="$2"
  local description="$3"
  if ! grep -F -- "$expected" "$file" >/dev/null; then
    printf '%s is missing %s\n' "$(basename "$file")" "$description" >&2
    exit 1
  fi
}

require_line "$build_workflow" '  push:' 'push trigger'
require_line "$build_workflow" '      - main' 'default-branch push trigger'
require_line "$build_workflow" "      - 'app/**'" 'application path filter'
require_line "$build_workflow" "      - '.github/workflows/debug-pr-comment.yml'" 'comment workflow path filter'
require_line "$build_workflow" '  pull_request:' 'pull request trigger'
require_line "$build_workflow" '      - opened' 'initial pull request build trigger'
require_line "$build_workflow" '      - reopened' 'reopened pull request build trigger'
require_line "$build_workflow" '  workflow_dispatch:' 'manual trigger'
require_line "$build_workflow" '      api_base_url:' 'manual API URL input'
require_line "$build_workflow" '  contents: read' 'read-only default permissions'
require_line "$build_workflow" "'debug-apk-publish'" 'serialized trusted publication group'
require_line "$build_workflow" "format('debug-apk-build-{0}', github.ref)" 'isolated non-publishing build group'
require_line "$build_workflow" "group: \${{ (github.event_name == 'workflow_dispatch' || (github.event_name == 'push' && github.ref == format('refs/heads/{0}', github.event.repository.default_branch))) && 'debug-apk-publish' || format('debug-apk-build-{0}', github.ref) }}" 'any-branch manual publication concurrency'
require_line "$build_workflow" "cancel-in-progress: \${{ !(github.event_name == 'workflow_dispatch' || (github.event_name == 'push' && github.ref == format('refs/heads/{0}', github.event.repository.default_branch))) }}" 'non-cancelling serialized publication'
require_line "$build_workflow" '  build:' 'debug build job'
require_line "$build_workflow" '          persist-credentials: false' 'credential-free checkout'
require_line "$build_workflow" '      - name: Configure stable signing for trusted pull request' 'trusted pull request signing step'
require_line "$build_workflow" "github.event.pull_request.user.login == 'shadowfish07'" 'trusted pull request author guard'
require_line "$build_workflow" "github.actor == 'shadowfish07'" 'trusted pull request actor guard'
require_line "$build_workflow" 'github.event.pull_request.head.repo.full_name == github.repository' 'same-repository pull request guard'
require_line "$build_workflow" 'uses: actions/upload-artifact@v7' 'temporary artifact upload'
require_line "$build_workflow" 'retention-days: 14' 'PR artifact retention'
require_line "$build_workflow" '  publish:' 'trusted publish job'
require_line "$build_workflow" "if: github.event_name == 'workflow_dispatch' || (github.event_name == 'push' && github.ref == format('refs/heads/{0}', github.event.repository.default_branch))" 'any-branch manual publication guard'
require_line "$build_workflow" '      contents: write' 'publish-only write permission'
require_line "$build_workflow" '          GAMEBOX_REQUIRE_RELEASE_SIGNING: "true"' 'publish-only stable signing requirement'
require_line "$build_workflow" 'Keep the tag as the stable release identity' 'stable rolling release behavior'
if grep -F '      - synchronize' "$build_workflow" >/dev/null; then
  printf 'Debug workflow still builds APKs for pull request updates\n' >&2
  exit 1
fi
build_job="$(awk '/^  build:/{capture=1} /^  publish:/{capture=0} capture' "$build_workflow")"
publish_job="$(awk '/^  publish:/{capture=1} capture' "$build_workflow")"
trusted_pr_signing_step="$(awk '/^      - name: Configure stable signing for trusted pull request/{capture=1} /^      - name: Build debug APK/{capture=0} capture' "$build_workflow")"
if grep -Eq 'GH_TOKEN|contents: write' <<<"$build_job"; then
  printf 'Debug build job can access write credentials\n' >&2
  exit 1
fi
for expected in \
  "github.event_name == 'pull_request'" \
  "github.event.pull_request.user.login == 'shadowfish07'" \
  "github.actor == 'shadowfish07'" \
  'github.event.pull_request.head.repo.full_name == github.repository' \
  'secrets.ANDROID_KEYSTORE_BASE64' \
  'secrets.ANDROID_STORE_PASSWORD' \
  'secrets.ANDROID_KEY_ALIAS' \
  'secrets.ANDROID_KEY_PASSWORD' \
  'GAMEBOX_REQUIRE_RELEASE_SIGNING=true'; do
  if ! grep -F -- "$expected" <<<"$trusted_pr_signing_step" >/dev/null; then
    printf 'Trusted pull request signing step is missing required guard or signing input: %s\n' "$expected" >&2
    exit 1
  fi
done
if [[ "$(grep -c 'secrets\.' <<<"$build_job")" -ne 4 ]]; then
  printf 'Debug build job exposes unexpected repository secrets\n' >&2
  exit 1
fi
if ! grep -F 'if: always()' <<<"$build_job" >/dev/null \
    || ! grep -F 'rm -f app/android/app/release-key.jks app/android/key.properties' <<<"$build_job" >/dev/null; then
  printf 'Debug build job does not always remove signing material\n' >&2
  exit 1
fi
if ! grep -F 'secrets.ANDROID_KEYSTORE_BASE64' <<<"$publish_job" >/dev/null \
    || ! grep -F 'GH_TOKEN: ${{ github.token }}' <<<"$publish_job" >/dev/null; then
  printf 'Trusted publish job is missing stable signing or release credentials\n' >&2
  exit 1
fi
if grep -F 'update_debug_tag' "$build_workflow" >/dev/null; then
  printf 'Debug workflow still requires moving the rolling tag per branch\n' >&2
  exit 1
fi
if grep -F 'pull_request_target' "$build_workflow" >/dev/null; then
  printf 'Debug workflow must not expose signing secrets through pull_request_target\n' >&2
  exit 1
fi

require_line "$comment_workflow" '  workflow_run:' 'trusted workflow_run trigger'
require_line "$comment_workflow" '      - Debug APK' 'Debug APK source workflow filter'
require_line "$comment_workflow" '      - completed' 'completed source run filter'
require_line "$comment_workflow" '  actions: read' 'artifact read permission'
require_line "$comment_workflow" '  pull-requests: write' 'pull request comment permission'
require_line "$comment_workflow" "github.event.workflow_run.conclusion == 'success'" 'successful build guard'
require_line "$comment_workflow" "github.event.workflow_run.event == 'pull_request'" 'pull request event guard'
require_line "$comment_workflow" 'repos/${GITHUB_REPOSITORY}/actions/runs/${RUN_ID}/artifacts?per_page=100' 'source-run artifact lookup'
require_line "$comment_workflow" '^gamebox-debug-[0-9a-f]{40}$' 'artifact name validation'
require_line "$comment_workflow" '<!-- gamebox-pr-debug-apk -->' 'stable PR comment marker'
require_line "$comment_workflow" 'actions/runs/${RUN_ID}/artifacts/${artifact_id}' 'artifact download link'
require_line "$comment_workflow" 'GitHub sign-in is required.' 'authenticated download disclosure'
if grep -Eq 'actions/checkout|pull_request_target|secrets\.' "$comment_workflow"; then
  printf 'PR comment workflow can execute untrusted code or access repository secrets\n' >&2
  exit 1
fi

printf 'PASS debug workflow publishes manual branch builds while restricting PR credentials\n'
