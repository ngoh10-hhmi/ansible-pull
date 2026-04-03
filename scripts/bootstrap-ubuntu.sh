#!/usr/bin/env bash
set -euo pipefail

# Usage/help text for operators running first-time bootstrap.
usage() {
  cat <<'EOF'
Usage:
  bootstrap-ubuntu.sh --repo <repo-url> [--branch <branch>] [--playbook <path>]
                      [--github-user <username>]
                      [--github-token <token> | --github-token-file <path>]

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

The script can also prompt for local users that should be added to the sudo
group during bootstrap.

If you choose Active Directory enrollment during bootstrap, the script will
prompt for an AD username and run kinit interactively before ansible-pull.
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
GITHUB_USER=""
GITHUB_TOKEN=""
GITHUB_TOKEN_FILE=""
SHORT_HOSTNAME=""
MACHINE_TYPE=""
DO_JOIN=""
LOCAL_SUDO_USERS=()

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

# Write the environment file consumed by the ansible-pull wrapper.
write_pull_environment() {
  cat > /etc/ansible/pull.env <<EOF
REPO_URL=${REPO_URL}
BRANCH=${BRANCH}
PLAYBOOK=${PLAYBOOK}
DEST=${DEST}
LOG_DIR=${LOG_DIR}
EOF
  chmod 0600 /etc/ansible/pull.env
}

# Ensure a local checkout exists and is synced to the requested branch.
sync_repository_checkout() {
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
    git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${DEST}"
  fi
}

# Install the wrapper script into the expected system path.
install_pull_wrapper() {
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

  prompt_local_sudo_users
}

# Prompt for optional local users that should be granted sudo access.
prompt_local_sudo_users() {
  local sudo_users_input
  local sanitized_input
  local user_name

  read -r -p "Local users to add to sudo (comma-separated, leave blank for none): " sudo_users_input

  if [[ -z "${sudo_users_input//[[:space:]]/}" ]]; then
    return
  fi

  sanitized_input="${sudo_users_input//,/ }"

  for user_name in ${sanitized_input}; do
    LOCAL_SUDO_USERS+=("${user_name}")
  done
}

# Persist bootstrap variables for Ansible.
# This also pins repo/branch/playbook settings so role defaults do not
# accidentally switch a test workstation back to main after first converge.
write_bootstrap_vars() {
  local ad_enabled="$1"
  local ad_user="${2:-}"
  local sudo_user
  local sudo_users_yaml=""

  if [[ "${#LOCAL_SUDO_USERS[@]}" -gt 0 ]]; then
    sudo_users_yaml="base_local_sudo_users:"
    for sudo_user in "${LOCAL_SUDO_USERS[@]}"; do
      sudo_users_yaml+=$'\n'"  - ${sudo_user}"
    done
  fi

  if [[ "${ad_enabled}" == "true" ]]; then
    cat > "${BOOTSTRAP_VARS_FILE}" <<EOF
base_ansible_pull_repo_url: ${REPO_URL}
base_ansible_pull_branch: ${BRANCH}
base_ansible_pull_playbook: ${PLAYBOOK}
base_ansible_pull_directory: ${DEST}
base_ansible_pull_log_dir: ${LOG_DIR}
target_hostname: ${SHORT_HOSTNAME}
machine_type: ${MACHINE_TYPE}
base_ad_enroll: true
ad_join_user: ${ad_user}
${sudo_users_yaml}
EOF
  else
    cat > "${BOOTSTRAP_VARS_FILE}" <<EOF
base_ansible_pull_repo_url: ${REPO_URL}
base_ansible_pull_branch: ${BRANCH}
base_ansible_pull_playbook: ${PLAYBOOK}
base_ansible_pull_directory: ${DEST}
base_ansible_pull_log_dir: ${LOG_DIR}
target_hostname: ${SHORT_HOSTNAME}
machine_type: ${MACHINE_TYPE}
base_ad_enroll: false
${sudo_users_yaml}
EOF
  fi

  chmod 0600 "${BOOTSTRAP_VARS_FILE}"
}

# Perform the first configuration convergence.
run_initial_configuration() {
  /usr/local/sbin/run-ansible-pull
}

# Optionally gather Kerberos creds and rerun convergence for AD enrollment.
maybe_join_active_directory() {
  local ad_user

  read -r -p "Join AD domain hhmi.org now? (y/n): " DO_JOIN
  if [[ "${DO_JOIN}" =~ ^[Yy]$ ]]; then
    read -r -p "AD Admin Username (e.g. duckd-a): " ad_user

    if [[ -z "${ad_user}" ]]; then
      die "Error: AD username cannot be empty when enrolling."
    fi

    if ! command -v kinit >/dev/null 2>&1; then
      die "Error: kinit was not found after baseline setup. Verify krb5-user is installed."
    fi

    echo "Obtaining Kerberos ticket for ${ad_user}@HHMI.ORG"
    while true; do
      if kinit "${ad_user}@HHMI.ORG"; then
        break
      fi

      echo "kinit failed. Check the username/password and try again, or press Ctrl-C to cancel." >&2
    done

    write_bootstrap_vars "true" "${ad_user}"
    /usr/local/sbin/run-ansible-pull
  fi
}

# Ensure periodic self-healing continues after bootstrap finishes.
enable_pull_timer() {
  systemctl enable --now ansible-pull.timer || true
}

# Print post-enrollment reboot warning when AD join was requested.
print_ad_reboot_warning_if_needed() {
  if [[ "${DO_JOIN}" =~ ^[Yy]$ ]]; then
    echo ""
    echo "******************************************************************"
    echo "WARNING: The machine has been joined to AD (hhmi.org)."
    echo "A system reboot is REQUIRED before graphical logins will work."
    echo "Please reboot your machine when ready: sudo reboot"
    echo "******************************************************************"
  fi
}

# Final apt upgrade pass for immediate package freshness after bootstrap.
run_final_upgrade() {
  echo "Running final package upgrade"
  apt-get update
  apt-get upgrade -y
}

# Main orchestration flow for first-time workstation bootstrap.
main() {
  parse_args "$@"
  validate_prerequisites
  install_bootstrap_dependencies
  prepare_runtime_directories
  configure_git_credentials
  write_pull_environment
  sync_repository_checkout
  install_pull_wrapper

  echo "--- Initial Workstation Config ---"
  prompt_machine_identity
  write_bootstrap_vars "false"
  run_initial_configuration
  maybe_join_active_directory
  enable_pull_timer
  print_ad_reboot_warning_if_needed
  run_final_upgrade
}

main "$@"
