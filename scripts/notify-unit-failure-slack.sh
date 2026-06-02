#!/usr/bin/env bash
set -euo pipefail

# Post a Slack alert when a scheduled maintenance unit fails.
#
# Wired in via `OnFailure=ansible-pull-slack-notify@%n.service` on the
# timer-driven maintenance units (managed-package-updates, browser-package-
# updates, apt-refresh). Those units run outside the ansible-pull wrapper, so
# without this a failure (e.g. SSSD left dead after a package upgrade) only
# lands in the journal and nobody is told. The pull wrapper keeps doing its own
# Slack notification; this covers the units the wrapper does not run.
#
# Intentionally self-contained -- one script + one templated unit + the
# OnFailure lines -- so the whole feature can be removed cleanly later by
# flipping base_maintenance_failure_slack_notify_enabled to false (or deleting
# the three pieces) if it is no longer wanted.
#
# Reads SLACK_WEBHOOK_URL from /etc/ansible/pull.env. If no webhook is
# configured it exits 0 (nothing to do) so it never turns a maintenance failure
# into a second failure.

# Maximum characters of failure context to embed in the Slack message, leaving
# headroom under Slack's per-attachment text limits.
CONTEXT_MAX_CHARS=2500

# Where to read the pull settings from. Resolved at call time (not source time)
# so the ANSIBLE_PULL_* overrides work no matter when they are exported.
env_file_path() {
  printf '%s' "${ANSIBLE_PULL_ENV_FILE:-/etc/ansible/pull.env}"
}

envfile_lib_path() {
  printf '%s' "${ANSIBLE_PULL_ENVFILE_LIB:-/usr/local/lib/ansible-pull/envfile.sh}"
}

load_webhook() {
  local envfile_lib=""

  # Honor an already-exported webhook (used by tests) before reading the file.
  if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    return 0
  fi

  envfile_lib="$(envfile_lib_path)"
  if [[ -f "${envfile_lib}" ]]; then
    # shellcheck disable=SC1090
    source "${envfile_lib}"
    # load_env_file uses `set -a` so KEY=VALUE lines become environment vars.
    load_env_file "$(env_file_path)" >/dev/null 2>&1 || true
  fi
}

# Collect a compact failure context: the unit's current state plus the tail of
# its journal. Both are best-effort; missing tools must not abort the alert.
gather_context() {
  local unit="$1"
  local unit_status="" journal_tail=""

  unit_status="$(systemctl status "${unit}" --no-pager --lines=0 2>&1 | head -n 12 || true)"
  journal_tail="$(journalctl -u "${unit}" --no-pager --lines=25 2>&1 | tail -n 25 || true)"

  printf '%s\n\n--- recent journal ---\n%s\n' "${unit_status}" "${journal_tail}"
}

truncate_context() {
  local text="$1"

  if (( ${#text} > CONTEXT_MAX_CHARS )); then
    printf '%s\n...' "${text:0:CONTEXT_MAX_CHARS}"
  else
    printf '%s' "${text}"
  fi
}

build_payload() {
  local host="$1"
  local text="$2"

  # Build the JSON via python3 so quotes/newlines/backslashes in the journal
  # excerpt are serialized correctly rather than hand-escaped in shell.
  python3 - "${host}" "${text}" <<'PY'
import json
import sys

host, text = sys.argv[1:3]
print(
    json.dumps(
        {
            "attachments": [
                {
                    "color": "#ff0000",
                    "title": f"ansible-pull maintenance failure on {host}",
                    "text": text,
                    "mrkdwn_in": ["text"],
                }
            ]
        }
    )
)
PY
}

send_alert() {
  local unit="$1"
  local host="" context="" text="" payload=""

  host="$(hostname -s 2>/dev/null || hostname || echo unknown)"
  context="$(truncate_context "$(gather_context "${unit}")")"

  text="Maintenance unit \`${unit}\` failed on \`${host}\`.

\`\`\`
${context}
\`\`\`"

  payload="$(build_payload "${host}" "${text}")"

  if curl \
    --silent \
    --show-error \
    --fail \
    --retry 2 \
    --retry-delay 1 \
    --connect-timeout 5 \
    --max-time 15 \
    -X POST \
    -H 'Content-type: application/json' \
    --data "${payload}" \
    "${SLACK_WEBHOOK_URL}"; then
    echo "Sent Slack failure alert for ${unit}."
  else
    echo "Warning: failed to send Slack alert for ${unit}." >&2
  fi
}

main() {
  local unit="${1:-}"

  if [[ -z "${unit}" ]]; then
    echo "Usage: notify-unit-failure-slack.sh <unit-name>" >&2
    exit 2
  fi

  load_webhook

  if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    echo "No SLACK_WEBHOOK_URL configured in $(env_file_path); skipping Slack alert for ${unit}."
    exit 0
  fi

  send_alert "${unit}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
