# Onboarding a New Ubuntu Workstation

## 1. Set the shared baseline

Edit [vars/baseline.yml](/Users/ngoh10/Documents/ChatGPT_Projects/ansible-pull/vars/baseline.yml) for settings that should apply to every Ubuntu workstation.

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

base_workstation_optional_packages:
  - htop
  - vim

base_workstation_extra_optional_packages: []
```

## 2. Add host-specific variables only if needed

Create:

`inventory/host_vars/<hostname>.yml`

Example:

```yaml
base_workstation_extra_packages:
  - openssh-server

base_workstation_extra_optional_packages:
  - tailscale
```

If a machine needs no special settings yet, you can skip this.

## 3. Decide how the machine will read the repo

Preferred order:

1. GitHub public repo over HTTPS with no credential
2. GitHub private repo over HTTPS with a read-only token
3. GitHub private repo over SSH only if you already want per-device key management

For your current plan, use a public HTTPS repo and no GitHub credential at all.

## 4. Copy bootstrap files to the machine

You only need [bootstrap-ubuntu.sh](/Users/ngoh10/Documents/ChatGPT_Projects/ansible-pull/scripts/bootstrap-ubuntu.sh). It performs the initial clone itself.

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

## 6. Verify

Check:

```bash
systemctl status ansible-pull.timer
systemctl list-timers ansible-pull.timer
tail -n 100 /var/log/ansible-pull/ansible-pull-$(hostname -s).log
```

## 7. Ongoing workflow

- Make repo changes in Git
- Merge to `main`
- Let the timer apply them automatically
- Use one test laptop before rolling changes to everyone

## What this setup updates

- Ubuntu security updates
- Ubuntu `-updates` packages
- APT-managed packages like `openssh-server`
- Optional non-security package upgrades if you enable `base_apt_maintenance_enabled`

This does not automatically manage snap refresh policy.

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
- Add CI before the repo gets large

See [docs/first-workstation.md](/Users/ngoh10/Documents/ChatGPT_Projects/ansible-pull/docs/first-workstation.md) for the exact first-machine rollout.
