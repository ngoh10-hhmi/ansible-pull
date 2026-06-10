#!/usr/bin/env bash
# install-slack-webhook: backfill SLACK_WEBHOOK_URL into
# /etc/ansible/pull.env from an AD-protected SMB share, using the
# running operator's Kerberos ticket.
#
# Run this AS YOUR NORMAL AD USER (not via sudo) once per host. The
# share is ACL'd to users, and SSSD keeps user TGTs in a KEYRING that
# root cannot read; sudo will not work here. The script invokes sudo
# only for the final write to /etc/ansible/pull.env.
#
# Share location and file path are loaded from
# /etc/ansible/slack-webhook.conf, dropped by the base role from
# inventory/group_vars/all.yml.

set -euo pipefail

CONF=/etc/ansible/slack-webhook.conf
PULL_ENV=/etc/ansible/pull.env

if [[ "${EUID}" -eq 0 ]]; then
  cat >&2 <<'EOF'
install-slack-webhook must run as your normal AD user, not root.
SSSD keeps your Kerberos ticket in a per-session KEYRING cache that
root cannot read. Exit any sudo shell and re-run this command as
yourself; the script will sudo only for the final pull.env write.
EOF
  exit 2
fi

if [[ ! -r "${CONF}" ]]; then
  echo "Missing or unreadable ${CONF}. Has the base role converged on this host?" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "${CONF}"

: "${SHARE_HOST:?SHARE_HOST is unset in ${CONF}}"
: "${SHARE_NAME:?SHARE_NAME is unset in ${CONF}}"
: "${SHARE_FILE:?SHARE_FILE is unset in ${CONF}}"

for cmd in smbclient klist sudo python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Required command '${cmd}' not found on PATH." >&2
    exit 1
  fi
done

if sudo grep -q '^SLACK_WEBHOOK_URL=https' "${PULL_ENV}" 2>/dev/null; then
  echo "${PULL_ENV} already has SLACK_WEBHOOK_URL set; nothing to do."
  exit 0
fi

if ! klist -s 2>/dev/null; then
  cat >&2 <<'EOF'
No Kerberos ticket available for your user. The share read needs a
valid TGT. Try one of:
  - Log out and back in (PAM/SSSD will mint a fresh TGT for you).
  - Run 'kinit' to mint one manually.
Then re-run install-slack-webhook.
EOF
  exit 1
fi

# smbclient prints the file contents to stdout when the destination
# is "-". --quiet suppresses progress noise, --no-pass plus stdin
# redirected from /dev/null prevents the legacy "Password for ..."
# prompt from being mixed into stdout even though
# --use-kerberos=required already authenticates.
#
# Capture stdout and stderr separately. The fetch is the most likely thing
# to fail (no Kerberos access to the share, share/host typo, file missing),
# and the previous pipe-into-grep form let pipefail+errexit kill the script
# at the assignment with no diagnostic at all. Running smbclient on its own
# in an `if !` guard keeps errexit from firing and lets us surface smbclient's
# own error message.
smb_stderr="$(mktemp)"
trap 'rm -f "${smb_stderr}"' EXIT

if ! share_content="$(smbclient "//${SHARE_HOST}/${SHARE_NAME}" \
  --use-kerberos=required \
  --no-pass \
  --quiet \
  -c "get \"${SHARE_FILE}\" -" \
  </dev/null \
  2>"${smb_stderr}")"; then
  echo "Failed to read '${SHARE_FILE}' from //${SHARE_HOST}/${SHARE_NAME}." >&2
  if [[ -s "${smb_stderr}" ]]; then
    echo "smbclient reported:" >&2
    cat "${smb_stderr}" >&2
  fi
  echo "Check that you have a valid Kerberos ticket (klist) and access to the share." >&2
  exit 1
fi

# As a defence in depth, extract only the first
# https://hooks.slack.com/services/... token from the fetched content so any
# stray prompt or progress line cannot pollute the URL we persist. `|| true`
# keeps a no-match from tripping pipefail+errexit, so we reach the diagnostic
# below instead of dying silently when the file content is wrong.
webhook="$(printf '%s\n' "${share_content}" \
  | grep -oE 'https://hooks\.slack\.com/services/[A-Za-z0-9/_-]+' \
  | head -n1 || true)"

if [[ ! "${webhook}" =~ ^https://hooks\.slack\.com/services/ ]]; then
  echo "Fetched share content does not look like a Slack webhook URL." >&2
  exit 1
fi

# Persist via Python so we get atomic rename and avoid sed escape
# hazards if the URL ever grows new characters. The webhook is passed
# in argv (not env) to sidestep sudoers env stripping.
sudo python3 - "${webhook}" "${PULL_ENV}" <<'PYEOF'
import os
import re
import shutil
import sys
import tempfile

url, path = sys.argv[1], sys.argv[2]

try:
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
except FileNotFoundError:
    original = ""

new_line = f"SLACK_WEBHOOK_URL={url}"
updated, n = re.subn(
    r"^SLACK_WEBHOOK_URL=.*$",
    new_line,
    original,
    flags=re.MULTILINE,
)
if n == 0:
    if original and not original.endswith("\n"):
        original += "\n"
    updated = original + new_line + "\n"

target_dir = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".pull.env-", dir=target_dir)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(updated)
    os.chmod(tmp, 0o600)
    shutil.chown(tmp, "root", "root")
    os.replace(tmp, path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
PYEOF

echo "Slack webhook installed in ${PULL_ENV}."
echo "Next ansible-pull run (every 15 min via the timer, or sudo /usr/local/sbin/run-ansible-pull) will start emitting Slack notifications."
