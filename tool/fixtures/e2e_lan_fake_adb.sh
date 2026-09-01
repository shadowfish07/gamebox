#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "devices -l")
    printf 'List of devices attached\nfixture-A device model:Pixel_7_Pro\nfixture-B device model:Pixel_7_Pro\n'
    ;;
  "-s fixture-A forward tcp:0 tcp:49321") printf '38117\n' ;;
  "-s fixture-A forward --remove tcp:38117") ;;
  "-s fixture-A get-state"|"-s fixture-B get-state") printf 'device\n' ;;
  *) printf 'fake adb rejected: %s\n' "$*" >&2; exit 64 ;;
esac
