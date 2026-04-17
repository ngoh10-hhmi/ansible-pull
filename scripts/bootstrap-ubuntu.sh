#!/usr/bin/env bash
set -euo pipefail

# Usage/help text for operators running first-time bootstrap.
usage() {
  cat <<'EOF'
Usage:
  bootstrap-ubuntu.sh --repo <repo-url> [--branch <branch>] [--playbook <path>]
                      [--github-user <username>]
                      [--github-token <token> | --github-token-file <path>]
                      [--slack-webhook <url>] [--slack-notify-success <true|false>]

Example:
  sudo ./bootstrap-ubuntu.sh \
    --repo https://github.com/example/ansible-pull.git \
    --branch main

Private repo later:
  sudo ./bootstrap-ubuntu.sh \
    --repo https://github.com/example/ansible-pull.git \
    --branch main \
    --github-user machine-reader \
    --github-token-file /root/github-read-token.txt

The script can also prompt for usernames that should be added to the local
`sudo` group during bootstrap after the AD enrollment converge.

Bootstrap requires joining the hhmi.org Active Directory domain. The script
will prompt for an AD username and hidden password before the domain-join
convergence run.

When Slack webhook notifications are configured, failed runs can include the
wrapper phase, last detected Ansible task, and a short error excerpt.
EOF
}

# Emit a fatal error message and stop execution.
die() {
  echo "$*" >&2
  exit 1
}

# Default bootstrap configuration and optional credential inputs.
REPO_URL=""
BRANCH="main"
PLAYBOOK="playbooks/workstation.yml"
DEST="/var/lib/ansible-pull"
LOG_DIR="/var/log/ansible-pull"
BOOTSTRAP_VARS_FILE="/etc/ansible/bootstrap-vars.yml"
INSTALLED_LIB_DIR="/usr/local/lib/ansible-pull"
GITHUB_USER=""
GITHUB_TOKEN=""
GITHUB_TOKEN_FILE=""
SHORT_HOSTNAME=""
MACHINE_TYPE=""
SUDO_USERS=()
# These are consumed by the shared env-file helper when bootstrap writes
# /etc/ansible/pull.env.
# shellcheck disable=SC2034
SLACK_WEBHOOK_URL=""
SLACK_NOTIFY_SUCCESS="false"
BOOTSTRAP_PHASE="starting"
FINAL_STATE_WRITTEN="false"
AD_CONVERGE_SUCCEEDED="false"
BOOTSTRAP_LIBS_LOADED="false"

# Parse CLI arguments into global script settings.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        REPO_URL="${2:-}"
        shift 2
        ;;
      --branch)
        BRANCH="${2:-}"
        shift 2
        ;;
      --playbook)
        PLAYBOOK="${2:-}"
        shift 2
        ;;
      --github-user)
        GITHUB_USER="${2:-}"
        shift 2
        ;;
      --github-token)
        GITHUB_TOKEN="${2:-}"
        shift 2
        ;;
      --github-token-file)
        GITHUB_TOKEN_FILE="${2:-}"
        shift 2
        ;;
      --slack-webhook)
        SLACK_WEBHOOK_URL="${2:-}"
        shift 2
        ;;
      --slack-notify-success)
        SLACK_NOTIFY_SUCCESS="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

# Validate execution context (root, required args, and Ubuntu OS).
validate_prerequisites() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script with sudo or as root."
  fi

  if [[ -z "${REPO_URL}" ]]; then
    echo "--repo is required." >&2
    usage
    exit 1
  fi

  if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect operating system."
  fi

  # shellcheck disable=SC1091
  # shellcheck source=/etc/os-release
  source /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    die "This bootstrap script currently supports Ubuntu only."
  fi
}

# Install baseline dependencies needed before first ansible-pull run.
install_bootstrap_dependencies() {
  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y \
    ansible \
    ca-certificates \
    curl \
    git \
    python3 \
    python3-apt
}

# Create local runtime directories used by ansible-pull and logging.
prepare_runtime_directories() {
  install -d -m 0755 /etc/ansible "${DEST}" "${LOG_DIR}"
}

# Configure optional GitHub credentials for private-repo pulls.
configure_git_credentials() {
  if [[ -n "${GITHUB_TOKEN}" && -n "${GITHUB_TOKEN_FILE}" ]]; then
    die "Use either --github-token or --github-token-file, not both."
  fi

  if [[ -n "${GITHUB_TOKEN_FILE}" ]]; then
    if [[ ! -f "${GITHUB_TOKEN_FILE}" ]]; then
      die "Token file does not exist: ${GITHUB_TOKEN_FILE}"
    fi
    GITHUB_TOKEN="$(tr -d '\r\n' < "${GITHUB_TOKEN_FILE}")"
  fi

  if [[ -n "${GITHUB_USER}" || -n "${GITHUB_TOKEN}" ]]; then
    if [[ -z "${GITHUB_USER}" || -z "${GITHUB_TOKEN}" ]]; then
      die "--github-user and a token source must be provided together."
    fi

    cat > /root/.git-credentials-ansible-pull <<EOF
https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com
EOF
    chmod 0600 /root/.git-credentials-ansible-pull
    git config --global credential.helper "store --file /root/.git-credentials-ansible-pull"
  fi
}

# Write the environment file consumed by the ansible-pull wrapper, including
# Slack settings for failure summaries and optional success notifications.
write_pull_environment() {
  if [[ "${BOOTSTRAP_LIBS_LOADED}" != "true" ]]; then
    die "Bootstrap helper libraries are not loaded yet."
  fi

  : "${SLACK_WEBHOOK_URL}" "${SLACK_NOTIFY_SUCCESS}"
  write_pull_env_file /etc/ansible/pull.env
  load_env_file /etc/ansible/pull.env
  validate_pull_env
}

source_checkout_libs() {
  local lib_dir="${DEST}/scripts/lib"

  if [[ ! -f "${lib_dir}/envfile.sh" || ! -f "${lib_dir}/git_sync.sh" ]]; then
    die "Missing helper libraries in ${lib_dir} after checkout."
  fi

  # shellcheck disable=SC1090
  # shellcheck source=/dev/null
  source "${lib_dir}/envfile.sh"
  # shellcheck disable=SC1090
  # shellcheck source=/dev/null
  source "${lib_dir}/git_sync.sh"
  BOOTSTRAP_LIBS_LOADED="true"
}

# Ensure a local checkout exists and is synced to the requested branch.
sync_repository_checkout() {
  if [[ -f "${DEST}/scripts/lib/git_sync.sh" ]]; then
    source_checkout_libs
    # The first bootstrap on a brand-new machine is often run from a single
    # downloaded bootstrap script, so this shared helper is only available
    # once a checkout already exists.
    sync_checkout_or_clone "${DEST}" "${REPO_URL}" "${BRANCH}" "1"
    return
  fi

  if [[ -d "${DEST}/.git" ]]; then
    if git -C "${DEST}" remote get-url origin >/dev/null 2>&1; then
      git -C "${DEST}" remote set-url origin "${REPO_URL}"
    else
      git -C "${DEST}" remote add origin "${REPO_URL}"
    fi
    git -C "${DEST}" fetch --prune origin "${BRANCH}"
    git -C "${DEST}" checkout -B "${BRANCH}" "origin/${BRANCH}"
    git -C "${DEST}" reset --hard "origin/${BRANCH}"
    git -C "${DEST}" clean -fdx
  else
    rm -rf "${DEST}"
    # --depth 1 fetches only the latest commit so the initial clone is fast
    # and uses minimal disk space. The installed runtime wrapper uses the
    # shared git sync helper after bootstrap completes.
    git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${DEST}"
  fi
}

write_bootstrap_file() {
  local tmp_file
  tmp_file="$(mktemp)"
  cat > "${tmp_file}"
  install -m 0600 "${tmp_file}" "${BOOTSTRAP_VARS_FILE}"
  rm -f "${tmp_file}"
}

write_bootstrap_vars_initial_state() {
  write_bootstrap_file <<EOF
base_ansible_pull_repo_url: "${REPO_URL}"
base_ansible_pull_branch: "${BRANCH}"
base_ansible_pull_playbook: "${PLAYBOOK}"
base_ansible_pull_directory: "${DEST}"
base_ansible_pull_log_dir: "${LOG_DIR}"
target_hostname: "${SHORT_HOSTNAME}"
machine_type: "${MACHINE_TYPE}"
base_ad_enroll: false
EOF
}

write_bootstrap_vars_ad_phase_state() {
  local sudo_users_yaml=""
  local sudo_user=""

  if [[ "${#SUDO_USERS[@]}" -gt 0 ]]; then
    sudo_users_yaml=$'base_manage_bootstrap_sudo_users: true\nbase_bootstrap_sudo_users:'
    for sudo_user in "${SUDO_USERS[@]}"; do
      sudo_users_yaml+=$'\n'"  - ${sudo_user}"
    done
  fi

  write_bootstrap_file <<EOF
base_ansible_pull_repo_url: "${REPO_URL}"
base_ansible_pull_branch: "${BRANCH}"
base_ansible_pull_playbook: "${PLAYBOOK}"
base_ansible_pull_directory: "${DEST}"
base_ansible_pull_log_dir: "${LOG_DIR}"
target_hostname: "${SHORT_HOSTNAME}"
machine_type: "${MACHINE_TYPE}"
base_ad_enroll: true
${sudo_users_yaml}
EOF
}

write_bootstrap_vars_final_state() {
  write_bootstrap_file <<EOF
base_ansible_pull_repo_url: "${REPO_URL}"
base_ansible_pull_branch: "${BRANCH}"
base_ansible_pull_playbook: "${PLAYBOOK}"
base_ansible_pull_directory: "${DEST}"
base_ansible_pull_log_dir: "${LOG_DIR}"
target_hostname: "${SHORT_HOSTNAME}"
machine_type: "${MACHINE_TYPE}"
base_ad_enroll: true
EOF
}

mark_final_state_written() {
  FINAL_STATE_WRITTEN="true"
}

cleanup_bootstrap_state_on_exit() {
  local exit_code=$?

  if [[ "${FINAL_STATE_WRITTEN}" == "true" ]]; then
    return "${exit_code}"
  fi

  if [[ -z "${REPO_URL}" || -z "${BRANCH}" || -z "${PLAYBOOK}" || -z "${DEST}" || -z "${LOG_DIR}" || -z "${SHORT_HOSTNAME}" || -z "${MACHINE_TYPE}" ]]; then
    return "${exit_code}"
  fi

  case "${BOOTSTRAP_PHASE}" in
    ad_phase|post_ad_converge|enable_timer)
      if [[ "${AD_CONVERGE_SUCCEEDED}" == "true" ]]; then
        write_bootstrap_vars_final_state || true
      else
        write_bootstrap_vars_initial_state || true
      fi
      ;;
  esac

  return "${exit_code}"
}

# Install the wrapper script and its shared helper libraries into the expected
# system paths. The final bootstrap upgrade is intentional because bootstrap is
# normally run on freshly imaged HHMI systems that should be brought current
# immediately rather than treated like arbitrary long-lived BYOD installs.
install_runtime_support() {
  install -d -m 0755 "${INSTALLED_LIB_DIR}"

  for helper in envfile.sh git_sync.sh; do
    if [[ ! -f "${DEST}/scripts/lib/${helper}" ]]; then
      die "Missing ${DEST}/scripts/lib/${helper} after initial clone."
    fi
    install -m 0644 "${DEST}/scripts/lib/${helper}" "${INSTALLED_LIB_DIR}/${helper}"
  done

  if [[ ! -f "${DEST}/scripts/run-ansible-pull.sh" ]]; then
    die "Missing ${DEST}/scripts/run-ansible-pull.sh after initial clone."
  fi

  install -m 0755 "${DEST}/scripts/run-ansible-pull.sh" /usr/local/sbin/run-ansible-pull
}

# Prompt for machine identity metadata used by the Ansible role.
prompt_machine_identity() {
  local current_short_hostname
  current_short_hostname="$(hostname -s 2>/dev/null || true)"

  while true; do
    if [[ -n "${current_short_hostname}" ]]; then
      read -r -p "Enter short hostname (max 15 chars, without .hhmi.org) [${current_short_hostname}]: " SHORT_HOSTNAME
      SHORT_HOSTNAME="${SHORT_HOSTNAME:-${current_short_hostname}}"
    else
      read -r -p "Enter short hostname (max 15 chars, without .hhmi.org): " SHORT_HOSTNAME
    fi

    if [[ ${#SHORT_HOSTNAME} -gt 15 ]]; then
      echo "Error: Hostname exceeds 15 characters. Please try again."
    elif [[ -z "${SHORT_HOSTNAME}" ]]; then
      echo "Error: Hostname cannot be empty."
    else
      break
    fi
  done

  while true; do
    read -r -p "Machine type (laptop/desktop): " MACHINE_TYPE
    if [[ "${MACHINE_TYPE}" == "laptop" || "${MACHINE_TYPE}" == "desktop" ]]; then
      break
    else
      echo "Error: Please enter either 'laptop' or 'desktop'."
    fi
  done

  prompt_sudo_users
}

# Prompt for optional usernames that should be added to the local sudo group
# during bootstrap after NSS/SSSD can resolve them.
prompt_sudo_users() {
  local sudo_users_input
  local sanitized_input
  local user_name

  read -r -p "Users to add to the local sudo group during bootstrap after join (comma-separated, AD usernames are okay, leave blank for none): " sudo_users_input

  if [[ -z "${sudo_users_input//[[:space:]]/}" ]]; then
    return
  fi

  sanitized_input="${sudo_users_input//,/ }"

  for user_name in ${sanitized_input}; do
    SUDO_USERS+=("${user_name}")
  done
}

# Perform the first configuration convergence.
run_initial_configuration() {
  /usr/local/sbin/run-ansible-pull
}

# Gather Kerberos creds and rerun convergence for the required AD enrollment.
join_active_directory() {
  local ad_user
  local ad_password

  read -r -p "AD Admin Username (e.g. duckd-a): " ad_user

  if [[ -z "${ad_user}" ]]; then
    die "Error: AD username cannot be empty."
  fi

  if ! command -v kinit >/dev/null 2>&1; then
    die "Error: kinit was not found after baseline setup. Verify krb5-user is installed."
  fi

  echo "Obtaining Kerberos ticket for ${ad_user}@HHMI.ORG"
  while true; do
    read -r -s -p "AD Password: " ad_password
    echo ""

    if [[ -z "${ad_password}" ]]; then
      echo "Error: AD password cannot be empty." >&2
      continue
    fi

    if printf '%s\n' "${ad_password}" | kinit "${ad_user}@HHMI.ORG"; then
      # Unset the password immediately after kinit succeeds so it does not
      # linger in memory or appear in any process listing.
      unset ad_password
      break
    fi

    echo "kinit failed. Check the username/password and try again, or press Ctrl-C to cancel." >&2
  done

  BOOTSTRAP_PHASE="ad_phase"
  write_bootstrap_vars_ad_phase_state
  /usr/local/sbin/run-ansible-pull
  AD_CONVERGE_SUCCEEDED="true"
  BOOTSTRAP_PHASE="post_ad_converge"
}

# Ensure periodic self-healing continues after bootstrap finishes.
enable_pull_timer() {
  if ! systemctl enable --now ansible-pull.timer; then
    die "Failed to enable ansible-pull.timer. Inspect: systemctl status ansible-pull.timer"
  fi
}

# Print post-enrollment reboot warning after the required AD join completes.
print_ad_reboot_warning() {
  echo ""
  echo "******************************************************************"
  echo "WARNING: The machine has been joined to AD (hhmi.org)."
  echo "A system reboot is REQUIRED before graphical logins will work."
  echo "Please reboot your machine when ready: sudo reboot"
  echo "******************************************************************"
}

# Final apt upgrade pass for immediate package freshness after bootstrap on the
# freshly imaged HHMI systems this workflow targets.
run_final_upgrade() {
  echo "Running final package upgrade"
  apt-get update
  apt-get upgrade -y
}

# Main orchestration flow for first-time workstation bootstrap.
# Bootstrap runs in two phases:
#   Phase 1 (write_bootstrap_vars "false"): converge the baseline role without
#           AD enrollment to install packages, timers, and the pull wrapper.
#           This ensures krb5-user and realmd are present before kinit is called.
#   Phase 2 (join_active_directory): obtain a Kerberos ticket, then re-converge
#           with base_ad_enroll=true so the role performs the domain join and
#           configures SSSD.
main() {
  trap cleanup_bootstrap_state_on_exit EXIT
  parse_args "$@"
  validate_prerequisites
  install_bootstrap_dependencies
  prepare_runtime_directories
  configure_git_credentials
  sync_repository_checkout
  source_checkout_libs
  install_runtime_support
  write_pull_environment

  echo "--- Initial Workstation Config ---"
  prompt_machine_identity
  BOOTSTRAP_PHASE="initial"
  write_bootstrap_vars_initial_state
  run_initial_configuration
  join_active_directory
  # Persist the final bootstrap state with AD enabled so subsequent scheduled
  # runs know this machine is domain-joined and can re-apply AD config if
  # needed, without re-applying one-time local sudo-group bootstrap choices.
  write_bootstrap_vars_final_state
  mark_final_state_written
  BOOTSTRAP_PHASE="enable_timer"
  enable_pull_timer
  run_final_upgrade
  print_ad_reboot_warning
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
