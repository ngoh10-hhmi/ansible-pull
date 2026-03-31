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

exec /usr/bin/ansible-pull \
  --url "${REPO_URL}" \
  --checkout "${BRANCH}" \
  --directory "${DEST}" \
  --inventory "${RUNTIME_INVENTORY}" \
  --limit localhost \
  --accept-host-key \
  --clean \
  -e ansible_python_interpreter=/usr/bin/python3 \
  "${PLAYBOOK}" >> "${RUN_LOG}" 2>&1
