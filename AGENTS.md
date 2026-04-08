# AGENTS.md

These instructions apply to the entire repository.

## Purpose

This repo manages Ubuntu workstations with `ansible-pull`.

- Machines clone the repo locally and apply configuration with a `systemd` timer.
- The main playbook is `playbooks/workstation.yml`.
- The repo currently includes HHMI-specific Active Directory enrollment and SSSD configuration.

## Repo shape

- `scripts/bootstrap-ubuntu.sh`: first-run bootstrap on a fresh Ubuntu machine
- `scripts/run-ansible-pull.sh`: recurring/manual convergence wrapper
- `scripts/switch-pull-branch.sh`: updates branch/repo settings on an enrolled machine
- `roles/base/tasks/main.yml`: baseline packages, timers, unattended-upgrades, local users
- `roles/base/tasks/ad_join.yml`: HHMI AD join and SSSD configuration
- `inventory/group_vars/all.yml`: shared workstation baseline
- `inventory/host_vars/<hostname>.yml`: host-specific exceptions
- `tests/integration/test_workstation.py`: current integration coverage

## Validation

Install the pinned toolchain:

```bash
python -m pip install -r requirements-dev.txt
```

Run the same local checks CI runs:

```bash
pre-commit run --all-files
```

Useful single checks:

```bash
pre-commit run yamllint
pre-commit run ansible-lint
pre-commit run ansible-syntax-check
pre-commit run shellcheck
```

Integration tests require root on a bootstrapped Ubuntu host:

```bash
sudo -E env "PATH=$PATH" python -m pytest -q tests/integration
```

CI currently runs:

- pre-commit checks on every PR and on pushes to `main` and `testing`
- integration coverage on Ubuntu 22.04 and 24.04

## Operational model

Bootstrap flow:

1. `scripts/bootstrap-ubuntu.sh` installs bootstrap dependencies.
2. It writes `/etc/ansible/pull.env`.
3. It clones the repo into `/var/lib/ansible-pull`.
4. It prompts for hostname, machine type, and optional sudo users.
5. It writes `/etc/ansible/bootstrap-vars.yml`.
6. It runs `/usr/local/sbin/run-ansible-pull`.
7. It then collects AD credentials, performs domain enrollment, enables the timer, and does a final package upgrade.

Scheduled run flow:

1. `ansible-pull.timer` starts `ansible-pull.service`.
2. The service runs `/usr/local/sbin/run-ansible-pull`.
3. The wrapper loads `/etc/ansible/pull.env`, acquires a `flock`, syncs the checkout, writes a runtime inventory, and runs `ansible-playbook`.

Variable precedence:

- `/etc/ansible/bootstrap-vars.yml` is passed as `--extra-vars @file`.
- That means bootstrap-persisted values override role defaults and inventory vars.
- `switch-pull-branch.sh` must keep `/etc/ansible/pull.env` and `/etc/ansible/bootstrap-vars.yml` aligned.

Inventory behavior:

- `inventory/hosts.yml` is mainly for CI and syntax checks.
- Real pull runs generate `${DEST}/inventory/runtime-hosts.yml`.
- Host-specific vars resolve against the machine's short hostname or FQDN during runtime.

## Invariants and gotchas

- Treat `/var/lib/ansible-pull` as disposable runtime state. Pull runs do `git reset --hard` and `git clean -fdx`.
- Do not store persistent local state in the runtime checkout.
- The wrapper writes to both `/var/log/ansible-pull/ansible-pull-<hostname>.log` and stdout/stderr, so systemd service runs should be visible in both the logfile and `journalctl -u ansible-pull.service`.
- `ansible-pull.service` is timer-driven; do not redesign it as a directly enabled long-running service without intent.
- The empty `base_workstation_base_packages` default in `roles/base/defaults/main.yml` is intentional. The active baseline lives in `inventory/group_vars/all.yml`.
- Unattended upgrades are currently security-only and configured on a 30-day cadence. Non-security upgrades are manual unless `base_apt_maintenance_enabled` is turned on.
- The repo does not manage snap refresh policy. Firefox may be outside the APT-managed path.
- The AD join path currently assumes HHMI-specific DNS, realm, and SSSD behavior. Changes there are high risk and should be treated as operational changes, not cosmetic refactors.
- `base_local_sudo_users` is currently handled through the `user` module in the base role. Be explicit about whether a change is meant for local accounts or directory-backed access.
- AD-backed sudo access is currently modeled through sudoers entries and groups in `roles/base/tasks/ad_join.yml`, not through separate account creation logic.

## Change rules

- If you change bootstrap behavior, also update `scripts/bootstrap-ubuntu.sh`, `scripts/run-ansible-pull.sh`, the relevant docs, and this file.
- If you change timer behavior or branch-switching behavior, update tests and operator docs in the same change.
- If you change AD enrollment, DNS handling, SSSD config, or sudo policy, call out the operational impact clearly.
- Prefer host overrides with `base_workstation_extra_packages` over replacing the entire baseline package list.
- Keep secrets out of the repository. If private repo access is needed, credentials belong on the machine, not in Git.

## Known coverage gaps

The current automated coverage is useful but incomplete. It does not fully exercise:

- AD enrollment end to end
- third-party APT repository onboarding
- sudo policy edge cases
- full idempotency across repeated real-world bootstrap and timer runs

When changing those areas, rely on targeted manual validation in addition to CI.
