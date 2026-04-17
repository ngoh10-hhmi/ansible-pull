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
  local label="$2"
  local msg="${3:-}"
  printf "${color}%-20s${NC} %s\n" "$label" "$msg"
}

# Check if the script is running with sufficient privileges
check_privileges() {
  if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)." >&2
    exit 1
  fi
}

# 1. Verify ansible-pull.timer is active and enabled
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
  local last_status_line=""
  local last_status_text=""

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

  # Inspect only the most recent terminal status line from the wrapper rather
  # than any older success elsewhere in the logfile.
  last_status_line="$(
    grep -E "Completed ansible-pull run successfully\.|Completed ansible-pull run\.|ansible-pull run failed with exit code|Skipped ansible-pull run because another run is already in progress\." "$RUN_LOG" \
      | tail -n 1 || true
  )"

  if [[ -z "$last_status_line" ]]; then
    status_msg "$RED" "[FAIL]" "Could not determine the outcome of the most recent ansible-pull run."
    echo "Recent log lines:"
    tail -n 10 "$RUN_LOG" | sed 's/^/  /'
    return 1
  fi

  last_status_text="${last_status_line#*] }"

  case "$last_status_line" in
    *"Completed ansible-pull run successfully."*|*"Completed ansible-pull run."*)
      status_msg "$GREEN" "[PASS]" "Most recent run completed successfully."
      ;;
    *"Skipped ansible-pull run because another run is already in progress."*)
      status_msg "$YELLOW" "[WARN]" "Most recent invocation was skipped because another run held the lock."
      echo "Last status line:"
      printf '  %s\n' "$last_status_text"
      ;;
    *"ansible-pull run failed with exit code"*)
      status_msg "$RED" "[FAIL]" "Most recent run failed."
      echo "Last status line:"
      printf '  %s\n' "$last_status_text"
      return 1
      ;;
    *)
      status_msg "$RED" "[FAIL]" "Unrecognized ansible-pull terminal status."
      echo "Last status line:"
      printf '  %s\n' "$last_status_text"
      return 1
      ;;
  esac
}

check_realm_membership() {
  local realm_output=""

  if ! command -v realm >/dev/null 2>&1; then
    return 1
  fi

  realm_output="$(realm list 2>/dev/null || true)"
  grep -Eiq '(^|\s)(hhmi\.org|domain-name:[[:space:]]*hhmi\.org)($|\s)' <<<"$realm_output"
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
    if check_realm_membership; then
      status_msg "$GREEN" "[PASS]" "Machine reports an hhmi.org realm membership."
    else
      status_msg "$RED" "[FAIL]" "Machine does not appear to be joined to hhmi.org."
      return 1
    fi

    if systemctl is-active --quiet sssd; then
      status_msg "$GREEN" "[PASS]" "sssd is active."
    else
      status_msg "$RED" "[FAIL]" "sssd is not active."
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
