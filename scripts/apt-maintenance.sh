#!/usr/bin/env bash
set -euo pipefail

# Ensure apt operations run non-interactively under timers/services.
export DEBIAN_FRONTEND=noninteractive

# Refresh package metadata before any upgrade action.
update_package_index() {
  apt-get update
}

# Apply full distribution upgrades for non-security maintenance windows.
run_dist_upgrade() {
  apt-get -y dist-upgrade
}

# Clean up unneeded packages and stale cache artifacts.
cleanup_packages() {
  apt-get -y autoremove
  apt-get -y autoclean
}

# Main maintenance flow: refresh, upgrade, then clean.
main() {
  update_package_index
  run_dist_upgrade
  cleanup_packages
}

main "$@"
