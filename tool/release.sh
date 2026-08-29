#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
readonly PUBSPEC_FILE="${ROOT_DIR}/app/pubspec.yaml"

usage() {
  cat <<'EOF'
Usage: bash tool/release.sh major|minor|patch [--dry-run]

Updates app/pubspec.yaml, commits the release, pushes the current branch, and
pushes the matching version tag to trigger the GitHub release workflow.
Use --dry-run to calculate and validate the release without changing Git state.
EOF
}

die() {
  printf 'release: %s\n' "$1" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
bump_type="$1"
dry_run=false
if [[ $# -eq 2 ]]; then
  [[ "$2" == "--dry-run" ]] || { usage >&2; exit 2; }
  dry_run=true
fi
case "$bump_type" in
  major|minor|patch) ;;
  *) die "bump must be major, minor, or patch" ;;
esac

[[ -f "$PUBSPEC_FILE" ]] || die "missing ${PUBSPEC_FILE}"
version_line="$(awk '/^version:[[:space:]]/ { print; exit }' "$PUBSPEC_FILE")"
[[ "$version_line" =~ ^version:[[:space:]]*([0-9]+)\.([0-9]+)\.([0-9]+)(\+([0-9]+))?[[:space:]]*$ ]] \
  || die "app/pubspec.yaml has an invalid version line"

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
build="${BASH_REMATCH[5]:-0}"
case "$bump_type" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac
build=$((build + 1))
version="${major}.${minor}.${patch}"
tag="v${version}"
new_version_line="version: ${version}+${build}"

cd "$ROOT_DIR"
git diff --quiet || die "working tree has tracked changes"
[[ -z "$(git ls-files --others --exclude-standard)" ]] || die "working tree has untracked files"
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "HEAD is detached"
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
[[ "$upstream" == "origin/${branch}" ]] || die "${branch} must track origin/${branch}"
git fetch origin "$branch" >/dev/null
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/${branch}")" ]] \
  || die "local ${branch} is not synchronized with origin/${branch}"
git show-ref --tags --verify --quiet "refs/tags/${tag}" && die "tag ${tag} already exists"
git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1 \
  && die "remote tag ${tag} already exists"

printf 'Next release: %s (build %s) from %s\n' "$version" "$build" "$branch"
if [[ "$dry_run" == true ]]; then
  printf 'Dry run: no files changed and nothing pushed.\n'
  exit 0
fi

GAMEBOX_RELEASE_VERSION_LINE="$new_version_line" perl -0pi \
  -e 's/^version:\s*\d+\.\d+\.\d+(?:\+\d+)?\s*$/$ENV{GAMEBOX_RELEASE_VERSION_LINE}/m' \
  "$PUBSPEC_FILE"
[[ "$(awk '/^version:[[:space:]]/ { print; exit }' "$PUBSPEC_FILE")" == "$new_version_line" ]] \
  || die "app/pubspec.yaml version was not updated"
git add -- app/pubspec.yaml
git commit -m "chore: release ${tag}"
git tag -a "$tag" -m "Release ${tag}"
git push origin "$branch"
git push origin "$tag"
printf 'Release triggered: https://github.com/shadowfish07/gamebox/actions\n'
