#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
test_script="${GODOT_TEST_SCRIPT:-res://test/run_tests.gd}"
watchdog_seconds="${GODOT_TEST_WATCHDOG_SECONDS:-20}"
log_file="$(mktemp -t gamebox-godot-tests.XXXXXX)"
godot_pid=""

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
	rm -f "$log_file"
}
trap cleanup EXIT

if ! [[ "$watchdog_seconds" =~ ^[1-9][0-9]*$ ]]; then
	echo "Invalid GODOT_TEST_WATCHDOG_SECONDS" >&2
	exit 2
fi

"$godot_bin" --headless --path game_runtime --script "$test_script" >"$log_file" 2>&1 &
godot_pid=$!
elapsed_seconds=0
while kill -0 "$godot_pid" 2>/dev/null; do
	if (( elapsed_seconds >= watchdog_seconds )); then
		echo "Godot test runner exceeded ${watchdog_seconds}s watchdog" >&2
		terminate_godot
		cat "$log_file"
		exit 1
	fi
	sleep 1
	elapsed_seconds=$((elapsed_seconds + 1))
done

if wait "$godot_pid"; then
	godot_status=0
else
	godot_status=$?
fi
godot_pid=""
cat "$log_file"

if (( godot_status != 0 )); then
	echo "Godot test runner exited with status ${godot_status}" >&2
	exit 1
fi
if grep -Eq '^ERROR:|SCRIPT ERROR:|Parse Error:|Compile Error:|Failed to load script|Invalid call\.' "$log_file"; then
	echo "Godot emitted fatal script diagnostics" >&2
	exit 1
fi
if ! grep -Fxq 'GAMEBOX_GODOT_TESTS_PASSED' "$log_file"; then
	echo "Godot test success marker is missing" >&2
	exit 1
fi
