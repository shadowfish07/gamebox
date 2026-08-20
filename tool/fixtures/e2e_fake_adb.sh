#!/bin/sh
set -eu

: "${FAKE_ADB_LOG:?}"
: "${FAKE_DEVICE_ROOT:?}"

for argument in "$@"; do
  printf 'arg=%s\n' "$argument" >>"$FAKE_ADB_LOG"
done

last_argument=""
for argument in "$@"; do
  last_argument="$argument"
done
private_input_name="$(
  printf '%s\n' "$last_argument" \
    | sed -n 's/.*\(gamebox-e2e-input-[A-Za-z0-9_.-][A-Za-z0-9_.-]*\).*/\1/p'
)"

case " $* " in
  *' uiautomator dump '*)
    : >"$FAKE_DEVICE_ROOT/remote-ui.xml"
    exit 0
    ;;
  *' pull '*)
    if [ "${FAKE_ADB_MODE:-}" = "pull-fail" ]; then
      exit 1
    fi
    printf '<hierarchy/>\n' >"$last_argument"
    exit 0
    ;;
  *' rm -f -- /data/local/tmp/gamebox-e2e-'*)
    rm -f -- "$FAKE_DEVICE_ROOT/remote-ui.xml"
    printf 'remote-cleanup\n' >>"$FAKE_ADB_LOG"
    exit 0
    ;;
esac

case " $* " in
  *' run-as me.zqydev.gamebox.test '*cat*)
    cat >"$FAKE_DEVICE_ROOT/$private_input_name"
    chmod 600 "$FAKE_DEVICE_ROOT/$private_input_name"
    exit 0
    ;;
  *' run-as me.zqydev.gamebox.test '*'test ! -e'*)
    test ! -e "$FAKE_DEVICE_ROOT/$private_input_name"
    exit $?
    ;;
  *' run-as me.zqydev.gamebox.test '*'rm -f'*)
    rm -f -- "$FAKE_DEVICE_ROOT/$private_input_name"
    printf 'private-input-cleanup=%s\n' "$private_input_name" >>"$FAKE_ADB_LOG"
    exit 0
    ;;
esac

test_class=""
input_name=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-e" ] && [ "$#" -ge 3 ]; then
    case "$2" in
      class) test_class="$3" ;;
      gameboxTextInputName) input_name="$3" ;;
    esac
    shift 3
  else
    shift
  fi
done

case "$test_class" in
  *'#setApprovedFieldFromPrivateInputWithoutEchoingValue')
    if [ "${FAKE_ADB_MODE:-}" = "hang-instrument" ]; then
      printf '%s\n' "$$" >"${FAKE_ADB_PID_FILE:?}"
      trap '' TERM
      while :; do sleep 1; done
    fi
    rm -f -- "$FAKE_DEVICE_ROOT/$input_name"
    printf 'OK (1 test)\n'
    exit 0
    ;;
  *'#clearClipboardWithoutReadingIt')
    printf 'clipboard-clear\n' >>"$FAKE_ADB_LOG"
    printf 'OK (1 test)\n'
    exit 0
    ;;
esac

exit 0
