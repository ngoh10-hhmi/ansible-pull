#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_BIN="${REPO_ROOT}/.venv/bin"
FAILURES=0
WARNINGS=0

pass() {
  printf 'PASS: %s\n' "$1"
}

warn() {
  printf 'WARN: %s\n' "$1"
  WARNINGS=$((WARNINGS + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

check_repo_venv() {
  if [[ -d "${VENV_BIN}" ]]; then
    pass "repo virtualenv exists at .venv"
  else
    fail "repo virtualenv is missing; run ./scripts/setup-dev.sh first"
  fi
}

check_repo_tool() {
  local name="$1"
  local path="${VENV_BIN}/${name}"

  if [[ -x "${path}" ]]; then
    pass "${name} is available in the repo virtualenv"
  else
    fail "${name} is missing from the repo virtualenv; rerun ./scripts/setup-dev.sh"
  fi
}

check_system_tool() {
  local name="$1"

  if command -v "${name}" >/dev/null 2>&1; then
    pass "${name} is available on PATH"
  else
    fail "${name} is missing from PATH"
  fi
}

check_optional_gh_auth() {
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh is not installed; GitHub CLI checks are skipped"
    return
  fi

  if gh auth status >/dev/null 2>&1; then
    pass "gh authentication is healthy"
  else
    warn "gh is installed but not authenticated; run gh auth login if you need GitHub CLI access"
  fi
}

check_managed_workstation_state() {
  local env_file="/etc/ansible/pull.env"
  local bootstrap_vars="/etc/ansible/bootstrap-vars.yml"

  if [[ ! -e "${env_file}" && ! -e "${bootstrap_vars}" ]]; then
    warn "managed workstation files are not present; skipping /etc/ansible checks"
    return
  fi

  if [[ -f "${env_file}" ]]; then
    pass "${env_file} exists"
  else
    fail "${env_file} is missing"
  fi

  if [[ -f "${bootstrap_vars}" ]]; then
    pass "${bootstrap_vars} exists"
  else
    fail "${bootstrap_vars} is missing"
  fi
}

print_summary() {
  printf '\nSummary: %s failure(s), %s warning(s)\n' "${FAILURES}" "${WARNINGS}"

  if [[ "${FAILURES}" -gt 0 ]]; then
    exit 1
  fi
}

main() {
  cd "${REPO_ROOT}"
  check_repo_venv
  check_repo_tool pre-commit
  check_repo_tool ansible-playbook
  check_repo_tool ansible-lint
  check_system_tool shellcheck
  check_optional_gh_auth
  check_managed_workstation_state
  print_summary
}

main "$@"
