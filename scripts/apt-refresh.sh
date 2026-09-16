#!/usr/bin/env bash
set -euo pipefail

# Ensure apt operations run non-interactively under timers/services.
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_LIB_DIR="/usr/local/lib/ansible-pull"

source_script_lib() {
  local filename="$1"
  local candidate=""

  for candidate in "${SCRIPT_DIR}/lib/${filename}" "${SHARED_LIB_DIR}/${filename}"; do
    if [[ -f "${candidate}" ]]; then
      # shellcheck disable=SC1090
      source "${candidate}"
      return 0
    fi
  done

  echo "Missing helper library ${filename}" >&2
  exit 1
}

source_script_lib "apt_lock.sh"

# Refresh package metadata. Acquire::Retries retries a transient fetch blip so a
# single momentary DNS/mirror hiccup self-heals within the run.
# APT::Update::Error-Mode=any makes apt-get exit non-zero when ANY source fails
# to refresh -- by default it exits 0 even when every index fetch fails, which
# would let metadata silently age while the unit's OnFailure Slack alert never
# fires.
#
# DPkg::Lock::Timeout does not cover the /var/lib/apt/lists/lock that
# "apt-get update" takes, so lock contention with a concurrent maintenance timer
# is handled by apt_get_with_lock_retry instead. The option stays because this
# helper can still contend for the dpkg lock behind the scenes.
main() {
  apt_get_with_lock_retry update \
    -o DPkg::Lock::Timeout=600 \
    -o Acquire::Retries=3 \
    -o APT::Update::Error-Mode=any
}

main "$@"
