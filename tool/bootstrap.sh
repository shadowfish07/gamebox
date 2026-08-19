#!/usr/bin/env bash
set -euo pipefail

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
		if [[ "$flutter_output" =~ ^Flutter[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+) ]]; then
			flutter_version="${BASH_REMATCH[1]}"
			if [[ "$flutter_version" == "3.35.1" ]]; then
				ok "Flutter $flutter_version"
			else
				missing "Flutter 3.35.1 required (found $flutter_version)" "Install Flutter 3.35.1 and put flutter on PATH."
			fi
		else
			missing "Flutter 3.35.1 required (version could not be parsed)" "Install Flutter 3.35.1 and put flutter on PATH."
		fi
	else
		missing "Flutter 3.35.1 required (flutter --version failed)" "Install Flutter 3.35.1 and put flutter on PATH."
	fi
else
	missing "Flutter 3.35.1" "Install Flutter 3.35.1 and put flutter on PATH."
fi

if command -v dart >/dev/null 2>&1; then
	if dart_output="$(dart --version 2>&1)"; then
		if [[ "$dart_output" =~ Dart[[:space:]]SDK[[:space:]]version:[[:space:]]([0-9]+)\.([0-9]+) ]]; then
			dart_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
			version_matches "Dart" "3.9" "$dart_version" "Use the Dart 3.9 SDK bundled with Flutter 3.35.1."
		else
			missing "Dart 3.9 required (version could not be parsed)" "Use the Dart 3.9 SDK bundled with Flutter 3.35.1."
		fi
	else
		missing "Dart 3.9 required (dart --version failed)" "Use the Dart 3.9 SDK bundled with Flutter 3.35.1."
	fi
else
	missing "Dart 3.9" "Install Flutter 3.35.1, which includes Dart 3.9."
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
