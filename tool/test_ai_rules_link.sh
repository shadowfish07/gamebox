#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
# shellcheck source=tool/lib/ai_rules_link.sh
source "$ROOT_DIR/tool/lib/ai_rules_link.sh"

fixture_root="$(mktemp -d -t gamebox-ai-rules.XXXXXX)"
readonly fixture_root
trap 'rm -rf "$fixture_root"' EXIT

rules_source="$fixture_root/ai-rules/rules"
primary_root="$fixture_root/primary"
project_root="$fixture_root/project"
mkdir -p "$rules_source" "$primary_root" "$project_root"
for route in verification flutter android godot go ui-acceptance git; do
  mkdir -p "$rules_source/$route"
  printf '# fixture\n' >"$rules_source/$route/index.md"
done

export GAMEBOX_AI_RULES_DIR="$rules_source"
gamebox_ai_rules_ensure_link "$project_root" "$primary_root" >/dev/null
first_target="$(readlink "$project_root/.ai/rules")"
[[ "$first_target" == "$(cd "$rules_source" && pwd -P)" ]]
gamebox_ai_rules_ensure_link "$project_root" "$primary_root" >/dev/null
[[ "$(readlink "$project_root/.ai/rules")" == "$first_target" ]]

mkdir -p "$primary_root/.ai"
ln -s "$rules_source" "$primary_root/.ai/rules"
unset GAMEBOX_AI_RULES_DIR
primary_link_project="$fixture_root/primary-link-project"
mkdir -p "$primary_link_project"
gamebox_ai_rules_ensure_link "$primary_link_project" "$primary_root" >/dev/null
[[ "$(readlink "$primary_link_project/.ai/rules")" == "$first_target" ]]
export GAMEBOX_AI_RULES_DIR="$rules_source"

conflict_root="$fixture_root/conflict"
mkdir -p "$conflict_root/.ai/rules"
conflict_status=0
conflict_output="$(gamebox_ai_rules_ensure_link "$conflict_root" "$primary_root" 2>&1)" \
  || conflict_status=$?
[[ "$conflict_status" -eq 1 ]]
grep -F 'refusing to replace non-symlink AI rules path' <<<"$conflict_output" >/dev/null

other_rules="$fixture_root/other-rules"
mkdir -p "$other_rules"
symlink_conflict_root="$fixture_root/symlink-conflict"
mkdir -p "$symlink_conflict_root/.ai"
ln -s "$other_rules" "$symlink_conflict_root/.ai/rules"
symlink_status=0
symlink_output="$(gamebox_ai_rules_ensure_link "$symlink_conflict_root" "$primary_root" 2>&1)" \
  || symlink_status=$?
[[ "$symlink_status" -eq 1 ]]
grep -F 'refusing to replace AI rules link' <<<"$symlink_output" >/dev/null

parent_target="$fixture_root/parent-target"
parent_conflict_root="$fixture_root/parent-conflict"
mkdir -p "$parent_target" "$parent_conflict_root"
ln -s "$parent_target" "$parent_conflict_root/.ai"
parent_status=0
parent_output="$(gamebox_ai_rules_ensure_link "$parent_conflict_root" "$primary_root" 2>&1)" \
  || parent_status=$?
[[ "$parent_status" -eq 1 ]]
grep -F 'refusing unsafe AI rules parent path' <<<"$parent_output" >/dev/null
[[ ! -e "$parent_target/rules" ]]

printf 'PASS AI rules link fixtures\n'
