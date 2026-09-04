#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"

verbose=false
screenshot_path=""
godot_args=()
while (( $# > 0 )); do
	case "$1" in
		--verbose)
			verbose=true
			shift
			;;
		--screenshot)
			if (( $# < 2 )); then
				printf 'Expected a value after --screenshot\n' >&2
				exit 2
			fi
			screenshot_path="$2"
			godot_args+=("$1" "$2")
			shift 2
			;;
		*)
			godot_args+=("$1")
			shift
			;;
	 esac
done

if [[ ! -x "$GODOT_BIN" ]]; then
	printf 'Godot 4 executable not found: %s\n' "$GODOT_BIN" >&2
	exit 1
fi

readonly log_file="$(mktemp "${TMPDIR:-/tmp}/gamebox-flight-chess-preview.log.XXXXXX")"
trap 'rm -f "$log_file"' EXIT

command=(
	"$GODOT_BIN"
	--path "$ROOT/game_runtime"
	--script "$ROOT/tool/flight_chess_preview.gd"
	--rendering-driver opengl3
	-- "${godot_args[@]}"
)

set +e
if [[ "$verbose" == true ]]; then
	"${command[@]}" 2>&1 | tee "$log_file"
	status=${PIPESTATUS[0]}
else
	"${command[@]}" >"$log_file" 2>&1
	status=$?
fi
set -e

if (( status != 0 )); then
	printf 'FAIL flight-chess-preview (Godot render)\n' >&2
	if [[ "$verbose" == false ]]; then
		sed -n '1,$p' "$log_file" >&2
	fi
	exit "$status"
fi

warning_count="$(rg -c 'WARNING:|WARN' "$log_file" || true)"
warning_count="${warning_count:-0}"
artifact="${screenshot_path:-interactive window}"
full_game_summary="$(rg '^GAMEBOX_FLIGHT_CHESS_FULL_GAME ' "$log_file" | tail -n 1 || true)"
if [[ -n "$full_game_summary" ]]; then
	full_game_summary="${full_game_summary#GAMEBOX_FLIGHT_CHESS_FULL_GAME }"
	printf 'PASS flight-chess-preview (%s, artifact=%s, warnings=%s)\n' "$full_game_summary" "$artifact" "$warning_count"
else
	printf 'PASS flight-chess-preview (artifact=%s, warnings=%s)\n' "$artifact" "$warning_count"
fi
