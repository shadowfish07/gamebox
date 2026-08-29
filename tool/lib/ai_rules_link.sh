#!/usr/bin/env bash

if [[ -n "${GAMEBOX_AI_RULES_LINK_LOADED:-}" ]]; then
  return 0
fi
readonly GAMEBOX_AI_RULES_LINK_LOADED=1

gamebox_ai_rules_validate_source() {
  local source_dir="$1"
  local route
  for route in verification flutter android godot go ui-acceptance git; do
    [[ -f "$source_dir/$route/index.md" ]] || {
      printf 'Gamebox worktree: AI rules source is incomplete: %s\n' \
        "$source_dir/$route/index.md" >&2
      return 1
    }
  done
}

gamebox_ai_rules_resolve_source() {
  local primary_root="$1"
  local candidate=""
  local primary_link="$primary_root/.ai/rules"
  local primary_target=""
  local user_home="${HOME:-}"

  if [[ -n "${GAMEBOX_AI_RULES_DIR:-}" ]]; then
    candidate="$GAMEBOX_AI_RULES_DIR"
    [[ -d "$candidate" ]] || {
      printf 'Gamebox worktree: GAMEBOX_AI_RULES_DIR is not a directory: %s\n' \
        "$candidate" >&2
      return 1
    }
  elif [[ -L "$primary_link" ]]; then
    primary_target="$(readlink "$primary_link")"
    if [[ "$primary_target" == /* ]]; then
      candidate="$primary_target"
    else
      candidate="$primary_root/.ai/$primary_target"
    fi
    [[ -d "$candidate" ]] || {
      printf 'Gamebox worktree: primary AI rules link is stale: %s -> %s\n' \
        "$primary_link" "$primary_target" >&2
      return 1
    }
  elif [[ -n "$user_home" && -d "$user_home/git/ai-rules/rules" ]]; then
    candidate="$user_home/git/ai-rules/rules"
  else
    return 3
  fi

  candidate="$(cd "$candidate" && pwd -P)"
  gamebox_ai_rules_validate_source "$candidate" || return
  printf '%s\n' "$candidate"
}

gamebox_ai_rules_ensure_link() {
  local project_root="$1"
  local primary_root="$2"
  local source_dir=""
  local source_status=0
  local link_dir="$project_root/.ai"
  local link_path="$link_dir/rules"
  local existing_target=""
  local existing_resolved=""

  source_dir="$(gamebox_ai_rules_resolve_source "$primary_root")" || source_status=$?
  if ((source_status == 3)); then
    printf 'Gamebox worktree: shared AI rules unavailable; skipped local .ai/rules link\n'
    return 0
  fi
  ((source_status == 0)) || return "$source_status"

  if [[ -L "$link_dir" || (-e "$link_dir" && ! -d "$link_dir") ]]; then
    printf 'Gamebox worktree: refusing unsafe AI rules parent path: %s\n' \
      "$link_dir" >&2
    return 1
  fi
  if [[ -e "$link_path" && ! -L "$link_path" ]]; then
    printf 'Gamebox worktree: refusing to replace non-symlink AI rules path: %s\n' \
      "$link_path" >&2
    return 1
  fi
  if [[ -L "$link_path" ]]; then
    existing_target="$(readlink "$link_path")"
    existing_resolved="$(cd "$link_path" 2>/dev/null && pwd -P)" || {
      printf 'Gamebox worktree: existing AI rules link is stale: %s -> %s\n' \
        "$link_path" "$existing_target" >&2
      return 1
    }
    if [[ "$existing_resolved" != "$source_dir" ]]; then
      printf 'Gamebox worktree: refusing to replace AI rules link: %s -> %s (expected %s)\n' \
        "$link_path" "$existing_target" "$source_dir" >&2
      return 1
    fi
    printf 'Gamebox worktree: AI rules ready: %s -> %s\n' "$link_path" "$source_dir"
    return 0
  fi

  mkdir -p "$link_dir"
  ln -s "$source_dir" "$link_path"
  printf 'Gamebox worktree: linked AI rules: %s -> %s\n' "$link_path" "$source_dir"
}
