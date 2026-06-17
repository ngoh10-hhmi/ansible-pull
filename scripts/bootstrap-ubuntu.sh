#!/usr/bin/env bash
set -euo pipefail

# Usage/help text for operators running first-time bootstrap.
usage() {
  cat <<'EOF'
Usage:
  bootstrap-ubuntu.sh --repo <repo-url> [--branch <branch>] [--commit <sha>] [--playbook <path>]
                      [--github-user <username>]
                      [--github-token <token> | --github-token-file <path>]
                      [--slack-webhook <url>] [--slack-notify-success <true|false>]
                      [--reset-env]

Example:
  sudo ./bootstrap-ubuntu.sh \
    --repo https://github.com/example/ansible-pull.git \
    --branch main

Pin to a specific commit (useful for rollback):
  sudo ./bootstrap-ubuntu.sh \
    --repo https://github.com/example/ansible-pull.git \
    --commit 0123456789abcdef0123456789abcdef01234567

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
wrapper phase, last detected Ansible task, and a short error excerpt. If
--slack-webhook is not passed, the script prompts for the webhook URL during
bootstrap; leave it blank to skip notifications.

Re-running bootstrap preserves values already in /etc/ansible/pull.env (such as
the Slack webhook and the configured branch) unless you override them with the
matching flag, so a re-run will not silently wipe operator-configured settings.
Pass --reset-env to ignore the existing file and rebuild pull.env purely from
the supplied flags and defaults (a clean-slate repair path).
EOF
}

# Emit a fatal error message and stop execution.
die() {
  echo "$*" >&2
  exit 1
}

# Read a single line of operator input into a named variable, failing loudly on
# EOF. A `read` returns non-zero when stdin is closed — a non-interactive run, a
# pipe with no more data, or the operator pressing Ctrl-D. Reprompt loops that
# ignore that status spin forever, so every interactive prompt funnels through
# here to turn "no input at all" into a clear abort with a reason. A blank line
# typed at a real terminal still reads successfully; callers decide whether an
# empty value is acceptable.
#
# Usage: prompt_line <label> <var-name> <prompt-text> [extra read flags...]
#   label       human-readable field name, used in the abort message
#   var-name    name of the variable to populate
#   prompt-text shown to the operator (passed to read -p)
#   extra flags forwarded to read (e.g. -s for a hidden password)
prompt_line() {
  local label="$1" var_name="$2" prompt="$3"
  shift 3

  # Reading into a variable whose name is held in ${var_name} is intentional;
  # SC2229 assumes a literal name was meant.
  # shellcheck disable=SC2229
  if ! read -r "$@" -p "${prompt}" "${var_name}"; then
    die "Error: reached end of input while reading ${label}; aborting (non-interactive run or Ctrl-D)."
  fi
}

# Echo the argument list with the values of secret-bearing flags replaced by a
# placeholder, so the audit log never persists a token or webhook URL. Handles
# both "--flag value" and "--flag=value" forms.
redact_sensitive_args() {
  local out=() redact_next="false" arg
  for arg in "$@"; do
    if [[ "${redact_next}" == "true" ]]; then
      out+=("***REDACTED***")
      redact_next="false"
      continue
    fi
    case "${arg}" in
      --github-token | --slack-webhook)
        out+=("${arg}")
        redact_next="true"
        ;;
      --github-token=* | --slack-webhook=*)
        out+=("${arg%%=*}=***REDACTED***")
        ;;
      *)
        out+=("${arg}")
        ;;
    esac
  done
  printf '%s' "${out[*]}"
}

# Record the invoking user and arguments to syslog so a fleet-wide audit can
# attribute bootstrap runs to a person rather than just the timer-driven
# convergence stream. Secret-bearing flag values are redacted first so the
# audit trail never leaks a token or webhook URL. Best-effort: if logger is
# missing we silently skip rather than block bootstrap.
audit_log_invocation() {
  local tag="$1"
  shift
  local invoker="${SUDO_USER:-${USER:-unknown}}"
  local redacted_args
  redacted_args="$(redact_sensitive_args "$@")"

  if command -v logger >/dev/null 2>&1; then
    logger -t "${tag}" "invoked by ${invoker} args=${redacted_args}" || true
  fi
}

# Default bootstrap configuration and optional credential inputs.
REPO_URL=""
BRANCH="main"
BRANCH_PROVIDED="false"
RESET_ENV="false"
COMMIT=""
PLAYBOOK="playbooks/workstation.yml"
DEST="/var/lib/ansible-pull"
LOG_DIR="/var/log/ansible-pull"
BOOTSTRAP_VARS_FILE="/etc/ansible/bootstrap-vars.yml"
PULL_ENV_FILE="/etc/ansible/pull.env"
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
GIT_CREDENTIALS_WRITTEN="false"
GIT_CREDENTIALS_FILE="/root/.git-credentials-ansible-pull"
# Bootstrap's converge passes must actually run, so they wait out an in-flight
# timer run for the lock rather than letting run-ansible-pull treat lock
# contention as a successful no-op (which would falsely set
# AD_CONVERGE_SUCCEEDED and permanently skip the one-shot sudo-users converge).
# A converge plus a final apt pass stays well under 30 minutes.
readonly BOOTSTRAP_LOCK_WAIT_SECONDS=1800
# The advisory lock the scheduled runner (run-ansible-pull) holds while it
# syncs and converges. Bootstrap takes it too while doing its own git sync so
# the two cannot race on the same worktree. Must match LOCK_FILE in
# scripts/run-ansible-pull.sh.
readonly PULL_LOCK_FILE="/var/lock/ansible-pull.lock"

# True when --reset-env appears anywhere in the argument list. We need this
# answer before parse_args runs, because the preload below must happen ahead of
# argument parsing to keep CLI flags authoritative.
args_contain_reset_env() {
  local arg
  for arg in "$@"; do
    [[ "${arg}" == "--reset-env" ]] && return 0
  done
  return 1
}

# Seed the pull.env-backed settings from any existing /etc/ansible/pull.env
# before CLI parsing, so a bootstrap re-run preserves operator-configured values
# (notably SLACK_WEBHOOK_URL, and a previously selected BRANCH/PLAYBOOK) unless
# they are explicitly overridden on the command line. Combined with the default
# assignments above and parse_args below, the precedence becomes:
#   CLI flag  >  existing pull.env value  >  built-in default
# A first-time bootstrap has no file and falls straight through to the defaults;
# a malformed file is tolerated (we keep the defaults rather than abort).
#
# Skipped entirely when --reset-env is passed, restoring the legacy behavior of
# rebuilding pull.env from CLI flags and defaults (a clean-slate repair path).
preload_existing_pull_env() {
  [[ -r "${PULL_ENV_FILE}" ]] || return 0
  # shellcheck disable=SC1090
  source "${PULL_ENV_FILE}" 2>/dev/null || true
}

# Parse CLI arguments into global script settings.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ -n "${2:-}" ]] || die "--repo requires a value."
        REPO_URL="${2:-}"
        shift 2
        ;;
      --branch)
        [[ -n "${2:-}" ]] || die "--branch requires a value."
        BRANCH="${2:-}"
        BRANCH_PROVIDED="true"
        shift 2
        ;;
      --commit)
        [[ -n "${2:-}" ]] || die "--commit requires a value."
        COMMIT="${2:-}"
        shift 2
        ;;
      --playbook)
        [[ -n "${2:-}" ]] || die "--playbook requires a value."
        PLAYBOOK="${2:-}"
        shift 2
        ;;
      --github-user)
        [[ -n "${2:-}" ]] || die "--github-user requires a value."
        GITHUB_USER="${2:-}"
        shift 2
        ;;
      --github-token)
        [[ -n "${2:-}" ]] || die "--github-token requires a value."
        GITHUB_TOKEN="${2:-}"
        shift 2
        ;;
      --github-token-file)
        [[ -n "${2:-}" ]] || die "--github-token-file requires a value."
        GITHUB_TOKEN_FILE="${2:-}"
        shift 2
        ;;
      --slack-webhook)
        [[ -n "${2:-}" ]] || die "--slack-webhook requires a value."
        is_valid_webhook_url "${2}" || die "--slack-webhook must be an https:// URL."
        SLACK_WEBHOOK_URL="${2:-}"
        shift 2
        ;;
      --slack-notify-success)
        [[ -n "${2:-}" ]] || die "--slack-notify-success requires a value."
        SLACK_NOTIFY_SUCCESS="${2:-}"
        shift 2
        ;;
      --reset-env)
        RESET_ENV="true"
        shift
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

is_valid_commit_sha() {
  local ref="${1:-}"

  [[ "${ref}" =~ ^[0-9A-Fa-f]{40}$ ]]
}

# Sanity-check a repo argument: a recognized git URL scheme (https, ssh, git,
# file), an scp-style git@host:path, or a local path. Deliberately permissive —
# it rejects empty input and embedded whitespace so an obviously malformed value
# fails with a clear reason here rather than as a cryptic git error, without
# second-guessing exotic-but-valid remotes.
is_plausible_repo_url() {
  local url="${1:-}"

  [[ -n "${url}" ]] || return 1
  [[ "${url}" != *[[:space:]]* ]] || return 1
  [[ "${url}" =~ ^(https?://|ssh://|git://|file://|git@|/|\.{1,2}/) ]]
}

# A webhook URL must be an https URL with no embedded whitespace. Used for both
# the --slack-webhook flag and the interactive prompt.
is_valid_webhook_url() {
  local url="${1:-}"

  [[ -n "${url}" ]] || return 1
  [[ "${url}" != *[[:space:]]* ]] || return 1
  [[ "${url}" =~ ^https://[^[:space:]]+$ ]]
}

normalize_pull_ref_args() {
  if [[ "${BRANCH_PROVIDED}" == "true" && -n "${COMMIT}" ]]; then
    die "Use either --branch or --commit, not both."
  fi

  if [[ -n "${COMMIT}" ]]; then
    if ! is_valid_commit_sha "${COMMIT}"; then
      die "Commit pin must be a full 40-character SHA."
    fi

    # BRANCH is the persisted ansible-pull ref, so a commit pin is stored here
    # for /etc/ansible/pull.env and bootstrap-vars.yml.
    BRANCH="${COMMIT}"
  fi
}

# Validate execution context (root, required args, and Ubuntu OS).
validate_prerequisites() {
  normalize_pull_ref_args

  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script with sudo or as root."
  fi

  if [[ -z "${REPO_URL}" ]]; then
    echo "--repo is required." >&2
    usage
    exit 1
  fi

  if ! is_plausible_repo_url "${REPO_URL}"; then
    die "--repo does not look like a git URL or path: ${REPO_URL}"
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

    cat > "${GIT_CREDENTIALS_FILE}" <<EOF
https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com
EOF
    chmod 0600 "${GIT_CREDENTIALS_FILE}"
    git config --global credential.helper "store --file ${GIT_CREDENTIALS_FILE}"
    GIT_CREDENTIALS_WRITTEN="true"
  fi
}

# Write the environment file consumed by the ansible-pull wrapper, including
# Slack settings for failure summaries and optional success notifications.
write_pull_environment() {
  if [[ "${BOOTSTRAP_LIBS_LOADED}" != "true" ]]; then
    die "Bootstrap helper libraries are not loaded yet."
  fi

  : "${SLACK_WEBHOOK_URL}" "${SLACK_NOTIFY_SUCCESS}"
  write_pull_env_file "${PULL_ENV_FILE}"
  load_env_file "${PULL_ENV_FILE}"
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

bootstrap_fetch_branch_ref() {
  local repo_dir="$1"
  local ref="$2"
  local clone_depth="${3:-}"
  local fetch_args=(--prune origin)

  if [[ -n "${clone_depth}" ]]; then
    fetch_args+=(--depth "${clone_depth}")
  fi

  fetch_args+=("+refs/heads/${ref}:refs/remotes/origin/${ref}")
  git -C "${repo_dir}" fetch "${fetch_args[@]}"
}

bootstrap_fetch_commit_ref() {
  local repo_dir="$1"
  local ref="$2"
  local clone_depth="${3:-}"
  local fetch_args=(--prune origin)

  if [[ -n "${clone_depth}" ]]; then
    fetch_args+=(--depth "${clone_depth}")
  fi

  fetch_args+=("${ref}")
  if git -C "${repo_dir}" fetch "${fetch_args[@]}"; then
    return 0
  fi

  git -C "${repo_dir}" fetch --prune origin \
    "+refs/heads/*:refs/remotes/origin/*" \
    "+refs/tags/*:refs/tags/*"
}

# Acquire the scheduled runner's advisory lock on fd 9 before bootstrap touches
# the worktree. Without this, a bootstrap re-run while the timer is mid-sync
# would let remove_stale_git_locks delete the live git's index.lock and have
# both processes reset --hard/clean the same checkout concurrently, corrupting
# it. Blocks up to BOOTSTRAP_LOCK_WAIT_SECONDS, then fails loudly.
acquire_pull_sync_lock() {
  exec 9>"${PULL_LOCK_FILE}"
  if ! flock -w "${BOOTSTRAP_LOCK_WAIT_SECONDS}" 9; then
    die "Timed out after ${BOOTSTRAP_LOCK_WAIT_SECONDS}s waiting for ${PULL_LOCK_FILE}; another ansible-pull run is in progress. Re-run bootstrap once it completes."
  fi
}

# Release the lock by closing fd 9. Called before run-ansible-pull, which
# acquires the same lock itself (holding it here would deadlock that run).
release_pull_sync_lock() {
  exec 9>&-
}

# Ensure a local checkout exists and is synced to the requested branch or commit.
sync_repository_checkout() {
  local ref="${BRANCH}"
  if [[ -n "${COMMIT}" ]]; then
    ref="${COMMIT}"
  fi

  if [[ -f "${DEST}/scripts/lib/git_sync.sh" ]]; then
    source_checkout_libs
    # The first bootstrap on a brand-new machine is often run from a single
    # downloaded bootstrap script, so this shared helper is only available
    # once a checkout already exists.
    sync_checkout_or_clone "${DEST}" "${REPO_URL}" "${ref}" "1"
    return
  fi

  if [[ -d "${DEST}/.git" ]]; then
    if git -C "${DEST}" remote get-url origin >/dev/null 2>&1; then
      git -C "${DEST}" remote set-url origin "${REPO_URL}"
    else
      git -C "${DEST}" remote add origin "${REPO_URL}"
    fi
    if [[ -n "${COMMIT}" ]]; then
      bootstrap_fetch_commit_ref "${DEST}" "${ref}"
      git -C "${DEST}" checkout --detach "${ref}"
      git -C "${DEST}" reset --hard "${ref}"
    else
      bootstrap_fetch_branch_ref "${DEST}" "${ref}"
      git -C "${DEST}" checkout -B "${ref}" "origin/${ref}"
      git -C "${DEST}" reset --hard "origin/${ref}"
    fi
    git -C "${DEST}" clean -fdx
  else
    rm -rf "${DEST}"
    # --depth 1 fetches only the latest commit so the initial clone is fast
    # and uses minimal disk space. The installed runtime wrapper uses the
    # shared git sync helper after bootstrap completes.
    if [[ -n "${COMMIT}" ]]; then
      git init --quiet "${DEST}"
      git -C "${DEST}" remote add origin "${REPO_URL}"
      bootstrap_fetch_commit_ref "${DEST}" "${ref}" "1"
      git -C "${DEST}" checkout --detach "${ref}"
      git -C "${DEST}" reset --hard "${ref}"
    else
      git clone --depth 1 --branch "${ref}" "${REPO_URL}" "${DEST}"
    fi
  fi

  # Once the inline path lands a checkout, the shared verifier is available
  # for the same HEAD-vs-expected check the runtime wrapper uses. Sourcing
  # is idempotent so doing it again later in main() is safe.
  if [[ -f "${DEST}/scripts/lib/git_sync.sh" ]]; then
    # shellcheck disable=SC1091
    source "${DEST}/scripts/lib/git_sync.sh"
    local is_commit_pin="false"
    if [[ -n "${COMMIT}" ]]; then
      is_commit_pin="true"
    fi
    git_verify_head_matches_ref "${DEST}" "${ref}" "${is_commit_pin}" \
      || die "Bootstrap clone of ${REPO_URL} did not land at expected ref ${ref}."
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

# The final state is identical to the AD-phase state today. Sudo group
# membership is no longer expressed through bootstrap vars at all: it is a
# one-shot OS-level change applied by add_bootstrap_sudo_users() after the
# realm join, so nothing about it needs to be persisted for the role to read.
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

  # If bootstrap aborted before reaching its successful terminal state, scrub
  # any GitHub PAT we wrote earlier so a half-finished install does not leave
  # a credential file or git config helper pointing at a token that may no
  # longer be needed. On the success path GIT_CREDENTIALS_WRITTEN stays set
  # but FINAL_STATE_WRITTEN gates this branch out, so the credentials remain
  # in place for the runtime wrapper.
  if [[ "${GIT_CREDENTIALS_WRITTEN}" == "true" ]]; then
    rm -f "${GIT_CREDENTIALS_FILE}" || true
    git config --global --unset credential.helper >/dev/null 2>&1 || true
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

# Keep bootstrap hostname inputs compatible with normal short-hostname rules:
# 1-15 chars, only letters/digits/hyphens, and no leading/trailing hyphen.
is_valid_short_hostname() {
  local hostname="${1:-}"

  [[ -n "${hostname}" ]] || return 1
  [[ ${#hostname} -le 15 ]] || return 1
  [[ "${hostname}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,13}[A-Za-z0-9])?$ ]]
}

# Validate a username's *format* only — not whether it resolves in NSS/SSSD.
# Accepts the shapes Linux and AD sAMAccountName use in practice: a leading
# letter or underscore, then letters, digits, dot, hyphen, or underscore, up to
# 32 characters. This rejects empty input, embedded spaces, and shell
# metacharacters while still allowing names that cannot resolve yet — existence
# is deliberately tolerated downstream (the role re-attempts gpasswd on later
# converges), so we only guard against malformed entries here.
is_valid_username() {
  local name="${1:-}"

  [[ -n "${name}" ]] || return 1
  [[ ${#name} -le 32 ]] || return 1
  [[ "${name}" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]]
}

is_already_joined_to_ad() {
  if command -v realm >/dev/null 2>&1 && realm list | grep -q "hhmi.org"; then
    return 0
  fi
  return 1
}

# Prompt for machine identity metadata used by the Ansible role. The whole set
# of prompts is collected, summarized, and confirmed; answering "no" at the
# confirmation restarts the prompts so a mistyped-but-valid value can be fixed.
prompt_machine_identity() {
  while true; do
    prompt_short_hostname
    prompt_machine_type
    prompt_sudo_users

    if confirm_machine_identity; then
      break
    fi
    echo "Restarting machine identity prompts." >&2
  done
}

prompt_short_hostname() {
  local current_short_hostname
  current_short_hostname="$(hostname -s 2>/dev/null || true)"

  while true; do
    if [[ -n "${current_short_hostname}" ]]; then
      prompt_line "the short hostname" SHORT_HOSTNAME \
        "Enter short hostname (max 15 chars, without .hhmi.org) [${current_short_hostname}]: "
      SHORT_HOSTNAME="${SHORT_HOSTNAME:-${current_short_hostname}}"
    else
      prompt_line "the short hostname" SHORT_HOSTNAME \
        "Enter short hostname (max 15 chars, without .hhmi.org): "
    fi

    if [[ ${#SHORT_HOSTNAME} -gt 15 ]]; then
      echo "Error: Hostname exceeds 15 characters. Please try again." >&2
    elif [[ -z "${SHORT_HOSTNAME}" ]]; then
      echo "Error: Hostname cannot be empty." >&2
    elif ! is_valid_short_hostname "${SHORT_HOSTNAME}"; then
      echo "Error: Hostname must use only letters, numbers, or internal hyphens." >&2
    else
      break
    fi
  done
}

prompt_machine_type() {
  while true; do
    prompt_line "the machine type" MACHINE_TYPE "Machine type (laptop/desktop): "
    if [[ "${MACHINE_TYPE}" == "laptop" || "${MACHINE_TYPE}" == "desktop" ]]; then
      break
    else
      echo "Error: Please enter either 'laptop' or 'desktop'." >&2
    fi
  done
}

# Prompt for optional usernames that should be added to the local sudo group
# during bootstrap after NSS/SSSD can resolve them. Re-prompts the whole list
# if any entry is not a valid username format, naming the offending token(s).
prompt_sudo_users() {
  local sudo_users_input sanitized_input user_name
  local invalid_users

  while true; do
    prompt_line "the sudo user list" sudo_users_input \
      "Users to add to the local sudo group during bootstrap after join (comma-separated, AD usernames are okay, leave blank for none): "

    # A blank or whitespace-only answer means "no sudo users" — a valid choice.
    if [[ -z "${sudo_users_input//[[:space:]]/}" ]]; then
      SUDO_USERS=()
      return
    fi

    sanitized_input="${sudo_users_input//,/ }"
    SUDO_USERS=()
    invalid_users=()
    for user_name in ${sanitized_input}; do
      if is_valid_username "${user_name}"; then
        SUDO_USERS+=("${user_name}")
      else
        invalid_users+=("${user_name}")
      fi
    done

    if [[ ${#invalid_users[@]} -eq 0 ]]; then
      return
    fi

    echo "Error: invalid username(s): ${invalid_users[*]}. Use only letters, digits, '.', '-', '_'; start with a letter or '_'; max 32 chars. Please re-enter the list." >&2
    SUDO_USERS=()
  done
}

# Resolve a username through NSS, retrying briefly. getent can lag for a few
# seconds immediately after the realm join while the SSSD cache warms up, so a
# valid AD account may not resolve on the first attempt; retry before declaring
# it absent. Returns 0 if the name resolves, non-zero otherwise.
sudo_user_resolves_in_ad() {
  local user_name="${1:-}"
  local attempt

  for (( attempt = 1; attempt <= 5; attempt++ )); do
    if getent passwd "${user_name}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

# Add the operator's requested users to the local sudo group. Called only after
# the realm join + SSSD are up, which is the first point at which an AD account
# can be confirmed to exist. Any name that does not resolve in AD is reported by
# name and the whole list is reprompted (interactive) rather than aborting the
# converge. Local accounts created later are intentionally out of scope: create
# them and grant sudo by hand after bootstrap.
add_bootstrap_sudo_users() {
  local user_name
  local unresolved

  while true; do
    if [[ "${#SUDO_USERS[@]}" -eq 0 ]]; then
      return
    fi

    unresolved=()
    for user_name in "${SUDO_USERS[@]}"; do
      if ! sudo_user_resolves_in_ad "${user_name}"; then
        unresolved+=("${user_name}")
      fi
    done

    if [[ "${#unresolved[@]}" -eq 0 ]]; then
      break
    fi

    for user_name in "${unresolved[@]}"; do
      echo "Error: user '${user_name}' does not exist in AD." >&2
    done
    echo "Re-enter the sudo user list; every name must resolve in AD. Local accounts you intend to create later are out of scope here — add them to sudo by hand afterward." >&2
    prompt_sudo_users
  done

  for user_name in "${SUDO_USERS[@]}"; do
    echo "Adding ${user_name} to the local sudo group"
    if ! gpasswd -a "${user_name}" sudo; then
      die "Error: failed to add '${user_name}' to the sudo group even though it resolves in AD. Inspect the gpasswd output above."
    fi
  done
}

# Summarize the collected machine identity and ask the operator to confirm.
# Returns 0 to proceed, 1 to restart the prompts.
confirm_machine_identity() {
  local reply sudo_summary

  if [[ ${#SUDO_USERS[@]} -eq 0 ]]; then
    sudo_summary="(none)"
  else
    sudo_summary="${SUDO_USERS[*]}"
  fi

  {
    echo ""
    echo "Please confirm these bootstrap settings:"
    echo "  Short hostname : ${SHORT_HOSTNAME}"
    echo "  Machine type   : ${MACHINE_TYPE}"
    echo "  Sudo users     : ${sudo_summary}"
  } >&2

  while true; do
    prompt_line "the confirmation" reply "Proceed with these settings? [y/n]: "
    case "${reply,,}" in
      y | yes) return 0 ;;
      n | no) return 1 ;;
      *) echo "Error: please answer 'y' or 'n'." >&2 ;;
    esac
  done
}

# Optionally collect a Slack webhook URL interactively when one was not supplied
# via --slack-webhook. Blank is allowed — the operator may not know the URL, in
# which case run notifications are simply left unconfigured. A non-blank entry
# must look like an https URL and is re-prompted otherwise.
prompt_slack_webhook() {
  # Respect a value already provided (and validated) on the command line.
  if [[ -n "${SLACK_WEBHOOK_URL}" ]]; then
    return
  fi

  local webhook_input
  while true; do
    prompt_line "the Slack webhook URL" webhook_input \
      "Slack webhook URL for run notifications (optional; leave blank if unknown): "

    if [[ -z "${webhook_input//[[:space:]]/}" ]]; then
      return
    fi

    if is_valid_webhook_url "${webhook_input}"; then
      SLACK_WEBHOOK_URL="${webhook_input}"
      return
    fi

    echo "Error: that does not look like a webhook URL (expected https://...). Please re-enter or leave blank to skip." >&2
  done
}

# Perform the first configuration convergence.
run_initial_configuration() {
  ANSIBLE_PULL_LOCK_WAIT_SECONDS="${BOOTSTRAP_LOCK_WAIT_SECONDS}" \
    /usr/local/sbin/run-ansible-pull
}

# Gather Kerberos creds and rerun convergence for the required AD enrollment.
join_active_directory() {
  local ad_user
  local ad_password
  local kinit_failures=0
  local max_kinit_failures=5

  if ! command -v kinit >/dev/null 2>&1; then
    die "Error: kinit was not found after baseline setup. Verify krb5-user is installed."
  fi

  while true; do
    # A failed read means EOF: stdin is closed (non-interactive run, a pipe, or
    # the operator pressed Ctrl-D). There is no one to reprompt, so bail rather
    # than spin the loop forever. A blank line from a real terminal still reads
    # successfully and falls through to the empty-username reprompt below.
    prompt_line "the AD username" ad_user "AD Admin Username (e.g. duckd-a): "

    if [[ -z "${ad_user}" ]]; then
      echo "Error: AD username cannot be empty." >&2
      continue
    fi

    # Strip the hhmi.org realm suffix if the operator typed it in
    # (e.g. user@hhmi.org or user@HHMI.ORG -> user). Reject other realms so a
    # typo like user@example.com fails loudly here rather than at kinit.
    if [[ "${ad_user}" == *"@"* ]]; then
      local ad_user_suffix="${ad_user#*@}"
      if [[ "${ad_user_suffix,,}" == "hhmi.org" ]]; then
        ad_user="${ad_user%@*}"
      else
        echo "Error: AD username must be in the hhmi.org realm (got '@${ad_user_suffix}')." >&2
        continue
      fi
    fi

    # Reject malformed usernames up front rather than feeding them to kinit.
    if ! is_valid_username "${ad_user}"; then
      echo "Error: '${ad_user}' is not a valid username (letters, digits, '.', '-', '_'; start with a letter or '_'; max 32 chars). Please try again." >&2
      continue
    fi

    prompt_line "the AD password" ad_password "AD Password: " -s
    echo ""

    if [[ -z "${ad_password}" ]]; then
      echo "Error: AD password cannot be empty." >&2
      unset ad_password
      continue
    fi

    echo "Obtaining Kerberos ticket for ${ad_user}@HHMI.ORG"
    if printf '%s\n' "${ad_password}" | kinit "${ad_user}@HHMI.ORG"; then
      # Unset the password immediately after kinit succeeds so it does not
      # linger in memory or appear in any process listing.
      unset ad_password
      break
    fi

    unset ad_password
    kinit_failures=$((kinit_failures + 1))
    if [[ "${kinit_failures}" -ge "${max_kinit_failures}" ]]; then
      die "Error: ${max_kinit_failures} failed AD authentication attempts; aborting. Re-run bootstrap once the credentials are confirmed."
    fi
    echo "kinit failed (attempt ${kinit_failures}/${max_kinit_failures}). Check the username/password and try again, or press Ctrl-C to cancel." >&2
  done

  BOOTSTRAP_PHASE="ad_phase"
  write_bootstrap_vars_ad_phase_state
  ANSIBLE_PULL_LOCK_WAIT_SECONDS="${BOOTSTRAP_LOCK_WAIT_SECONDS}" \
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
  # Non-fatal: by this point AD enrollment, the pull timer, and the final
  # bootstrap-vars state are all in place, so a transient mirror/network
  # hiccup during the freshness upgrade should not fail the whole bootstrap.
  # Surface a clear warning and let the operator re-run apt later.
  if ! { apt-get update && apt-get upgrade -y; }; then
    echo "Warning: final package upgrade did not complete cleanly. The machine is already enrolled and the ansible-pull timer is active; run 'sudo apt-get update && sudo apt-get upgrade' later to finish." >&2
  fi
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
  audit_log_invocation "ansible-pull-bootstrap" "$@"
  # Preserve existing pull.env values across re-runs unless --reset-env asks for
  # the legacy clean-slate rebuild. Detected via a pre-scan because the preload
  # must precede parse_args to keep CLI flags authoritative.
  if ! args_contain_reset_env "$@"; then
    preload_existing_pull_env
  fi
  parse_args "$@"
  if [[ "${RESET_ENV}" == "true" ]]; then
    echo "Rebuilding ${PULL_ENV_FILE} from flags and defaults (--reset-env); existing values are not preserved." >&2
  fi
  validate_prerequisites
  install_bootstrap_dependencies
  prepare_runtime_directories
  configure_git_credentials
  acquire_pull_sync_lock
  sync_repository_checkout
  source_checkout_libs
  install_runtime_support
  release_pull_sync_lock

  echo "--- Initial Workstation Config ---"
  prompt_slack_webhook
  write_pull_environment

  prompt_machine_identity

  local was_already_joined="false"
  if is_already_joined_to_ad; then
    was_already_joined="true"
  fi

  if [[ "${was_already_joined}" == "true" ]]; then
    echo "System is already joined to Active Directory (hhmi.org). Skipping enrollment prompt."
    BOOTSTRAP_PHASE="post_ad_converge"
    AD_CONVERGE_SUCCEEDED="true"
    write_bootstrap_vars_final_state
    run_initial_configuration
    mark_final_state_written
  else
    BOOTSTRAP_PHASE="initial"
    write_bootstrap_vars_initial_state
    run_initial_configuration
    join_active_directory
    write_bootstrap_vars_final_state
    mark_final_state_written
  fi

  # Sudo group membership is applied here, after the realm join + SSSD are up
  # in either branch, so requested AD accounts can be confirmed to resolve.
  add_bootstrap_sudo_users

  BOOTSTRAP_PHASE="enable_timer"
  enable_pull_timer
  run_final_upgrade

  if [[ "${was_already_joined}" == "false" ]]; then
    print_ad_reboot_warning
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
