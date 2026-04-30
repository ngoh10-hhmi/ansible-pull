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

# Validate the structure of /etc/ansible/bootstrap-vars.yml before passing it
# to ansible-playbook via --extra-vars. Catches malformed YAML, missing
# required keys, and obviously wrong values (e.g. non-laptop/desktop
# machine_type) so a corrupted bootstrap state fails fast rather than
# silently running ansible-pull against bad config.
validate_bootstrap_vars_file() {
  local vars_file="$1"

  if [[ ! -f "${vars_file}" ]]; then
    echo "Missing ${vars_file}" >&2
    return 1
  fi

  python3 - "${vars_file}" <<'PY'
import re
import sys

try:
    import yaml
except ImportError:
    print(
        "python3 yaml module is required to validate bootstrap-vars; "
        "install python3-yaml or ansible.",
        file=sys.stderr,
    )
    sys.exit(2)

path = sys.argv[1]
try:
    with open(path) as fh:
        data = yaml.safe_load(fh)
except yaml.YAMLError as exc:
    print(f"Bootstrap vars file {path} is not valid YAML: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print(f"Bootstrap vars file {path} must be a YAML mapping.", file=sys.stderr)
    sys.exit(1)

# Pull-side keys are required for any converge. target_hostname /
# machine_type are only consumed by the AD enrollment path
# (roles/base/tasks/ad_join.yml asserts them when base_ad_enroll is true),
# so non-AD converges and the integration test harness should not be
# forced to provide them.
required_string_keys = [
    "base_ansible_pull_repo_url",
    "base_ansible_pull_branch",
    "base_ansible_pull_playbook",
    "base_ansible_pull_directory",
    "base_ansible_pull_log_dir",
]
if data.get("base_ad_enroll") is True:
    required_string_keys += ["target_hostname", "machine_type"]

errors = []
for key in required_string_keys:
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        errors.append(f"missing or empty required key: {key}")

machine_type = data.get("machine_type")
if machine_type is not None and (
    not isinstance(machine_type, str) or machine_type not in ("laptop", "desktop")
):
    errors.append(
        f"machine_type must be 'laptop' or 'desktop' (got {machine_type!r})"
    )

branch = data.get("base_ansible_pull_branch")
if isinstance(branch, str) and branch.strip():
    is_sha = bool(re.fullmatch(r"[0-9A-Fa-f]{40}", branch))
    is_branch = bool(re.fullmatch(r"[A-Za-z0-9._/+@-]+", branch))
    if not (is_sha or is_branch):
        errors.append(
            f"base_ansible_pull_branch is not a recognizable branch name "
            f"or 40-char SHA: {branch!r}"
        )

if errors:
    for line in errors:
        print(f"Invalid {path}: {line}", file=sys.stderr)
    sys.exit(1)
PY
}
