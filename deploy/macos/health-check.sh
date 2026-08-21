#!/bin/zsh
set -euo pipefail

readonly local_url="${GAMEBOX_LOCAL_HEALTH_URL:-http://127.0.0.1:18080/healthz}"
readonly public_url="${GAMEBOX_PUBLIC_HEALTH_URL:-https://gamebox.zqydev.me/healthz}"
readonly expected='{"status":"ok"}'

check_health() {
  local name="$1"
  local url="$2"
  local body

  body="$(/usr/bin/curl --fail --silent --show-error --max-time 10 "${url}")"
  if [[ "${body}" != "${expected}" ]]; then
    print -u2 -- "${name} health returned an unexpected response"
    return 1
  fi
}

check_health local "${local_url}"

if ! check_health public "${public_url}"; then
  public_host="${public_url#https://}"
  public_host="${public_host%%/*}"
  public_ip="$(/usr/bin/dig +short @1.1.1.1 "${public_host}" A | /usr/bin/head -n 1)"
  if [[ -z "${public_ip}" ]]; then
    print -u2 -- "public health hostname could not be resolved"
    exit 1
  fi
  public_body="$(/usr/bin/curl --fail --silent --show-error --max-time 10 \
    --resolve "${public_host}:443:${public_ip}" "${public_url}")"
  if [[ "${public_body}" != "${expected}" ]]; then
    print -u2 -- "public health returned an unexpected response"
    exit 1
  fi
fi
print -- "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ') local=ok public=ok"
