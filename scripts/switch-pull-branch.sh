#!/usr/bin/env bash
set -euo pipefail

# Update ansible-pull branch/repo settings on a workstation without full re-bootstrap.
# This keeps /etc/ansible/pull.env and /etc/ansible/bootstrap-vars.yml aligned so
# scheduled runs continue to track the intended branch while preserving Slack
# notification settings.

ENV_FILE="/etc/ansible/pull.env"
BOOTSTRAP_VARS_FILE="/etc/ansible/bootstrap-vars.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_LIB_DIR="/usr/local/lib/ansible-pull"

NEW_BRANCH=""
NEW_COMMIT=""
NEW_REPO_URL=""
RUN_NOW="false"

die() {
  echo "$*" >&2
  exit 1
}

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

  die "Missing helper library ${filename}"
}

source_script_lib "envfile.sh"
source_script_lib "git_sync.sh"

is_valid_commit_sha() {
  local ref="${1:-}"

  [[ "${ref}" =~ ^[0-9A-Fa-f]{40}$ ]]
}

usage() {
  cat <<'EOF'
Usage:
  switch-pull-branch.sh --branch <branch> [--repo <repo-url>] [--run-now]
  switch-pull-branch.sh --commit <sha> [--repo <repo-url>] [--run-now]

Examples:
  sudo switch-pull-branch.sh --branch testing
  sudo switch-pull-branch.sh --branch main
  sudo switch-pull-branch.sh --commit 0123456789abcdef0123456789abcdef01234567
  sudo switch-pull-branch.sh --branch testing --run-now
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)
        [[ -n "${2:-}" ]] || die "--branch requires a value."
        NEW_BRANCH="${2:-}"
        shift 2
        ;;
      --commit)
        [[ -n "${2:-}" ]] || die "--commit requires a value."
        NEW_COMMIT="${2:-}"
        shift 2
        ;;
      --repo)
        [[ -n "${2:-}" ]] || die "--repo requires a value."
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

  if [[ -n "${NEW_BRANCH}" && -n "${NEW_COMMIT}" ]]; then
    usage
    die "Use either --branch or --commit, not both."
  elif [[ -z "${NEW_BRANCH}" && -z "${NEW_COMMIT}" ]]; then
    usage
    die "Either --branch or --commit is required."
  fi

  if [[ -n "${NEW_COMMIT}" ]] && ! is_valid_commit_sha "${NEW_COMMIT}"; then
    die "Commit pin must be a full 40-character SHA."
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script with sudo or as root."
  fi
}

load_existing_pull_env() {
  load_env_file "${ENV_FILE}" || die "Missing ${ENV_FILE}. Run bootstrap first."
  validate_pull_env || die "Invalid ${ENV_FILE}. Fix it before switching branches."
}

require_bootstrap_vars_file() {
  if [[ ! -f "${BOOTSTRAP_VARS_FILE}" ]]; then
    die "Missing ${BOOTSTRAP_VARS_FILE}. Refusing to rewrite bootstrap state without the existing machine-local settings."
  fi
}

apply_branch_settings() {
  if [[ -n "${NEW_COMMIT}" ]]; then
    BRANCH="${NEW_COMMIT}"
  else
    BRANCH="${NEW_BRANCH}"
  fi

  if [[ -n "${NEW_REPO_URL}" ]]; then
    REPO_URL="${NEW_REPO_URL}"
  fi
}

validate_target_branch() {
  if ! command -v git >/dev/null 2>&1; then
    die "git is required to validate the target ref."
  fi

  if [[ -n "${NEW_COMMIT}" ]]; then
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    if (
      git init --quiet "${tmp_dir}"
      git -C "${tmp_dir}" remote add origin "${REPO_URL}"
      git_fetch_commit_ref "${tmp_dir}" "${NEW_COMMIT}" "1"
      git -C "${tmp_dir}" cat-file -e "${NEW_COMMIT}^{commit}"
    ); then
      rm -rf "${tmp_dir}"
      return 0
    fi

    rm -rf "${tmp_dir}"
    die "Could not fetch commit '${NEW_COMMIT}' from repo '${REPO_URL}'. Refusing to update ansible-pull settings."
  else
    # Branch switches are validated upfront to avoid persisting a branch that
    # the next scheduled run cannot fetch.
    if ! git ls-remote --exit-code --heads "${REPO_URL}" "${BRANCH}" >/dev/null 2>&1; then
      die "Could not find branch '${BRANCH}' in repo '${REPO_URL}'. Refusing to update ansible-pull settings."
    fi

    return 0
  fi
}

write_pull_env() {
  # Keep existing Slack settings intact so future scheduled runs preserve the
  # same failure summaries and optional success notifications.
  write_pull_env_file "${ENV_FILE}"
  load_env_file "${ENV_FILE}"
  validate_pull_env
}

write_bootstrap_vars() {
  local tmp_file
  tmp_file="$(mktemp)"

  {
    # Write the five updated pull settings first, then append everything else
    # from the existing bootstrap vars file with those five keys stripped out.
    # This preserves host-specific values (hostname, machine_type, sudo users,
    # AD settings, etc.) while updating only the repo/branch coordinates.
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
    echo "No immediate run requested. Timer/manual runs will now use ref '${BRANCH}'."
  fi
}

main() {
  parse_args "$@"
  require_root
  load_existing_pull_env
  require_bootstrap_vars_file
  apply_branch_settings
  validate_target_branch
  write_pull_env
  write_bootstrap_vars
  print_summary
  maybe_run_now
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
