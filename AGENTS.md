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
- `scripts/lib/envfile.sh`: reads/writes `/etc/ansible/pull.env` and validates the `bootstrap-vars.yml` schema
- `scripts/lib/git_sync.sh`: checkout/clone helper; verifies HEAD matches the requested ref after every reset
- `scripts/doctor.sh`: fast local and managed-host sanity check (invoked by `make doctor` and on workstations)
- `scripts/apt-refresh.sh` / `scripts/upgrade-installed-apt-packages.sh` / `scripts/update-installed-browsers.sh`: helpers behind the hourly/daily maintenance timers
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

Python 3.12 or newer is required. `.python-version` pins 3.12 for local
development, and CI runs the matrix against both 3.12 and 3.14, so anything
that depends on 3.12-only behavior will fail in CI.

Manual toolchain install if you are not using the helper:

```bash
python3.12 -m venv .venv
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
4. It prompts for an optional Slack webhook URL (unless `--slack-webhook` was supplied; blank skips notifications) and writes `/etc/ansible/pull.env` through the shared env-file helper.
5. It prompts for hostname, machine type, and optional sudo users, then prints a summary and asks for confirmation (answering no restarts the prompts).
6. It checks if the host is already joined to Active Directory (via `realm list`).
7. If not joined, it writes an initial `/etc/ansible/bootstrap-vars.yml` with `base_ad_enroll: false`, runs `/usr/local/sbin/run-ansible-pull`, prompts for AD credentials (stripping a trailing `@hhmi.org`/`@HHMI.ORG` realm suffix if present, and aborting if any other realm is supplied), performs the AD enrollment converge, and rewrites the final stable bootstrap vars.
8. If already joined, it skips Phase 1 and the credential prompt, writes the final bootstrap vars directly (with `base_ad_enroll: true`), and runs a single converge.
9. It enables the timer, does a final package upgrade, and prints the reboot warning (skipped if already joined).

Bootstrap-time sudo-group membership is handled entirely by the bootstrap
script (`add_bootstrap_sudo_users`), not the role, and runs once after the AD
join + SSSD are up (the first point a domain account can be confirmed to
exist). Each requested name is validated with `getent passwd` (retried for
SSSD cache warmup) and added with `gpasswd -a`; a name that does not resolve in
AD is reported and the whole list is reprompted interactively (it does not
abort the converge), while a `gpasswd` failure on a name that *did* resolve is
fatal. The membership is a persistent OS-level change, so it remains after
bootstrap, and it is never written into `/etc/ansible/bootstrap-vars.yml`, so
scheduled converges do not re-assert it. The old role-side
`base_sudo_users` / NSS-tolerance path is gone — do not reintroduce it.

Bootstrap now treats timer enablement as required. If `ansible-pull.timer`
cannot be enabled, bootstrap should fail loudly rather than silently
continuing.

Bootstrap also supports optional Slack notification settings through
`--slack-webhook` and `--slack-notify-success`, which are persisted into
`/etc/ansible/pull.env`. When `--slack-webhook` is not supplied, bootstrap
prompts for the webhook URL interactively (blank skips it).

Re-running bootstrap is non-destructive to operator-configured `pull.env`
values: before parsing CLI flags it seeds settings from any existing
`/etc/ansible/pull.env`, so precedence is CLI flag > existing value > built-in
default. A re-run therefore preserves the Slack webhook and a previously
selected branch/playbook unless the matching flag overrides them. Pass
`--reset-env` to skip that seeding and rebuild `pull.env` purely from flags and
defaults (the clean-slate repair path). This mirrors how `switch-pull-branch.sh`
already preserves Slack values.

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
- `/etc/ansible/pull.env` is shell-escaped through a shared helper, written
  mode `0600`, and should be treated as machine-local runtime state rather
  than hand-maintained configuration.

Bootstrap-vars schema:

- `run-ansible-pull` and `switch-pull-branch.sh` both validate
  `/etc/ansible/bootstrap-vars.yml` via `validate_bootstrap_vars_file` in
  `scripts/lib/envfile.sh` before doing work, so a corrupted or hand-edited
  file fails fast rather than silently driving a converge against bad config.
- The five `base_ansible_pull_*` keys (repo URL, branch, playbook, directory,
  log dir) are required for any converge.
- `target_hostname` and `machine_type` (`laptop` or `desktop`) are required
  only when `base_ad_enroll: true`; non-AD converges omit them.
- The branch field must be a valid branch name or a 40-char hex SHA.

Per-host package list files (created and managed by the role under
`/etc/ansible/`, consumed by the maintenance timers):

- `managed-package-updates.list`: drives `managed-package-updates.timer`
- `browser-package-updates.list`: APT browser upgrade list
- `browser-snap-updates.list`: snap browser refresh list

Comments (`#`) and blank lines are filtered out by the helper scripts, so the
files can be edited and commented like normal config.

Inventory behavior:

- `inventory/hosts.yml` is mainly for CI and syntax checks.
- Real pull runs generate `${DEST}/inventory/runtime-hosts.yml`.
- Host-specific vars resolve against the machine's short hostname or FQDN during runtime.

Recommended Git workflow:

- Keep active changes in a `testing` worktree.
- Keep a separate clean `main` worktree for reference and merge comparison.
- Use temporary feature worktrees only for isolated or risky changes.
- When the user says `git yeet`, interpret that as: commit the relevant local
  changes and push them to the current branch's upstream if a push is the next
  obvious Git step.

## Rollback and pin-to-commit

When a `testing` or `main` push breaks workstations, there are two recovery
paths:

**1. Switch back to the previous branch**

```bash
sudo /usr/local/sbin/switch-pull-branch --branch main --run-now
```

This reverts all workstations to the last known-good branch. The downside is
that any unmerged changes in `testing` are left behind.

**2. Pin to a specific commit**

```bash
sudo /usr/local/sbin/switch-pull-branch --commit <sha> --run-now
```

Pinning to a commit SHA is useful when you want to:
- Roll back to a known-good commit on a branch that has since regressed
- Temporarily freeze a workstation on a specific commit while debugging
- Deploy a specific fix without merging it into a release branch

The commit SHA is stored in `/etc/ansible/pull.env` and
`/etc/ansible/bootstrap-vars.yml` under `BRANCH`, so the ansible-pull
wrapper treats it as a ref to fetch and checkout. Future scheduled runs stay
on that commit until an operator switches the branch back.

**3. Bootstrap with a commit pin**

For new machines or re-imaged workstations, use `--commit` during bootstrap
instead of `--branch`:

```bash
sudo /tmp/bootstrap-ubuntu.sh \
  --repo https://github.com/ngoh10-hhmi/ansible-pull.git \
  --commit 0123456789abcdef0123456789abcdef01234567
```

When a commit is pinned, the checkout uses a detached HEAD and the sync helper
resets to that exact SHA on every run, so it never drifts forward.

## Invariants and gotchas

- Treat `/var/lib/ansible-pull` as disposable runtime state. Pull runs do `git reset --hard` and `git clean -fdx`.
- Do not store persistent local state in the runtime checkout.
- The wrapper writes to both `/var/log/ansible-pull/ansible-pull-<hostname>.log` and stdout/stderr, so systemd service runs should be visible in both the logfile and `journalctl -u ansible-pull.service`.
- The base role also installs `/etc/logrotate.d/ansible-pull`; those logs are
  rotated weekly and compressed. Keep that in mind when giving debugging or
  retention advice.
- `bootstrap-ubuntu.sh` and `switch-pull-branch.sh` log every invocation to
  syslog under tags `ansible-pull-bootstrap` and `ansible-pull-switch-branch`
  with the invoking user (`SUDO_USER`) and arguments. Secret-bearing flag
  values (`--github-token`, `--slack-webhook`) are redacted to `***REDACTED***`
  before logging so credentials never land in the audit trail. Use
  `journalctl -t ansible-pull-bootstrap` (or the switch-branch tag) for the
  audit trail. Best-effort: if `logger` is missing the script still runs.
- Interactive bootstrap prompts go through the `prompt_line` helper, which
  re-prompts on an invalid value and aborts with a clear reason on EOF (closed
  stdin, a non-interactive run, or Ctrl-D) rather than looping forever.
  Usernames (sudo and AD) are format-checked with `is_valid_username`, the AD
  realm suffix is validated, and the kinit retry is capped. Preserve this
  fail-loud, never-hang contract when adding or refactoring prompts.
- Git checkouts are verified against the resolved expected ref after every
  `git reset --hard` via `git_verify_head_matches_ref` in `scripts/lib/git_sync.sh`.
  A partial git operation that leaves the tree on the wrong commit fails the
  sync rather than running ansible against drifted code.
- If bootstrap aborts before its successful terminal state, the trap scrubs
  `/root/.git-credentials-ansible-pull` and the corresponding
  `git config --global credential.helper` entry. On the success path those
  stay in place for the runtime wrapper to use on private-repo pulls.
- `update-installed-browsers.sh` refreshes snaps individually so a single bad
  snap does not block the others. Failures are aggregated and printed; the
  unit returns non-zero if any snap failed so systemd marks it failed.
- The APT helpers (`apt-refresh.sh` and `upgrade-installed-apt-packages.sh`)
  pass `DPkg::Lock::Timeout=600` so they wait up to 10 minutes for the dpkg
  lock instead of failing immediately when another timer-driven or
  ansible-pull APT operation is mid-flight.
- `ansible-pull.service` is timer-driven; do not redesign it as a directly enabled long-running service without intent.
- The empty `base_workstation_base_packages` default in `roles/base/defaults/main.yml` is intentional. The active baseline lives in `inventory/group_vars/all.yml`.
- `ansible-pull` currently checks in every 15 minutes. A dedicated `apt-refresh.timer` refreshes APT package lists hourly, `managed-package-updates.timer` upgrades installed packages from `base_workstation_base_packages` daily, `browser-package-updates.timer` upgrades installed browser APT packages from `base_browser_update_packages` and installed browser snaps from `base_browser_update_snaps` daily, and unattended security upgrades remain on a 30-day cadence.
- The repo does not manage general snap refresh policy. The browser timer only targets named installed browser snaps such as Firefox.
- The AD join path currently assumes HHMI-specific DNS, realm, and SSSD behavior. Changes there are high risk and should be treated as operational changes, not cosmetic refactors.
- Ubuntu 26.04 ships SSSD as a non-root service running under the package-provisioned `sssd` user, and later releases keep that model. The role gates this behavior on Ubuntu **26.04 and newer** (`version('26.04', '>=')`, so point releases like 26.04.1 and future releases are covered without a code change), confirms the `sssd` group exists on those releases, and sets `/etc/krb5.keytab` and `/etc/sssd/sssd.conf` to `root:sssd` mode `0640` so the daemon can read them. The legacy `root:root 0600` permissions apply on older releases even if an `sssd` group exists locally. Any future Kerberos-adjacent file the role manages (e.g. `/etc/sssd/conf.d/*` drop-ins) must be ownership-gated the same way or SSSD will fail to start on 26.04+.
- After SSSD is restarted by the AD-join handler the role asserts `systemctl is-active sssd` so a permissions regression fails the converge immediately instead of surfacing at next login.
- `managed-package-updates.timer` upgrades the SSSD package set (it is in `base_workstation_base_packages`). dpkg restarts SSSD mid-transaction against half-swapped provider plugins, which can leave the daemon dead with no clean restart and break AD login until the next manual/converge restart. `base_managed_package_updates_restart_verify` makes `upgrade-installed-apt-packages` snapshot each service's `trigger_packages` before/after the apt transaction, then do one clean restart + `is-active` check of that service when any trigger package changed (including dependency upgrades), and exit non-zero otherwise. Keep SSSD (and any future auth-critical daemon whose packages are in the baseline) in that list rather than excluding it from upgrades.
- The timer-driven maintenance units (`managed-package-updates`, `browser-package-updates`, `apt-refresh`) run outside `run-ansible-pull`, so they do not get the wrapper's Slack notification. Each carries `OnFailure=ansible-pull-slack-notify@%n.service`, a templated unit that runs `/usr/local/sbin/notify-unit-failure-slack` (reads `SLACK_WEBHOOK_URL` from `/etc/ansible/pull.env`; no-op without a webhook). The notifier template intentionally has no `OnFailure` of its own to avoid recursion. The whole feature (helper + template unit + the `OnFailure` lines) is gated on `base_maintenance_failure_slack_notify_enabled` so it can be removed cleanly. Do not add `OnFailure` to `ansible-pull.service` — the wrapper already self-notifies and a second hook would double-alert.
- Bootstrap-time sudo-group membership is handled entirely by the bootstrap
  script (`add_bootstrap_sudo_users`), not the role. It runs after the AD join +
  SSSD are up (the first point a domain account can be confirmed to exist),
  validates each requested name with `getent passwd` (retried for SSSD cache
  warmup), and adds it with `gpasswd -a`. A name that does not resolve in AD is
  reported by name and the whole list is reprompted interactively — it does not
  abort the converge. A `gpasswd` failure on a name that *did* resolve is fatal
  (unexpected). The group membership persists at the OS level afterward.
- Local accounts that will be created later are intentionally out of scope:
  `gpasswd` cannot add an account that does not exist yet, so create the user
  and run `usermod -aG sudo <user>` by hand after bootstrap. Do not reintroduce
  the old role-side `base_bootstrap_sudo_users` / NSS-tolerance path to work
  around this — it silently no-op'd on exactly these names.
- The final `apt-get upgrade -y` in bootstrap is intentional because bootstrap
  is expected to run on freshly imaged HHMI systems that should be brought
  current immediately. It is non-fatal: by that point AD enrollment, the timer,
  and the final bootstrap-vars state are all in place, so a transient
  mirror/network failure during the upgrade warns rather than failing the whole
  bootstrap.
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
