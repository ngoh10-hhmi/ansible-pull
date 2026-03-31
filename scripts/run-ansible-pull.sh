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
RUN_LOG="${LOG_DIR}/ansible-pull-${HOSTNAME_SHORT}.log"

exec /usr/bin/ansible-pull \
  --url "${REPO_URL}" \
  --checkout "${BRANCH}" \
  --directory "${DEST}" \
  --inventory localhost, \
  --limit localhost \
  --accept-host-key \
  --clean \
  "${PLAYBOOK}" >> "${RUN_LOG}" 2>&1
