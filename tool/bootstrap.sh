#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
SELF_TEST_FIXTURE_ROOT=""

usage() {
	printf 'usage: %s [--build-only|--self-test]\n' "$0" >&2
}

run_self_test() {
	local fixture_root fake_bin fake_sdk fake_tool build_output default_output
	local build_status default_status invalid_status tool_name
	fixture_root="$(mktemp -d -t gamebox-bootstrap.XXXXXX)"
	SELF_TEST_FIXTURE_ROOT="$fixture_root"
	fake_bin="$fixture_root/bin"
	fake_sdk="$fixture_root/android-sdk"
	mkdir -p "$fake_bin" "$fake_sdk/platforms/android-36"
	fake_tool="$fake_bin/fake-tool"
	# shellcheck disable=SC2016 # The fixture script expands these at execution time.
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		'set -euo pipefail' \
		'case "${0##*/}" in' \
		'  flutter)' \
		'    if [[ "${1:-}" == "--version" ]]; then printf "Waiting for another flutter command to release the startup lock...\\nFlutter 3.47.1 fixture\\n"; else printf "All Android licenses accepted.\\n"; fi' \
		'    ;;' \
		'  dart) printf "Dart SDK version: 3.13.1 (stable)\\n" ;;' \
		'  go) printf "go version go1.25.0 fixture/amd64\\n" ;;' \
		'  java) printf "openjdk version \\x2217.0.1\\x22 fixture\\n" >&2 ;;' \
		'  godot) printf "4.7.stable.fixture\\n" ;;' \
		'  *) exit 99 ;;' \
		'esac' >"$fake_tool"
	chmod +x "$fake_tool"
	for tool_name in flutter dart go java godot; do
		ln -s fake-tool "$fake_bin/$tool_name"
	done

	build_status=0
	build_output="$(env PATH="$fake_bin:/usr/bin:/bin" ANDROID_SDK_ROOT="$fake_sdk" GODOT_BIN="$fake_bin/godot" \
		bash "$ROOT_DIR/tool/bootstrap.sh" --build-only 2>&1)" || build_status=$?
	if (( build_status != 0 )); then
		printf 'Build-only bootstrap failed without adb/emulator:\n%s\n' "$build_output" >&2
		return 1
	fi
	if grep -Eq 'MISSING: (adb|emulator)' <<<"$build_output"; then
		printf 'Build-only bootstrap unexpectedly checked adb/emulator:\n%s\n' "$build_output" >&2
		return 1
	fi

	default_status=0
	default_output="$(env PATH="$fake_bin:/usr/bin:/bin" ANDROID_SDK_ROOT="$fake_sdk" GODOT_BIN="$fake_bin/godot" \
		bash "$ROOT_DIR/tool/bootstrap.sh" 2>&1)" || default_status=$?
	if (( default_status == 0 )) || ! grep -Fq 'MISSING: adb' <<<"$default_output" || ! grep -Fq 'MISSING: emulator' <<<"$default_output"; then
		printf 'Default bootstrap did not require both adb and emulator:\n%s\n' "$default_output" >&2
		return 1
	fi

	invalid_status=0
	env PATH="$fake_bin:/usr/bin:/bin" bash "$ROOT_DIR/tool/bootstrap.sh" --build-only unexpected >/dev/null 2>&1 || invalid_status=$?
	if (( invalid_status != 2 )); then
		printf 'Bootstrap invalid arguments exited %s instead of 2.\n' "$invalid_status" >&2
		return 1
	fi

	for tool_name in flutter dart go java godot; do
		rm -f "$fake_bin/$tool_name"
	done
	rm -f "$fake_tool"
	rmdir "$fake_sdk/platforms/android-36" "$fake_sdk/platforms" "$fake_sdk" "$fake_bin" "$fixture_root"
	SELF_TEST_FIXTURE_ROOT=""
	printf 'Bootstrap build-only/default fixtures passed.\n'
}

cleanup_self_test() {
	if [[ -n "$SELF_TEST_FIXTURE_ROOT" && -d "$SELF_TEST_FIXTURE_ROOT" ]]; then
		find "$SELF_TEST_FIXTURE_ROOT" -type l -delete
		find "$SELF_TEST_FIXTURE_ROOT" -type f -delete
		find "$SELF_TEST_FIXTURE_ROOT" -depth -type d -exec rmdir {} + 2>/dev/null || true
	fi
}

mode=full
case "${1:-}" in
	"")
		[[ $# -eq 0 ]] || { usage; exit 2; }
		;;
	--build-only)
		[[ $# -eq 1 ]] || { usage; exit 2; }
		mode=build-only
		;;
	--self-test)
		[[ $# -eq 1 ]] || { usage; exit 2; }
		trap cleanup_self_test EXIT
		run_self_test
		exit 0
		;;
	*)
		usage
		exit 2
		;;
esac

failures=0

ok() {
	echo "OK: $1"
}

missing() {
	echo "MISSING: $1"
	echo "  $2"
	failures=1
}

version_matches() {
	local command_name="$1"
	local expected="$2"
	local actual="$3"

	if [[ "$actual" == "$expected" ]]; then
		ok "$command_name $actual"
	else
		missing "$command_name $expected required (found ${actual:-not installed})" "$4"
	fi
}

if command -v flutter >/dev/null 2>&1; then
	if flutter_output="$(flutter --version 2>&1)"; then
		flutter_version_line="$(printf '%s\n' "$flutter_output" | sed -n '/^Flutter[[:space:]][0-9]/{p;q;}')"
		if [[ "$flutter_version_line" =~ ^Flutter[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+) ]]; then
			flutter_version="${BASH_REMATCH[1]}"
			if [[ "$flutter_version" == "3.47.1" ]]; then
				ok "Flutter $flutter_version"
			else
				missing "Flutter 3.47.1 required (found $flutter_version)" "Install Flutter 3.47.1 and put flutter on PATH."
			fi
		else
			missing "Flutter 3.47.1 required (version could not be parsed)" "Install Flutter 3.47.1 and put flutter on PATH."
		fi
	else
		missing "Flutter 3.47.1 required (flutter --version failed)" "Install Flutter 3.47.1 and put flutter on PATH."
	fi
else
	missing "Flutter 3.47.1" "Install Flutter 3.47.1 and put flutter on PATH."
fi

if command -v dart >/dev/null 2>&1; then
	if dart_output="$(dart --version 2>&1)"; then
		if [[ "$dart_output" =~ Dart[[:space:]]SDK[[:space:]]version:[[:space:]]([0-9]+)\.([0-9]+) ]]; then
			dart_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
			version_matches "Dart" "3.13" "$dart_version" "Use the Dart 3.13 SDK bundled with Flutter 3.47.1."
		else
			missing "Dart 3.13 required (version could not be parsed)" "Use the Dart 3.13 SDK bundled with Flutter 3.47.1."
		fi
	else
		missing "Dart 3.13 required (dart --version failed)" "Use the Dart 3.13 SDK bundled with Flutter 3.47.1."
	fi
else
	missing "Dart 3.13" "Install Flutter 3.47.1, which includes Dart 3.13."
fi

if command -v go >/dev/null 2>&1; then
	if go_output="$(go version 2>&1)"; then
		if [[ "$go_output" =~ ^go[[:space:]]version[[:space:]]go([0-9]+)\.([0-9]+) ]]; then
			go_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
			version_matches "Go" "1.25" "$go_version" "Install Go 1.25 and put go on PATH."
		else
			missing "Go 1.25 required (version could not be parsed)" "Install Go 1.25 and put go on PATH."
		fi
	else
		missing "Go 1.25 required (go version failed)" "Install Go 1.25 and put go on PATH."
	fi
else
	missing "Go 1.25" "Install Go 1.25 and put go on PATH."
fi

godot_bin="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
if [[ -x "$godot_bin" ]]; then
	if godot_output="$("$godot_bin" --version 2>&1)"; then
		if [[ "$godot_output" =~ ^([0-9]+)\.([0-9]+) ]]; then
			godot_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
			version_matches "Godot" "4.7" "$godot_version" "Install Godot 4.7 or set GODOT_BIN to its executable."
		else
			missing "Godot 4.7 required (version could not be parsed)" "Install Godot 4.7 or set GODOT_BIN to its executable."
		fi
	else
		missing "Godot 4.7 required (Godot --version failed)" "Install Godot 4.7 or set GODOT_BIN to its executable."
	fi
else
	missing "Godot 4.7" "Install Godot 4.7 at /Applications/Godot.app or set GODOT_BIN."
fi

if command -v java >/dev/null 2>&1; then
	if java_output="$(java -version 2>&1)"; then
		if [[ "$java_output" =~ version[[:space:]]\"([0-9]+) ]]; then
			java_version="${BASH_REMATCH[1]}"
			if (( java_version >= 17 )); then
				ok "JDK $java_version"
			else
				missing "JDK 17+ (found $java_version)" "Install JDK 17 or newer and put java on PATH."
			fi
		else
			missing "JDK 17+ (version could not be parsed)" "Install JDK 17 or newer and put java on PATH."
		fi
	else
		missing "JDK 17+ (java -version failed)" "Install JDK 17 or newer and put java on PATH."
	fi
else
	missing "JDK 17+" "Install JDK 17 or newer and put java on PATH."
fi

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/Users/${USER}/Library/Android/sdk}}"
if [[ -d "$sdk_root/platforms/android-36" ]]; then
	ok "Android SDK platform 36 ($sdk_root)"
else
	missing "Android SDK platform 36" "Install platform 36 with: sdkmanager --install 'platforms;android-36' (SDK: $sdk_root)."
fi

if [[ "$mode" == full ]]; then
	if command -v adb >/dev/null 2>&1; then
		ok "adb ($(command -v adb))"
	else
		missing "adb" "Install Android SDK platform-tools and add it to PATH."
	fi

	if command -v emulator >/dev/null 2>&1; then
		ok "emulator ($(command -v emulator))"
	else
		missing "emulator" "Install Android SDK emulator tools and add them to PATH."
	fi
fi

if command -v flutter >/dev/null 2>&1; then
	flutter_doctor="$(flutter doctor -v 2>&1 || true)"
	if printf '%s\n' "$flutter_doctor" | grep -Fq "All Android licenses accepted."; then
		ok "accepted Android SDK licenses"
	else
		missing "accepted Android SDK licenses" "Run: yes | flutter doctor --android-licenses"
	fi
else
	missing "accepted Android SDK licenses" "Install Flutter, then run: yes | flutter doctor --android-licenses"
fi

if (( failures )); then
	exit 1
fi
