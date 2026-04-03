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

  if [[ -z "${ANSIBLE_PLAYBOOK_BIN}" ]]; then
    echo "ansible-playbook was not found in PATH" >&2
    exit 1
  fi
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
}

# Prevent overlapping runs from timer/manual invocations.
acquire_lock_or_exit() {
  exec 9>"${LOCK_FILE}"

  if ! flock -n 9; then
    {
      echo "Another ansible-pull run is already in progress. Exiting."
    } >> "${RUN_LOG}"
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
  acquire_lock_or_exit

  {
    echo "Starting Ansible Pull at $(date '+%Y-%m-%d %H:%M:%S')"
    sync_repository_checkout
    write_runtime_inventory
    select_target_host
    build_playbook_args
    run_playbook "$@"
  } >> "${RUN_LOG}" 2>&1
}

main "$@"
