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

## Check timer state

Verify that the pull timer is installed, enabled, and scheduled:

```bash
systemctl status ansible-pull.timer
systemctl list-timers ansible-pull.timer
systemctl cat ansible-pull.timer
```

For the optional maintenance and refresh timers:

```bash
systemctl status apt-refresh.timer
systemctl status apt-maintenance.timer
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

## Common local check issues

- `shellcheck` missing:
  install it first, for example `brew install shellcheck` on macOS
- `.venv` missing:
  rerun `./scripts/setup-dev.sh`
- `gh auth status` fails:
  rerun `gh auth login` if you need GitHub CLI access
- `pre-commit` cache path is not writable:
  run with `PRE_COMMIT_HOME=.pre-commit-cache`
