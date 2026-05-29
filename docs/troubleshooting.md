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

## SSSD fails to start on Ubuntu 26.04

Ubuntu 26.04 runs SSSD as the unprivileged `sssd` user. If the daemon cannot
read `/etc/krb5.keytab` or `/etc/sssd/sssd.conf`, `sssd_be` exits at startup
and the converge fails on the `systemctl is-active sssd` check.

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
