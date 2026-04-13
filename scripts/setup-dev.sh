#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${REPO_ROOT}/.venv"
PYTHON_BIN=""

die() {
  echo "$*" >&2
  exit 1
}

pick_python() {
  if command -v python3.11 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3.11)"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    local version
    version="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    if [[ "${version}" == "3.11" || "${version}" == "3.12" || "${version}" == "3.13" ]]; then
      PYTHON_BIN="$(command -v python3)"
      return
    fi
  fi

  die "Python 3.11 or newer is required. Install python3.11 and rerun this script."
}

check_shellcheck() {
  if command -v shellcheck >/dev/null 2>&1; then
    return
  fi

  case "$(uname -s)" in
    Darwin)
      die "shellcheck is required. Install it with: brew install shellcheck"
      ;;
    Linux)
      die "shellcheck is required. Install it with your package manager and rerun this script."
      ;;
    *)
      die "shellcheck is required. Install it and rerun this script."
      ;;
  esac
}

main() {
  pick_python
  check_shellcheck

  cd "${REPO_ROOT}"
  "${PYTHON_BIN}" -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/python" -m pip install -U pip
  "${VENV_DIR}/bin/python" -m pip install -r requirements-dev.txt

  export PRE_COMMIT_HOME="${REPO_ROOT}/.pre-commit-cache"
  export PATH="${VENV_DIR}/bin:${PATH}"
  "${VENV_DIR}/bin/pre-commit" install

  cat <<EOF
Developer setup complete.

Next commands:
  source .venv/bin/activate
  ./scripts/check.sh
EOF
}

main "$@"
