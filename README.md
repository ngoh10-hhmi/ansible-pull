# Ubuntu Workstation Management with `ansible-pull`

This repository is a starter kit for managing Ubuntu laptops and workstations with `ansible-pull`.

It is now tuned for a security-updates-first rollout: keep the repo small, keep patching automatic, and avoid storing credentials in Git.
The default docs below assume you are starting with a public GitHub repo.

## What this gives you

- A simple `ansible-pull` bootstrap path for a brand new Ubuntu machine
- A base workstation role with security-first Ubuntu update defaults
- A shared baseline file for every machine, with optional per-host overrides
- A scheduled `systemd` timer so machines keep themselves updated from Git
- A place for host-specific settings in `inventory/host_vars/`
- Documentation for GitHub-hosted vs internally hosted Git repos

## Why `ansible-pull`

`ansible-pull` flips the usual Ansible model:

- `ansible` / push model: one control node connects to every machine
- `ansible-pull` / pull model: each machine pulls the repo and applies its own config

For laptops, roaming workstations, and machines that are not always on VPN, `ansible-pull` is often easier to operate.

## Recommended starting path

If you are new to Ansible, start here:

1. Keep one Git repo for all workstation config.
2. Use a single base playbook for every Ubuntu workstation.
3. Put shared settings in `inventory/group_vars/all.yml`.
4. Use `inventory/host_vars/<hostname>.yml` only for exceptions.
5. Start with a public HTTPS repo if the contents are safe to expose.
6. Let Ubuntu handle security updates locally, and use `ansible-pull` mainly to keep policy consistent.

That avoids having to stand up a full Ansible control node on day one.

If you want a plain-English walkthrough of how bootstrap, scheduled runs, the
`base` role, and variable precedence fit together, read
[docs/how-it-works.md](docs/how-it-works.md).
If you want a quick reference for the main configuration variables, read
[docs/variable-map.md](docs/variable-map.md).
If you need operator or local troubleshooting steps, read
[docs/troubleshooting.md](docs/troubleshooting.md).
If you want a simple Git worktree layout for `testing` and `main`, read
[docs/worktree-setup.md](docs/worktree-setup.md).

## Repository layout

- `ansible.cfg`: local Ansible defaults
- `docs/how-it-works.md`: plain-English repo walkthrough
- `docs/dev-setup.md`: local developer environment and check workflow
- `docs/troubleshooting.md`: local and workstation troubleshooting steps
- `docs/variable-map.md`: quick reference for the main variables
- `docs/worktree-setup.md`: recommended Git worktree layout for this repo
- `Makefile`: common local development commands
- `.python-version`: expected local Python version for developer tooling
- `playbooks/workstation.yml`: main workstation playbook
- `inventory/group_vars/all.yml`: shared settings for every Ubuntu workstation
- `roles/base/`: baseline Ubuntu workstation configuration
- `inventory/hosts.yml`: local inventory used by `ansible-pull`
- `inventory/host_vars/`: optional per-host overrides
- `scripts/bootstrap-ubuntu.sh`: first-run setup for a new Ubuntu machine
- `scripts/doctor.sh`: local and managed-workstation sanity checks
- `scripts/setup-dev.sh`: local developer setup helper
- `scripts/check.sh`: local wrapper for repo checks
- `scripts/run-ansible-pull.sh`: wrapper used by `systemd`
- `scripts/apt-maintenance.sh`: optional full-upgrade helper for non-security maintenance
- `docs/decision-guide.md`: GitHub vs internal Git hosting tradeoffs
- `docs/onboarding.md`: how to add and bootstrap a new workstation
- `docs/targeted-package-updates.md`: how to handle one-off package updates safely

## New development machine

On a new workstation or laptop where you want to work on this repo locally:

```bash
git clone https://github.com/ngoh10-hhmi/ansible-pull.git
cd ansible-pull
./scripts/setup-dev.sh
```

That will create the local virtualenv, install the pinned Python tooling,
verify `shellcheck`, and install the local `pre-commit` hook for this clone.

To verify the environment afterward:

```bash
make doctor
```

## Quick start

On a fresh Ubuntu workstation:

```bash
curl -fsSL https://raw.githubusercontent.com/ngoh10-hhmi/ansible-pull/main/scripts/bootstrap-ubuntu.sh -o /tmp/bootstrap-ubuntu.sh
chmod +x /tmp/bootstrap-ubuntu.sh
sudo /tmp/bootstrap-ubuntu.sh \
  --repo https://github.com/ngoh10-hhmi/ansible-pull.git \
  --branch main
```

The bootstrap script now performs the initial clone itself, so you only need this one file on a fresh machine.
During bootstrap it will ask for machine type, an AD username plus hidden password for the required `hhmi.org` domain join, and optional usernames that should be added to the local `sudo` group after the join completes.

If you later make the repo private, the same script supports a local read-only GitHub credential on the workstation. That credential stays on the machine and does not live in this repo.

## Testing branch workflow

Use a long-lived `testing` branch for workstation validation so you do not need to push experimental changes to `main`.

Create the branch once:

```bash
git checkout main
git pull
git checkout -b testing
git push -u origin testing
```

Bootstrap a test workstation against that branch:

```bash
curl -fsSL https://raw.githubusercontent.com/ngoh10-hhmi/ansible-pull/testing/scripts/bootstrap-ubuntu.sh -o /tmp/bootstrap-ubuntu.sh
chmod +x /tmp/bootstrap-ubuntu.sh
sudo /tmp/bootstrap-ubuntu.sh \
  --repo https://github.com/ngoh10-hhmi/ansible-pull.git \
  --branch testing
```

The bootstrap flow now persists the selected repo/branch into Ansible variables, so scheduled runs on that test machine stay on `testing` unless you intentionally re-bootstrap or change `/etc/ansible/bootstrap-vars.yml`.

To switch an existing machine between branches without re-bootstrap:

```bash
sudo /usr/local/sbin/switch-pull-branch --branch testing --run-now
sudo /usr/local/sbin/switch-pull-branch --branch main --run-now
```

## Run On Demand

To run `ansible-pull` immediately on a managed workstation:

```bash
sudo /usr/local/sbin/run-ansible-pull
```

To inspect the most recent run output:

```bash
journalctl -u ansible-pull.service -n 100 --no-pager
tail -n 100 /var/log/ansible-pull/ansible-pull-$(hostname -s).log
```

## Shared baseline

Edit [inventory/group_vars/all.yml](inventory/group_vars/all.yml) for settings that should apply to every workstation.

Example:

```yaml
base_workstation_base_packages:
  - ca-certificates
  - curl
  - git
  - python3
  - python3-apt
  - rsync
  - sudo
  - unattended-upgrades
  - wget

base_workstation_extra_packages: []
```

## Optional host-specific configuration

Create a file named after the machine hostname:

`inventory/host_vars/laptop-01.yml`

Example:

```yaml
base_workstation_extra_packages:
  - htop
ad_sudo_group: workstation-admins
base_local_sudo_users:
  - duckd-a
```

Use `base_workstation_extra_packages` to add packages on one host without replacing the fleet baseline. Use `base_workstation_base_packages` in a host file only when you truly want to replace the whole base list.

## Common edits

These are the most common day-to-day changes in this repo:

1. Add a package for every workstation:
   edit `inventory/group_vars/all.yml` and add it to `base_workstation_base_packages`
2. Add a package for one workstation:
   edit `inventory/host_vars/<hostname>.yml` and add it to `base_workstation_extra_packages`
3. Change the pull cadence:
   adjust `base_ansible_pull_timer_on_calendar`
4. Change unattended-upgrade timing:
   adjust `base_workstation_unattended_upgrade_days`
5. Switch one workstation to the testing branch:
   run `sudo /usr/local/sbin/switch-pull-branch --branch testing --run-now`

If you want the background on why those variables work that way, see
[docs/variable-map.md](docs/variable-map.md).

## What gets updated automatically

By default this repo is aimed at:

- Ubuntu security updates through `unattended-upgrades`
- APT-installed packages such as `openssh-server`
- Any browser or other app installed from an APT repository you explicitly manage

The shared package list in `inventory/group_vars/all.yml` is now the main place to define what every workstation should have. Host files should usually only use `base_workstation_extra_packages` for one-off additions.
`ansible-pull` checks in every 15 minutes. A dedicated hourly systemd timer refreshes APT package lists, while unattended upgrades remain security-only on a 30-day interval.

Important caveat:

- Firefox on modern Ubuntu is usually a snap, so it is not updated by the APT tasks in this repo.
- Google Chrome can be kept updated if you add Google's APT repository later.
- `ansible-pull` keeps config current; Ubuntu's package tools perform the actual updates.

For intentionally updating one package outside the security-only unattended policy, see [docs/targeted-package-updates.md](docs/targeted-package-updates.md).

## Switching to private later

Moving from public to private is straightforward if you keep secrets out of Git now.

At cutover time you would:

1. Make the GitHub repo private.
2. Put a read-only credential on each workstation.
3. Re-run [scripts/bootstrap-ubuntu.sh](scripts/bootstrap-ubuntu.sh) with `--github-user` and `--github-token-file`.
4. Run `ansible-pull` once manually to confirm access.

## Suggested rollout

1. Test this on one non-critical Ubuntu machine.
2. Keep the first scope small: security updates, OpenSSH, a few essential packages.
3. Add laptop-specific settings only after the base role is stable.
4. Once a few machines are healthy, decide whether GitHub private hosting is good enough or whether internal hosting is worth the extra operating overhead.

## Next improvements

- Add browser repository management if you want Chrome or other vendor packages patched here
- Tighten private-repo credential handling so pull access is scoped per machine or per repo
- Expand integration coverage for optional paths such as AD enrollment and third-party APT repositories

## Local checks

Set up the local developer environment:

```bash
make setup
```

Run the same checks used in CI:

```bash
make lint
```

Run the local doctor check when you want a faster sanity check first:

```bash
make doctor
```

If you want the checks to run automatically before each local commit:

```bash
pre-commit install
```

Notes:

- `pre-commit` runs locally. It does not upload anything to GitHub by itself.
- The pinned toolchain currently expects Python 3.11 or newer. If your default
  `python3` is older, use `python3.11` when creating the virtualenv.
- In this repo, the configured hooks use system-installed tools, so
  `shellcheck` must also be available on the machine.
- If you use the virtualenv approach above, activate it with
  `source .venv/bin/activate` before running `pre-commit`.

See [docs/dev-setup.md](docs/dev-setup.md) for the manual setup details and
[docs/troubleshooting.md](docs/troubleshooting.md) for common local or
workstation failure paths.
