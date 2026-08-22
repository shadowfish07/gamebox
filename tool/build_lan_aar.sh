#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
BUILD_ROOT="$ROOT_DIR/app/build"
readonly BUILD_ROOT

usage() {
	printf 'usage: %s OUTPUT_AAR\n' "$0" >&2
}

fail() {
	printf '%s\n' "$1" >&2
	exit 2
}

[[ $# -eq 1 ]] || {
	usage
	exit 2
}

output_argument="$1"
if [[ "$output_argument" == /* ]]; then
	requested_output="$output_argument"
else
	requested_output="$(pwd)/$output_argument"
fi

mkdir -p "$BUILD_ROOT"
build_root_physical="$(cd "$BUILD_ROOT" && pwd -P)"
case "$requested_output" in
	"$BUILD_ROOT"/*) relative_output="${requested_output#"$BUILD_ROOT"/}" ;;
	*) fail "OUTPUT_AAR must be under $BUILD_ROOT" ;;
esac

output_name="${relative_output##*/}"
[[ -n "$output_name" && "$output_name" != . && "$output_name" != .. ]] || fail "OUTPUT_AAR must name an AAR file"
parent_relative="${relative_output%/*}"
if [[ "$parent_relative" == "$relative_output" ]]; then
	parent_relative=""
fi

output_directory="$build_root_physical"
if [[ -n "$parent_relative" ]]; then
	IFS='/' read -r -a path_components <<<"$parent_relative"
	for component in "${path_components[@]}"; do
		[[ -n "$component" && "$component" != . && "$component" != .. ]] || fail "OUTPUT_AAR must not contain relative path traversal"
		candidate_directory="$output_directory/$component"
		if [[ -e "$candidate_directory" || -L "$candidate_directory" ]]; then
			[[ -d "$candidate_directory" ]] || fail "OUTPUT_AAR parent is not a directory: $candidate_directory"
			output_directory="$(cd "$candidate_directory" && pwd -P)"
			case "$output_directory" in
				"$build_root_physical"|"$build_root_physical"/*) ;;
				*) fail "OUTPUT_AAR must not traverse outside $BUILD_ROOT" ;;
			esac
		else
			mkdir "$candidate_directory"
			output_directory="$candidate_directory"
		fi
	done
fi

output_path="$output_directory/$output_name"
temporary_output="$(mktemp "$output_directory/.${output_name}.XXXXXX.aar")"
cleanup() {
	rm -f "$temporary_output"
}
trap cleanup EXIT

(
	cd "$ROOT_DIR/server"
	go tool gomobile init
	go tool gomobile bind \
		-target=android/arm,android/arm64,android/amd64 \
		-androidapi=24 \
		-trimpath \
		-o "$temporary_output" \
		./mobile/lanengine
)

aar_entries="$(unzip -Z1 "$temporary_output")"
if [[ "$(grep -Fxc 'classes.jar' <<<"$aar_entries")" != 1 ]]; then
	printf 'AAR must contain one classes.jar: %s\n' "$temporary_output" >&2
	exit 1
fi

expected_jni_entries=$'jni/arm64-v8a/libgojni.so\njni/armeabi-v7a/libgojni.so\njni/x86_64/libgojni.so'
actual_jni_entries="$(grep '^jni/' <<<"$aar_entries" | LC_ALL=C sort || true)"
if [[ "$actual_jni_entries" != "$expected_jni_entries" ]]; then
	printf 'AAR JNI entries were [%s], expected exactly [%s].\n' "$actual_jni_entries" "$expected_jni_entries" >&2
	exit 1
fi

mv -f "$temporary_output" "$output_path"
trap - EXIT
