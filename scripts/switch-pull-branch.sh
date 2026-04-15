#!/usr/bin/env bash
set -euo pipefail

# Update ansible-pull branch/repo settings on a workstation without full re-bootstrap.
# This keeps /etc/ansible/pull.env and /etc/ansible/bootstrap-vars.yml aligned so
# scheduled runs continue to track the intended branch while preserving Slack
# notification settings.

ENV_FILE="/etc/ansible/pull.env"
BOOTSTRAP_VARS_FILE="/etc/ansible/bootstrap-vars.yml"

NEW_BRANCH=""
NEW_REPO_URL=""
RUN_NOW="false"

usage() {
  cat <<'EOF'
Usage:
  switch-pull-branch.sh --branch <branch> [--repo <repo-url>] [--run-now]

Examples:
  sudo switch-pull-branch.sh --branch testing
  sudo switch-pull-branch.sh --branch main
  sudo switch-pull-branch.sh --branch testing --run-now
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)
        NEW_BRANCH="${2:-}"
        shift 2
        ;;
      --repo)
        NEW_REPO_URL="${2:-}"
        shift 2
        ;;
      --run-now)
        RUN_NOW="true"
        shift 1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  if [[ -z "${NEW_BRANCH}" ]]; then
    usage
    die "--branch is required."
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script with sudo or as root."
  fi
}

load_existing_pull_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    die "Missing ${ENV_FILE}. Run bootstrap first."
  fi

  set -a
  # shellcheck disable=SC1091
  # shellcheck source=/etc/ansible/pull.env
  source "${ENV_FILE}"
  set +a
}

apply_branch_settings() {
  BRANCH="${NEW_BRANCH}"
  if [[ -n "${NEW_REPO_URL}" ]]; then
    REPO_URL="${NEW_REPO_URL}"
  fi
}

write_pull_env() {
  # Keep existing Slack settings intact so future scheduled runs preserve the
  # same failure summaries and optional success notifications.
  cat > "${ENV_FILE}" <<EOF
REPO_URL="${REPO_URL}"
BRANCH="${BRANCH}"
PLAYBOOK="${PLAYBOOK}"
DEST="${DEST}"
LOG_DIR="${LOG_DIR}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLACK_NOTIFY_SUCCESS="${SLACK_NOTIFY_SUCCESS:-false}"
EOF
  chmod 0600 "${ENV_FILE}"
}

write_bootstrap_vars() {
  local tmp_file
  tmp_file="$(mktemp)"

  {
    echo "base_ansible_pull_repo_url: \"${REPO_URL}\""
    echo "base_ansible_pull_branch: \"${BRANCH}\""
    echo "base_ansible_pull_playbook: \"${PLAYBOOK}\""
    echo "base_ansible_pull_directory: \"${DEST}\""
    echo "base_ansible_pull_log_dir: \"${LOG_DIR}\""

    if [[ -f "${BOOTSTRAP_VARS_FILE}" ]]; then
      awk '
        !/^base_ansible_pull_repo_url:/ &&
        !/^base_ansible_pull_branch:/ &&
        !/^base_ansible_pull_playbook:/ &&
        !/^base_ansible_pull_directory:/ &&
        !/^base_ansible_pull_log_dir:/
      ' "${BOOTSTRAP_VARS_FILE}"
    fi
  } > "${tmp_file}"

  install -m 0600 "${tmp_file}" "${BOOTSTRAP_VARS_FILE}"
  rm -f "${tmp_file}"
}

print_summary() {
  echo "Updated ansible-pull configuration:"
  echo "  REPO_URL=${REPO_URL}"
  echo "  BRANCH=${BRANCH}"
  echo "  PLAYBOOK=${PLAYBOOK}"
  echo "  DEST=${DEST}"
  echo "  LOG_DIR=${LOG_DIR}"
}

maybe_run_now() {
  if [[ "${RUN_NOW}" == "true" ]]; then
    if [[ ! -x /usr/local/sbin/run-ansible-pull ]]; then
      die "Missing /usr/local/sbin/run-ansible-pull. Bootstrap may be incomplete."
    fi

    echo "Running ansible-pull immediately..."
    /usr/local/sbin/run-ansible-pull
  else
    echo "No immediate run requested. Timer/manual runs will now use branch '${BRANCH}'."
  fi
}

main() {
  parse_args "$@"
  require_root
  load_existing_pull_env
  apply_branch_settings
  write_pull_env
  write_bootstrap_vars
  print_summary
  maybe_run_now
}

main "$@"
