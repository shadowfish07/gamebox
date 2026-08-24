#!/usr/bin/env bash
set -euo pipefail

readonly root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly production_script="${root_dir}/deploy/macos/install.sh"
readonly staging_script="${root_dir}/deploy/macos/install-staging.sh"
readonly service_prefix_reference='${service_prefix}'

production_prefix_line="$(grep '^readonly service_prefix=' "${production_script}")"
staging_prefix_line="$(grep '^readonly service_prefix=' "${staging_script}")"

[[ -n "${production_prefix_line}" && -n "${staging_prefix_line}" ]] \
  || { printf 'macOS deploy prefix declarations are missing\n' >&2; exit 1; }
[[ "${production_prefix_line}" != "${staging_prefix_line}" ]] \
  || { printf 'staging deployment reuses the production executable prefix\n' >&2; exit 1; }
[[ "${staging_prefix_line}" == 'readonly service_prefix="${HOME}/.local/libexec/gamebox-staging"' ]] \
  || { printf 'staging executable prefix is not isolated\n' >&2; exit 1; }

for artifact in gameboxd gameboxctl run-server.sh health-check.sh backup.sh; do
  grep -F -- "\"${service_prefix_reference}/${artifact}\"" "${staging_script}" >/dev/null \
    || { printf 'staging installer does not install %s under its service prefix\n' "${artifact}" >&2; exit 1; }
done

printf 'macOS deployment prefix isolation contract passed.\n'
