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
  local candidate version major minor

  for candidate in python3.12 python3.13 python3.14 python3; do
    if ! command -v "${candidate}" >/dev/null 2>&1; then
      continue
    fi

    version="$("${candidate}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    IFS=. read -r major minor <<<"${version}"
    if [[ "${major}" -eq 3 && "${minor}" -ge 12 ]]; then
      PYTHON_BIN="$(command -v "${candidate}")"
      return
    fi
  done

  die "Python 3.12 or newer is required. Install Python 3.12+ and rerun this script."
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
