#!/usr/bin/env bash
set -euo pipefail

# Static file locations used by scheduled ansible-pull runs.
ENV_FILE="/etc/ansible/pull.env"
BOOTSTRAP_VARS_FILE="/etc/ansible/bootstrap-vars.yml"

# Runtime variables loaded and built from ENV_FILE.
HOSTNAME_SHORT=""
HOSTNAME_FQDN=""
RUN_LOG=""
RUNTIME_INVENTORY=""
LOCK_FILE=""
TARGET_HOST=""
ANSIBLE_PLAYBOOK_BIN=""
PLAYBOOK_ARGS=()
RUN_STATUS="starting"
CURRENT_PHASE="starting"
RUN_STARTED_AT=0

# Load configured pull settings from /etc/ansible/pull.env.
load_environment() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Missing ${ENV_FILE}" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1091
  # shellcheck source=/etc/ansible/pull.env
  source "${ENV_FILE}"
  set +a
}

# Prepare directories and derive per-host runtime file paths.
prepare_runtime_context() {
  mkdir -p "${DEST}" "${LOG_DIR}"

  HOSTNAME_SHORT="$(hostname -s)"
  HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
  RUN_LOG="${LOG_DIR}/ansible-pull-${HOSTNAME_SHORT}.log"
  RUNTIME_INVENTORY="${DEST}/inventory/runtime-hosts.yml"
  LOCK_FILE="/var/lock/ansible-pull.lock"
  TARGET_HOST="${HOSTNAME_SHORT}"
  ANSIBLE_PLAYBOOK_BIN="${ANSIBLE_PLAYBOOK_BIN:-$(command -v ansible-playbook || true)}"
  RUN_STARTED_AT="$(date +%s)"

  if [[ -z "${ANSIBLE_PLAYBOOK_BIN}" ]]; then
    echo "ansible-playbook was not found in PATH" >&2
    exit 1
  fi
}

# Duplicate output to the per-host logfile and stdout/stderr so systemd can
# capture the same stream in journald.
setup_logging() {
  touch "${RUN_LOG}"
  exec > >(tee -a "${RUN_LOG}") 2>&1
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

elapsed_seconds() {
  local now

  now="$(date +%s)"
  if [[ "${RUN_STARTED_AT:-0}" -le 0 ]]; then
    echo 0
    return
  fi

  echo "$((now - RUN_STARTED_AT))"
}

format_duration() {
  local total_seconds="${1:-0}"
  local hours=0
  local minutes=0
  local seconds=0

  if [[ "${total_seconds}" -lt 0 ]]; then
    total_seconds=0
  fi

  hours="$((total_seconds / 3600))"
  minutes="$(((total_seconds % 3600) / 60))"
  seconds="$((total_seconds % 60))"

  if [[ "${hours}" -gt 0 ]]; then
    printf '%dh %02dm %02ds' "${hours}" "${minutes}" "${seconds}"
  elif [[ "${minutes}" -gt 0 ]]; then
    printf '%dm %02ds' "${minutes}" "${seconds}"
  else
    printf '%ds' "${seconds}"
  fi
}

extract_last_matching_line() {
  local pattern="$1"
  local line=""

  if [[ ! -f "${RUN_LOG:-}" ]]; then
    return 1
  fi

  line="$(grep -E "${pattern}" "${RUN_LOG}" | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 1
  printf '%s\n' "${line}"
}

extract_last_task_name() {
  local task_line=""
  local task_name=""

  task_line="$(extract_last_matching_line '^TASK \[' || true)"
  [[ -n "${task_line}" ]] || return 1

  task_name="$(printf '%s\n' "${task_line}" | sed -E 's/^TASK \[(.*)\] \*+$/\1/')"
  if [[ "${task_name}" == "${task_line}" ]]; then
    task_name="${task_line#TASK [}"
    task_name="${task_name%%]*}"
  fi

  printf '%s\n' "${task_name}"
}

extract_block_from_last_match() {
  local pattern="$1"
  local max_lines="$2"
  local matched_line=""
  local start_line=""
  local end_line=""

  if [[ ! -f "${RUN_LOG:-}" ]]; then
    return 1
  fi

  matched_line="$(grep -n -E "${pattern}" "${RUN_LOG}" | tail -n 1 || true)"
  [[ -n "${matched_line}" ]] || return 1

  start_line="${matched_line%%:*}"
  end_line="$((start_line + max_lines - 1))"

  sed -n "${start_line},${end_line}p" "${RUN_LOG}" | awk '
    /^PLAY RECAP/ { exit }
    NR > 1 && /^[[:space:]]*$/ { exit }
    { print }
  '
}

truncate_text() {
  local text="$1"
  local max_chars="${2:-800}"

  if [[ "${#text}" -le "${max_chars}" ]]; then
    printf '%s' "${text}"
    return
  fi

  printf '%s\n...' "${text:0:max_chars}"
}

extract_failure_excerpt() {
  local excerpt=""

  excerpt="$(extract_block_from_last_match '^fatal: \[' 6 || true)"
  if [[ -z "${excerpt}" ]]; then
    excerpt="$(extract_block_from_last_match '^ERROR!' 6 || true)"
  fi
  if [[ -z "${excerpt}" ]]; then
    excerpt="$(extract_block_from_last_match '^fatal:' 3 || true)"
  fi
  if [[ -z "${excerpt}" && -f "${RUN_LOG:-}" ]]; then
    excerpt="$(tail -n 12 "${RUN_LOG}" | awk '!/^\[[0-9]{4}-[0-9]{2}-[0-9]{2} / { print }' | tail -n 8 || true)"
  fi
  if [[ -z "${excerpt}" && -f "${RUN_LOG:-}" ]]; then
    excerpt="$(tail -n 8 "${RUN_LOG}" || true)"
  fi

  [[ -n "${excerpt}" ]] || return 1
  printf '%s\n' "${excerpt}"
}

build_success_notification_text() {
  local duration

  duration="$(format_duration "$(elapsed_seconds)")"

  cat <<EOF
Completed ansible-pull run successfully on \`${HOSTNAME_SHORT}\`.

*Branch:* \`${BRANCH:-unknown}\`
*Duration:* \`${duration}\`
*Log:* \`${RUN_LOG}\`
EOF
}

build_failure_notification_text() {
  local exit_code="$1"
  local duration=""
  local task_name=""
  local excerpt=""

  duration="$(format_duration "$(elapsed_seconds)")"
  task_name="$(extract_last_task_name || true)"
  excerpt="$(extract_failure_excerpt || true)"

  cat <<EOF
ansible-pull run failed on \`${HOSTNAME_SHORT}\`.

*Branch:* \`${BRANCH:-unknown}\`
*Phase:* \`${CURRENT_PHASE:-unknown}\`
*Exit code:* \`${exit_code}\`
*Duration:* \`${duration}\`
${task_name:+*Task:* \`${task_name}\`}
*Log:* \`${RUN_LOG}\`
${excerpt:+
*Error excerpt:*
\`\`\`
$(truncate_text "${excerpt}" 900)
\`\`\`}
EOF
}

log_failure_summary() {
  local exit_code="$1"
  local task_name=""
  local excerpt=""

  task_name="$(extract_last_task_name || true)"
  excerpt="$(extract_failure_excerpt || true)"

  log "Failure context: phase=${CURRENT_PHASE:-unknown}, exit_code=${exit_code}${task_name:+, task=${task_name}}."
  if [[ -n "${excerpt}" ]]; then
    log "Failure excerpt:"
    while IFS= read -r line; do
      log "  ${line}"
    done <<<"${excerpt}"
  fi
}

build_slack_payload() {
  local status="$1"
  local title="$2"
  local msg="$3"
  local color="#36a64f"

  if [[ "${status}" != "success" ]]; then
    color="#ff0000"
  fi

  python3 - "${color}" "${title}" "${msg}" <<'PY'
import json
import sys

color, title, text = sys.argv[1:4]
print(
    json.dumps(
        {
            "attachments": [
                {
                    "color": color,
                    "title": title,
                    "text": text,
                    "mrkdwn_in": ["text"],
                }
            ]
        }
    )
)
PY
}

notify_slack() {
  local status="$1"
  local msg="$2"
  local payload=""

  if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    return
  fi

  if [[ "${status}" == "success" && "${SLACK_NOTIFY_SUCCESS:-false}" != "true" ]]; then
    log "Skipping Slack notification for success (SLACK_NOTIFY_SUCCESS is not true)."
    return
  fi

  log "Sending Slack notification (status: ${status})..."

  payload="$(build_slack_payload "${status}" "ansible-pull on ${HOSTNAME_SHORT}" "${msg}")"

  if curl \
    --silent \
    --show-error \
    --fail \
    --retry 2 \
    --retry-delay 1 \
    --connect-timeout 5 \
    --max-time 15 \
    -X POST \
    -H 'Content-type: application/json' \
    --data "${payload}" \
    "${SLACK_WEBHOOK_URL}"; then
    log "Slack notification sent successfully."
  else
    log "Warning: Failed to send Slack notification."
  fi
}

finish() {
  local exit_code=$?
  local success_message=""
  local failure_message=""

  case "${RUN_STATUS}" in
    success)
      log "Completed ansible-pull run successfully."
      success_message="$(build_success_notification_text)"
      notify_slack "success" "${success_message}"
      ;;
    locked)
      log "Skipped ansible-pull run because another run is already in progress."
      ;;
    *)
      if [[ "${exit_code}" -eq 0 ]]; then
        log "Completed ansible-pull run."
        success_message="$(build_success_notification_text)"
        notify_slack "success" "${success_message}"
      else
        failure_message="$(build_failure_notification_text "${exit_code}")"
        log "ansible-pull run failed with exit code ${exit_code}."
        log_failure_summary "${exit_code}"
        notify_slack "failed" "${failure_message}"
      fi
      ;;
  esac
}

build_playbook_args() {
  PLAYBOOK_ARGS=(
    --inventory "${RUNTIME_INVENTORY}"
    --limit "${TARGET_HOST}"
    -e ansible_python_interpreter=/usr/bin/python3
  )

  if [[ -f "${BOOTSTRAP_VARS_FILE}" ]]; then
    PLAYBOOK_ARGS+=(--extra-vars "@${BOOTSTRAP_VARS_FILE}")
  fi
}

# Build a local inventory that can match localhost/hostname/FQDN host_vars.
write_runtime_inventory() {
  mkdir -p "$(dirname "${RUNTIME_INVENTORY}")"

  cat > "${RUNTIME_INVENTORY}" <<EOF
all:
  hosts:
    localhost:
      ansible_connection: local
      ansible_python_interpreter: /usr/bin/python3
    ${HOSTNAME_SHORT}:
      ansible_connection: local
      ansible_python_interpreter: /usr/bin/python3
    ${HOSTNAME_FQDN}:
      ansible_connection: local
      ansible_python_interpreter: /usr/bin/python3
EOF
}

# Select the inventory host that should receive host_vars for this machine.
select_target_host() {
  if [[ -f "${DEST}/inventory/host_vars/${HOSTNAME_SHORT}.yml" ]]; then
    TARGET_HOST="${HOSTNAME_SHORT}"
  elif [[ -f "${DEST}/inventory/host_vars/${HOSTNAME_FQDN}.yml" ]]; then
    TARGET_HOST="${HOSTNAME_FQDN}"
  fi

  log "Using runtime inventory host '${TARGET_HOST}' for host_vars resolution."
}

# Prevent overlapping runs from timer/manual invocations.
acquire_lock_or_exit() {
  exec 9>"${LOCK_FILE}"

  if ! flock -n 9; then
    RUN_STATUS="locked"
    log "Another ansible-pull run is already in progress. Exiting."
    exit 0
  fi
}

# Sync the local checkout to the latest state of the configured branch.
sync_repository_checkout() {
  if [[ -d "${DEST}/.git" ]]; then
    rm -f "${DEST}/.git/index.lock" "${DEST}/.git/shallow.lock" "${DEST}/.git/HEAD.lock"
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
    git clone --branch "${BRANCH}" "${REPO_URL}" "${DEST}"
  fi
}

# Execute the configured playbook with consistent local-connection arguments.
run_playbook() {
  cd "${DEST}"

  "${ANSIBLE_PLAYBOOK_BIN}" \
    "${PLAYBOOK_ARGS[@]}" \
    "${PLAYBOOK}" "$@"
}

# Main scheduled/manual ansible-pull run flow.
main() {
  load_environment
  prepare_runtime_context
  setup_logging
  trap finish EXIT
  CURRENT_PHASE="acquire_lock"
  acquire_lock_or_exit

  log "Starting ansible-pull run for host '${HOSTNAME_SHORT}' on branch '${BRANCH}'."
  CURRENT_PHASE="sync_repository_checkout"
  sync_repository_checkout
  CURRENT_PHASE="write_runtime_inventory"
  write_runtime_inventory
  CURRENT_PHASE="select_target_host"
  select_target_host
  CURRENT_PHASE="build_playbook_args"
  build_playbook_args
  CURRENT_PHASE="run_playbook"
  run_playbook "$@"
  CURRENT_PHASE="complete"
  RUN_STATUS="success"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
