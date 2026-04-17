#!/usr/bin/env bash
set -euo pipefail

# Configuration and path defaults
ENV_FILE="/etc/ansible/pull.env"
BOOTSTRAP_VARS_FILE="/etc/ansible/bootstrap-vars.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper to print status with colors
status_msg() {
  local color="$1"
  local msg="$2"
  printf "${color}%-20s${NC} %s\n" "$msg" ""
}

# Check if the script is running with sufficient privileges
check_privileges() {
  if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)." >&2
    exit 1
  fi
}

# 1. Verify ansible-pull.timer is active and scheduled
check_timer() {
  echo "--- Checking ansible-pull timer ---"
  if systemctl is-active --quiet ansible-pull.timer; then
    status_msg "$GREEN" "[PASS]" "ansible-pull.timer is active."
  else
    status_msg "$RED" "[FAIL]" "ansible-pull.timer is NOT active."
    return 1
  fi

  if systemctl is-enabled --quiet ansible-pull.timer; then
    status_msg "$GREEN" "[PASS]" "ansible-pull.timer is enabled."
  else
    status_msg "$YELLOW" "[WARN]" "ansible-pull.timer is NOT enabled (it's running but won't persist across reboots)."
  fi
}

# 2. Verify the most recent run was successful
check_last_run() {
  echo ""
  echo "--- Checking last ansible-pull run ---"

  # We need to determine the log file path.
  # We try to source pull.env to get the correct LOG_DIR and HOSTNAME.
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1091
    # shellcheck source=/etc/ansible/pull.env
    source "$ENV_FILE"
    HOSTNAME_SHORT="$(hostname -s)"
    RUN_LOG="${LOG_DIR}/ansible-pull-${HOSTNAME_SHORT}.log"
  else
    echo "Error: Could not find $ENV_FILE to determine log location." >&2
    return 1
  fi

  if [[ ! -f "$RUN_LOG" ]]; then
    status_msg "$RED" "[FAIL]" "Log file not found at $RUN_LOG"
    return 1
  fi

  # Check the last line of the log for success or failure.
  # The run_ansible-pull.sh script logs "Completed ansible-pull run successfully." on success.
  if grep -q "Completed ansible-pull run successfully." "$RUN_LOG"; then
    status_msg "$GREEN" "[PASS]" "Last run was successful."
  else
    status_msg "$RED" "[FAIL]" "Last run failed or did not complete successfully."
    echo "Last log entry:"
    tail -n 5 "$RUN_LOG" | sed 's/^/  /'
    return 1
  fi
}

# 3. If AD enrollment is enabled, verify domain join
check_ad_status() {
  echo ""
  echo "--- Checking Active Directory status ---"

  # Check bootstrap-vars.yml for base_ad_enroll
  local ad_enabled="false"
  if [[ -f "$BOOTSTRAP_VARS_FILE" ]]; then
    if grep -q "base_ad_enroll: true" "$BOOTSTRAP_VARS_FILE"; then
      ad_enabled="true"
    fi
  fi

  if [[ "$ad_enabled" == "true" ]]; then
    # Check if the machine can resolve/talk to the domain via 'id' or 'realm'
    # We attempt to check if the local user can see domain users or if realm list works.
    if command -v realm >/dev/null 2>&1 && realm list | grep -q "\["; then
      status_msg "$GREEN" "[PASS]" "Machine is joined to Active Directory."
    elif id "hhmi.org" >/dev/null 2>&1; then
       status_msg "$GREEN" "[PASS]" "Machine is joined to Active Directory (verified via NSS/id)."
    else
      status_msg "$RED" "[FAIL]" "Machine is NOT joined to Active Directory (expected based on configuration)."
      return 1
    fi
  else
    status_msg "$YELLOW" "[SKIP]" "AD enrollment is not enabled for this machine."
  fi
}

main() {
  check_privileges

  local exit_code=0

  check_timer || exit_code=1
  check_last_run || exit_code=1
  check_ad_status || exit_code=1

  echo ""
  if [[ $exit_code -eq 0 ]]; then
    status_msg "$GREEN" "HEALTH CHECK PASSED"
  else
    status_msg "$RED" "HEALTH CHECK FAILED"
  fi

  exit $exit_code
}

main "$@"
