#!/usr/bin/env bash

write_env_var_line() {
  local key="$1"
  local value="${2-}"

  printf '%s=' "${key}"
  printf '%q\n' "${value}"
}

write_pull_env_file() {
  local output_file="$1"
  local tmp_file=""

  tmp_file="$(mktemp)"

  {
    write_env_var_line "REPO_URL" "${REPO_URL:-}"
    write_env_var_line "BRANCH" "${BRANCH:-}"
    write_env_var_line "PLAYBOOK" "${PLAYBOOK:-}"
    write_env_var_line "DEST" "${DEST:-}"
    write_env_var_line "LOG_DIR" "${LOG_DIR:-}"
    write_env_var_line "SLACK_WEBHOOK_URL" "${SLACK_WEBHOOK_URL:-}"
    write_env_var_line "SLACK_NOTIFY_SUCCESS" "${SLACK_NOTIFY_SUCCESS:-false}"
  } > "${tmp_file}"

  install -m 0600 "${tmp_file}" "${output_file}"
  rm -f "${tmp_file}"
}

load_env_file() {
  local env_file="$1"

  if [[ ! -f "${env_file}" ]]; then
    echo "Missing ${env_file}" >&2
    return 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a
}

validate_pull_env() {
  local missing=()
  local var_name=""

  for var_name in REPO_URL BRANCH PLAYBOOK DEST LOG_DIR; do
    if [[ -z "${!var_name:-}" ]]; then
      missing+=("${var_name}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    printf 'Missing required ansible-pull settings: %s\n' "${missing[*]}" >&2
    return 1
  fi
}
