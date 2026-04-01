#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/ansible/pull.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

mkdir -p "${DEST}" "${LOG_DIR}"

HOSTNAME_SHORT="$(hostname -s)"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
RUN_LOG="${LOG_DIR}/ansible-pull-${HOSTNAME_SHORT}.log"
RUNTIME_INVENTORY="/etc/ansible/pull-inventory.yml"
LOCK_FILE="/var/lock/ansible-pull.lock"

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

exec 9>"${LOCK_FILE}"

if ! flock -n 9; then
  {
    echo "Another ansible-pull run is already in progress. Exiting."
  } >> "${RUN_LOG}"
  exit 0
fi

{
  echo "Starting Ansible Pull at $(date '+%Y-%m-%d %H:%M:%S')"

  if [[ -d "${DEST}/.git" ]]; then
    rm -f "${DEST}/.git/index.lock" "${DEST}/.git/shallow.lock" "${DEST}/.git/HEAD.lock"
    git -C "${DEST}" fetch origin "${BRANCH}"
    git -C "${DEST}" checkout "${BRANCH}"
    git -C "${DEST}" reset --hard "origin/${BRANCH}"
  else
    rm -rf "${DEST}"
    git clone --branch "${BRANCH}" "${REPO_URL}" "${DEST}"
  fi

  cd "${DEST}"

  /usr/bin/ansible-playbook \
    --inventory "${RUNTIME_INVENTORY}" \
    --limit localhost \
    -e ansible_python_interpreter=/usr/bin/python3 \
    "${PLAYBOOK}" "$@"
} >> "${RUN_LOG}" 2>&1
