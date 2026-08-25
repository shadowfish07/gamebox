#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=tool/lib/check_output.sh
source "$root_dir/tool/lib/check_output.sh"
gamebox_test_output_init

godot_bin="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
test_script="${GODOT_TEST_SCRIPT:-res://test/run_tests.gd}"
watchdog_seconds="${GODOT_TEST_WATCHDOG_SECONDS:-20}"
godot_pid=""
phase_log_file=""

terminate_godot() {
	if [[ -z "$godot_pid" ]]; then
		return
	fi
	if kill -0 "$godot_pid" 2>/dev/null; then
		kill -TERM "$godot_pid" 2>/dev/null || true
		for _ in 1 2 3; do
			if ! kill -0 "$godot_pid" 2>/dev/null; then
				break
			fi
			sleep 1
		done
		if kill -0 "$godot_pid" 2>/dev/null; then
			kill -KILL "$godot_pid" 2>/dev/null || true
		fi
	fi
	wait "$godot_pid" 2>/dev/null || true
	godot_pid=""
}

cleanup() {
	terminate_godot
	if [[ -n "$phase_log_file" ]]; then
		rm -f -- "$phase_log_file"
	fi
	gamebox_test_output_cleanup
}
trap cleanup EXIT

if ! [[ "$watchdog_seconds" =~ ^[1-9][0-9]*$ ]]; then
	echo "Invalid GODOT_TEST_WATCHDOG_SECONDS" >&2
	exit 2
fi

run_godot_with_watchdog() {
	local phase_name="$1"
	shift
	phase_log_file="$(mktemp -t gamebox-godot-phase.XXXXXX)"
	"$godot_bin" "$@" >"$phase_log_file" 2>&1 &
	godot_pid=$!
	local elapsed_seconds=0
	while kill -0 "$godot_pid" 2>/dev/null; do
		if (( elapsed_seconds >= watchdog_seconds )); then
			printf '%s exceeded %ss watchdog\n' "$phase_name" "$watchdog_seconds" >&2
			terminate_godot
			cat "$phase_log_file" >&2
			rm -f -- "$phase_log_file"
			phase_log_file=""
			return 1
		fi
		sleep 1
		elapsed_seconds=$((elapsed_seconds + 1))
	done

	local godot_status=0
	if wait "$godot_pid"; then
		godot_status=0
	else
		godot_status=$?
	fi
	godot_pid=""
	cat "$phase_log_file"
	rm -f -- "$phase_log_file"
	phase_log_file=""
	return "$godot_status"
}

run_godot_phase() {
	local phase_name="$1"
	local required_marker="$2"
	shift 2
	local output_file phase_status=0
	output_file="$(mktemp -t gamebox-godot-output.XXXXXX)"
	if run_godot_with_watchdog "$phase_name" "$@" >"$output_file" 2>&1; then
		phase_status=0
	else
		phase_status=$?
	fi
	cat "$output_file"
	if (( phase_status != 0 )); then
		rm -f -- "$output_file"
		return "$phase_status"
	fi
	if grep -Eq '^ERROR:|SCRIPT ERROR:|Parse Error:|Compile Error:|Failed to load script|Invalid call\.' "$output_file"; then
		printf '%s emitted fatal script diagnostics\n' "$phase_name" >&2
		rm -f -- "$output_file"
		return 1
	fi
	if [[ -n "$required_marker" ]] && ! grep -Fxq "$required_marker" "$output_file"; then
		printf '%s success marker is missing\n' "$phase_name" >&2
		rm -f -- "$output_file"
		return 1
	fi
	rm -f -- "$output_file"
}

gamebox_run_step "Godot resource import" run_godot_phase \
	"Godot resource import" "" --headless --editor --path game_runtime --import
gamebox_run_step "Godot tests" run_godot_phase \
	"Godot tests" "GAMEBOX_GODOT_TESTS_PASSED" \
	--headless --path game_runtime --script "$test_script"

gamebox_test_output_finish godot-tests
