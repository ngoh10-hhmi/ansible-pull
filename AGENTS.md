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
- `docs/slack-webhook-setup.md`: operator guide for optional Slack notifications
- `roles/base/tasks/main.yml`: baseline packages, timers, unattended-upgrades, local users
- `roles/base/tasks/ad_join.yml`: HHMI AD join and SSSD configuration
- `inventory/group_vars/all.yml`: shared workstation baseline
- `inventory/host_vars/<hostname>.yml`: host-specific exceptions
- `tests/integration/test_workstation.py`: current integration coverage

## Orientation

If you need a fast repo walkthrough, start here:

- `docs/how-it-works.md`: plain-English explanation of bootstrap, pull runs, and role structure
- `docs/dev-setup.md`: repo-local developer environment and check workflow
- `docs/variable-map.md`: where the main variables are usually set and consumed
- `docs/troubleshooting.md`: local and workstation troubleshooting steps
- `docs/worktree-setup.md`: recommended `testing` plus `main` Git worktree layout
- `docs/slack-webhook-setup.md`: Slack webhook setup and behavior

## Validation

Preferred local setup:

```bash
./scripts/setup-dev.sh
make doctor
```

Manual toolchain install if you are not using the helper:

```bash
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install -U pip
python -m pip install -r requirements-dev.txt
```

Run the same local checks CI runs:

```bash
PRE_COMMIT_HOME=.pre-commit-cache pre-commit run --all-files
```

Equivalent Make target:

```bash
make lint
```

Useful single checks:

```bash
pre-commit run --all-files
pre-commit run yamllint
pre-commit run ansible-lint
pre-commit run ansible-syntax-check
pre-commit run shellcheck
```

Integration tests require root on a converged Ubuntu host. The common local path
is a bootstrapped workstation:

```bash
make integration
```

CI currently runs:

- pre-commit checks on every PR and on pushes to `main` and `testing`
- integration coverage on Ubuntu 22.04 and 24.04

Common local workflow:

```bash
./scripts/setup-dev.sh
make doctor
make lint
```

Dependency and CI-tooling changes usually involve:

- `requirements-ci.txt`
- `requirements-dev.txt`
- `.github/workflows/ansible-lint.yml`
- `.pre-commit-config.yaml`

## Operational model

Bootstrap flow:

1. `scripts/bootstrap-ubuntu.sh` installs bootstrap dependencies.
2. It clones the repo into `/var/lib/ansible-pull`.
3. It installs `/usr/local/sbin/run-ansible-pull` plus its shared helper libraries.
4. It writes `/etc/ansible/pull.env` through the shared env-file helper.
5. It prompts for hostname, machine type, and optional sudo users.
6. It writes an initial `/etc/ansible/bootstrap-vars.yml` with `base_ad_enroll: false`.
7. It runs `/usr/local/sbin/run-ansible-pull`.
8. It then collects AD credentials, writes a temporary AD-phase bootstrap state, and performs the AD enrollment converge.
9. It rewrites the final stable bootstrap vars without one-time sudo keys, enables the timer, and does a final package upgrade.

Bootstrap-only sudo-user choices are applied during the AD enrollment
converge after NSS/SSSD can resolve them, but they are not kept in the final
persisted bootstrap vars for later scheduled runs.

Bootstrap now treats timer enablement as required. If `ansible-pull.timer`
cannot be enabled, bootstrap should fail loudly rather than silently
continuing.

Bootstrap also supports optional Slack notification settings through
`--slack-webhook` and `--slack-notify-success`, which are persisted into
`/etc/ansible/pull.env`.

Scheduled run flow:

1. `ansible-pull.timer` starts `ansible-pull.service`.
2. The service runs `/usr/local/sbin/run-ansible-pull`.
3. The wrapper loads `/etc/ansible/pull.env`, acquires a `flock`, syncs the checkout, writes a runtime inventory, and runs `ansible-playbook`.
4. If `SLACK_WEBHOOK_URL` is set, the wrapper can send Slack notifications on
   failures. Failure notifications can include the wrapper phase, last detected
   Ansible task, a short error excerpt, and the local logfile path when that
   context is available. Success notifications are opt-in through
   `SLACK_NOTIFY_SUCCESS=true`.

Variable precedence:

- `/etc/ansible/bootstrap-vars.yml` is passed as `--extra-vars @file`.
- That means bootstrap-persisted values override role defaults and inventory vars.
- `switch-pull-branch.sh` must keep `/etc/ansible/pull.env` and `/etc/ansible/bootstrap-vars.yml` aligned.
- `switch-pull-branch.sh` preserves Slack-related values stored in
  `/etc/ansible/pull.env`.
- `/etc/ansible/pull.env` is shell-escaped through a shared helper and should
  still be treated as machine-local runtime state rather than hand-maintained
  configuration.

Inventory behavior:

- `inventory/hosts.yml` is mainly for CI and syntax checks.
- Real pull runs generate `${DEST}/inventory/runtime-hosts.yml`.
- Host-specific vars resolve against the machine's short hostname or FQDN during runtime.

Recommended Git workflow:

- Keep active changes in a `testing` worktree.
- Keep a separate clean `main` worktree for reference and merge comparison.
- Use temporary feature worktrees only for isolated or risky changes.

## Invariants and gotchas

- Treat `/var/lib/ansible-pull` as disposable runtime state. Pull runs do `git reset --hard` and `git clean -fdx`.
- Do not store persistent local state in the runtime checkout.
- The wrapper writes to both `/var/log/ansible-pull/ansible-pull-<hostname>.log` and stdout/stderr, so systemd service runs should be visible in both the logfile and `journalctl -u ansible-pull.service`.
- The base role also installs `/etc/logrotate.d/ansible-pull`; those logs are
  rotated weekly and compressed. Keep that in mind when giving debugging or
  retention advice.
- `ansible-pull.service` is timer-driven; do not redesign it as a directly enabled long-running service without intent.
- The empty `base_workstation_base_packages` default in `roles/base/defaults/main.yml` is intentional. The active baseline lives in `inventory/group_vars/all.yml`.
- `ansible-pull` currently checks in every 15 minutes. A dedicated `apt-refresh.timer` refreshes APT package lists hourly, `managed-package-updates.timer` upgrades installed packages from `base_workstation_base_packages` daily, `browser-package-updates.timer` upgrades installed browser APT packages from `base_browser_update_packages` and installed browser snaps from `base_browser_update_snaps` daily, and unattended security upgrades remain on a 30-day cadence.
- The repo does not manage general snap refresh policy. The browser timer only targets named installed browser snaps such as Firefox.
- The AD join path currently assumes HHMI-specific DNS, realm, and SSSD behavior. Changes there are high risk and should be treated as operational changes, not cosmetic refactors.
- Bootstrap-only local sudo-group updates happen during bootstrap after AD/SSSD
  is configured so requested usernames can resolve through NSS.
- Those bootstrap sudo-user choices are intentionally not persisted for later
  scheduled converges.
- The final `apt-get upgrade -y` in bootstrap is intentional because bootstrap
  is expected to run on freshly imaged HHMI systems that should be brought
  current immediately.
- `base_sudo_users` and `base_local_sudo_users` may still exist on older hosts
  as legacy state, but scheduled converges should not keep re-applying them.
- AD-backed sudo access is still also modeled through sudoers entries and groups in `roles/base/tasks/ad_join.yml` when `ad_sudo_group` is used.
- Slack webhook secrets must stay out of Git. `SLACK_WEBHOOK_URL` belongs in
  `/etc/ansible/pull.env`, not in inventory or committed files.

## Change rules

- If you change bootstrap behavior, also update `scripts/bootstrap-ubuntu.sh`, `scripts/run-ansible-pull.sh`, the relevant docs, and this file.
- If you change timer behavior or branch-switching behavior, update tests and operator docs in the same change.
- If you change Slack notification behavior or `/etc/ansible/pull.env` handling,
  also update `scripts/bootstrap-ubuntu.sh`, `scripts/run-ansible-pull.sh`,
  `scripts/switch-pull-branch.sh`, `docs/slack-webhook-setup.md`, and any
  relevant troubleshooting docs.
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
