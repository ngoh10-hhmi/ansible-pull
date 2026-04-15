# Onboarding a New Ubuntu Workstation

## 1. Set the shared baseline

Edit [inventory/group_vars/all.yml](../inventory/group_vars/all.yml) for settings that should apply to every Ubuntu workstation.

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

## 2. Add host-specific variables only if needed

Create:

`inventory/host_vars/<hostname>.yml`

Example:

```yaml
base_workstation_extra_packages:
  - htop
```

If a machine needs no special settings yet, you can skip this.

## 3. Decide how the machine will read the repo

Preferred order:

1. GitHub public repo over HTTPS with no credential
2. GitHub private repo over HTTPS with a read-only token
3. GitHub private repo over SSH only if you already want per-device key management

For your current plan, use a public HTTPS repo and no GitHub credential at all.

## 4. Copy bootstrap files to the machine

You only need [bootstrap-ubuntu.sh](../scripts/bootstrap-ubuntu.sh). It performs the initial clone itself.

## 5. Bootstrap

Run:

```bash
curl -fsSL https://raw.githubusercontent.com/ngoh10-hhmi/ansible-pull/main/scripts/bootstrap-ubuntu.sh -o /tmp/bootstrap-ubuntu.sh
chmod +x /tmp/bootstrap-ubuntu.sh
sudo /tmp/bootstrap-ubuntu.sh \
  --repo https://github.com/ngoh10-hhmi/ansible-pull.git \
  --branch main
```

If the repo becomes private later, rerun the bootstrap with `--github-user` and `--github-token-file`.
The bootstrap prompts require an AD username and hidden password for the `hhmi.org` domain join, and they also let you nominate usernames that should be added to the local `sudo` group once the join completes. That list can include AD usernames if they resolve through SSSD after enrollment.

## 6. Verify

Check:

```bash
systemctl status ansible-pull.timer
systemctl list-timers ansible-pull.timer
journalctl -u ansible-pull.service -n 100 --no-pager
tail -n 100 /var/log/ansible-pull/ansible-pull-$(hostname -s).log
```

The pull wrapper now writes to both journald and the per-host logfile, so either view should show the same run output.

## 7. Ongoing workflow

- Make repo changes in Git
- Merge to `main`
- Let the timer apply them automatically
- Use one test laptop before rolling changes to everyone

## What this setup updates

- Ubuntu security updates
- Daily targeted upgrades for installed packages from `base_workstation_base_packages`
- Daily targeted upgrades for installed browser packages from `base_browser_update_packages`
- Daily targeted refreshes for installed browser snaps from `base_browser_update_snaps`

By default, `ansible-pull` checks in every 15 minutes. A dedicated hourly systemd timer refreshes APT package lists, managed baseline packages upgrade daily, configured browser packages upgrade daily only when already installed, configured browser snaps refresh daily only when already installed, and unattended upgrades remain security-only on a 30-day cadence. This does not automatically manage general snap refresh policy.

## Private repo later

If you later hide the repo or add private configuration:

```bash
sudo ./bootstrap-ubuntu.sh \
  --repo https://github.com/YOUR_ORG/YOUR_REPO.git \
  --branch main \
  --github-user YOUR_GITHUB_MACHINE_USER \
  --github-token-file /root/github-read-token.txt
```

Using a token file is safer than passing the token directly on the command line.

## Guardrails for early success

- Avoid managing everything at once
- Keep secrets out of the repo
- Prefer package install and security patching before deeper OS policy changes
- Run `pre-commit` before pushing changes so local checks match CI

See [docs/first-workstation.md](first-workstation.md) for the exact first-machine rollout.
See [docs/targeted-package-updates.md](targeted-package-updates.md) for how to handle packages that sit outside the shared baseline and browser exception lists.
