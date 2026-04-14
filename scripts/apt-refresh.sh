#!/usr/bin/env bash
set -euo pipefail

# Ensure apt operations run non-interactively under timers/services.
export DEBIAN_FRONTEND=noninteractive

# Refresh package metadata and wait briefly if another apt consumer holds the lock.
main() {
  apt-get update -o DPkg::Lock::Timeout=600
}

main "$@"
