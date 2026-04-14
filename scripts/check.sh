#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${REPO_ROOT}/.venv"

if [[ ! -x "${VENV_DIR}/bin/pre-commit" ]]; then
  echo "Missing ${VENV_DIR}/bin/pre-commit." >&2
  echo "Run ./scripts/setup-dev.sh first." >&2
  exit 1
fi

cd "${REPO_ROOT}"
export PRE_COMMIT_HOME="${REPO_ROOT}/.pre-commit-cache"
export PATH="${VENV_DIR}/bin:${PATH}"

exec "${VENV_DIR}/bin/pre-commit" run --all-files
