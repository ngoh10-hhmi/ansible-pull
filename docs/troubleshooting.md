# Troubleshooting

Use this page when local checks or scheduled workstation runs are not behaving
the way you expect.

## Local developer environment

Start with the repo doctor check:

```bash
make doctor
```

That verifies:

- the repo-local `.venv` exists
- `pre-commit`, `ansible-playbook`, and `ansible-lint` are available from that virtualenv
- `shellcheck` is installed on the machine
- `gh` is installed and authenticated if you use the GitHub CLI

If `make doctor` reports a missing virtualenv, rebuild it with:

```bash
./scripts/setup-dev.sh
```

If local checks still fail, run:

```bash
make lint
```

That runs the same `pre-commit` checks CI uses.

## Force a managed workstation run

On a bootstrapped workstation, force an immediate convergence with:

```bash
sudo /usr/local/sbin/run-ansible-pull
```

Inspect the most recent service output with:

```bash
journalctl -u ansible-pull.service -n 100 --no-pager
tail -n 100 /var/log/ansible-pull/ansible-pull-$(hostname -s).log
```

The wrapper writes to both journald and the per-host logfile.

## Bootstrap-specific failures

If first-run bootstrap fails, inspect:

```bash
sudo cat /etc/ansible/pull.env
sudo cat /etc/ansible/bootstrap-vars.yml
systemctl status ansible-pull.timer
journalctl -u ansible-pull.service -n 100 --no-pager
```

Bootstrap now treats timer enablement as required. If the machine finished AD
enrollment but `ansible-pull.timer` is not enabled, treat the bootstrap as
incomplete and fix that before relying on scheduled converges.

Re-running `bootstrap-ubuntu.sh` on a machine that is already joined to
`hhmi.org` is safe: the script detects the existing realm membership via
`realm list`, skips the AD credential prompt and the reboot warning, and runs
a single converge with `base_ad_enroll: true`. Use this when you need to
finish or repeat the post-AD steps (timer enablement, final upgrade) after a
partial bootstrap.

A re-run also preserves operator-set values already in `/etc/ansible/pull.env`
(the Slack webhook, and the selected branch/playbook) unless you override them
with the matching flag — so it will not wipe a configured webhook. Pass
`--reset-env` if you instead want bootstrap to rebuild `pull.env` from flags and
defaults (a clean-slate repair). Note a re-run still re-converges the whole
machine; to only add a webhook, edit `/etc/ansible/pull.env` directly (see the
Slack webhook guide) rather than re-running bootstrap.

## SSSD fails to start on Ubuntu 26.04+

Ubuntu 26.04 runs SSSD as the unprivileged `sssd` user, and later releases keep
that model. The role applies the group-readable SSSD permissions when the host
reports Ubuntu 26.04 or newer (a `>=` version test, so point releases like
26.04.1 are covered); older Ubuntu releases keep `root:root 0600` even if an
`sssd` group exists locally.
If the daemon cannot read `/etc/krb5.keytab` or `/etc/sssd/sssd.conf`,
`sssd_be` exits at startup and the converge fails on the `systemctl is-active
sssd` check.

Expected permissions after a healthy converge:

```bash
stat -c '%U:%G %a' /etc/krb5.keytab        # root:sssd 640
stat -c '%U:%G %a' /etc/sssd/sssd.conf     # root:sssd 640
getent group sssd                          # must exist
```

If those values are wrong, re-run `sudo /usr/local/sbin/run-ansible-pull` —
the role re-applies them every converge. If the daemon still refuses to start,
check `journalctl -u sssd -n 100 --no-pager` for the failing file path; the
common culprit is a Kerberos-related file the role does not yet manage (for
example a manually placed `/etc/sssd/conf.d/*.conf` drop-in that is still
`root:root 0600`).

## SSSD left dead after a managed package upgrade

The daily `managed-package-updates.timer` runs
`upgrade-installed-apt-packages` against `base_workstation_base_packages`,
which includes `sssd`, `sssd-common`, and `sssd-tools`. When an SSSD security
update lands, dpkg restarts the daemon **mid-transaction** — while its provider
plugins and helper binaries (`sssd-ad`, the `ldap_child` executable) are only
half-swapped. That restart loads a mismatched shared object and `sssd_be`
exits:

```
sss_atomic_read_s() failed … Module [ad] constructor failed [5]: Input/output error
Unable to load target [id] [80]: Accessing a corrupted shared library
sssd: Exiting the SSSD. Could not restart critical service [hhmi.org].
```

Nothing in dpkg retries the restart afterward, so SSSD stays down — and AD
users cannot log in — until the daemon is restarted cleanly against the
now-consistent binaries.

The signature is distinctive: SSSD failed during a `*-updates`/`-security`
package upgrade window (~03:00), file permissions on `/etc/krb5.keytab` and
`/etc/sssd/sssd.conf` are correct, and a plain `sudo systemctl restart sssd`
fixes it with no config change. Confirm the upgrade with:

```bash
grep -iE 'sssd|libsss' /var/log/dpkg.log* | grep "$(date +%F)"
journalctl --since today --no-pager | grep -iE 'managed-package-updates|Could not restart critical'
```

Immediate recovery:

```bash
sudo systemctl restart sssd
systemctl is-active sssd
```

The upgrade helper now guards against this automatically: after upgrading any
package listed in `base_managed_package_updates_restart_verify` (SSSD by
default), it does one clean `systemctl restart` plus an `is-active` check once
the transaction settles, and exits non-zero if the service does not come back.
A genuine failure therefore fails `managed-package-updates.service`, which
fires the `OnFailure` Slack notifier (see below), and is also caught by the next
converge's `Verify SSSD is active after restart` task. To extend the guard to
another auth-critical service, add an entry to
`base_managed_package_updates_restart_verify`.

## Slack alerts for failed maintenance units

The timer-driven maintenance units (`managed-package-updates`,
`browser-package-updates`, `apt-refresh`) run outside the `run-ansible-pull`
wrapper, so their failures do not go through the wrapper's Slack path. Each one
instead carries `OnFailure=ansible-pull-slack-notify@%n.service`, which runs
`/usr/local/sbin/notify-unit-failure-slack` with the failed unit name. The
notifier reads `SLACK_WEBHOOK_URL` from `/etc/ansible/pull.env` (the same
webhook the pull wrapper uses) and posts the unit status plus a short journal
excerpt. With no webhook configured it is a silent no-op.

Verify or exercise it:

```bash
# Confirm the wiring and the helper:
systemctl cat managed-package-updates.service | grep OnFailure
test -x /usr/local/sbin/notify-unit-failure-slack && echo helper-present

# Dry-run the notification for a unit (posts to Slack if a webhook is set):
sudo /usr/local/sbin/notify-unit-failure-slack managed-package-updates.service
```

To turn the feature off, set `base_maintenance_failure_slack_notify_enabled:
false` (drops the `OnFailure` wiring on the next converge).

## Check timer state

Verify that the pull timer is installed, enabled, and scheduled:

```bash
systemctl status ansible-pull.timer
systemctl list-timers ansible-pull.timer
systemctl cat ansible-pull.timer
```

For the refresh and targeted-update timers:

```bash
systemctl status apt-refresh.timer
systemctl status managed-package-updates.timer
systemctl status browser-package-updates.timer
```

## Check which host_vars file should apply

Runtime pull runs do not use `inventory/hosts.yml`. They generate a local
runtime inventory and select host vars in this order:

1. `inventory/host_vars/<short-hostname>.yml`
2. `inventory/host_vars/<fqdn>.yml`
3. no host-specific file if neither exists

To see the names the machine will use:

```bash
hostname -s
hostname -f
```

To see whether matching files exist in the runtime checkout:

```bash
ls /var/lib/ansible-pull/inventory/host_vars/$(hostname -s).yml
ls /var/lib/ansible-pull/inventory/host_vars/$(hostname -f).yml
```

To inspect the generated runtime inventory:

```bash
sudo cat /var/lib/ansible-pull/inventory/runtime-hosts.yml
```

Recent runs also log the selected runtime inventory host in the
`ansible-pull.service` output.

## Check branch and repo settings

The scheduled pull wrapper reads:

- `/etc/ansible/pull.env`
- `/etc/ansible/bootstrap-vars.yml`

If branch switching looks wrong, inspect both files:

```bash
sudo cat /etc/ansible/pull.env
sudo cat /etc/ansible/bootstrap-vars.yml
```

Those files must stay aligned. `switch-pull-branch.sh` updates both.

## Check Slack notification settings

If Slack alerts are missing or too noisy, inspect the runtime settings:

```bash
sudo grep '^SLACK_' /etc/ansible/pull.env
```

By default, only failed runs notify Slack. Set `SLACK_NOTIFY_SUCCESS=true` if
you want success notifications too.

Recent failure notifications can include the wrapper phase, the last detected
Ansible task, a short error excerpt, and the local logfile path. If the Slack
message is still too short, inspect the referenced logfile or journal output
for the full failure context.

## Common local check issues

- `shellcheck` missing:
  install it first, for example `brew install shellcheck` on macOS
- `.venv` missing:
  rerun `./scripts/setup-dev.sh`
- `gh auth status` fails:
  rerun `gh auth login` if you need GitHub CLI access
- `pre-commit` cache path is not writable:
  run with `PRE_COMMIT_HOME=.pre-commit-cache`
