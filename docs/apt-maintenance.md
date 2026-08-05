# APT Maintenance

This document describes the scripts used for managing APT package updates on managed workstations.

## Overview

Workstation package management in this repository follows a tiered approach to balance security with stability:

1.  **Security Updates (Automatic):** Managed by Ubuntu's `unattended-upgrades` service. This handles critical security patches automatically and is configured to run on a 30-day interval in this repo.
2.  **Package Metadata Refresh (Scheduled):** A dedicated `systemd` timer runs `scripts/apt-refresh.sh` hourly to ensure the local APT cache is up-to-date.
3.  **Targeted Package Updates (Manual/Scheduled):** For non-security packages (e.g., browsers or specific developer tools), `scripts/upgrade-installed-apt-packages.sh` can be used to upgrade a specific subset of installed packages.

## Pinned packages

Some packages must not move on their own schedule:

- **NVIDIA driver packages** (`nvidia-`, `libnvidia-`) are listed in `Unattended-Upgrade::Package-Blacklist` in `/etc/apt/apt.conf.d/52ansible-unattended-upgrades`. The userspace libraries must match the loaded kernel module, and silent background upgrades produce a mismatch that breaks the GPU stack until reboot. Operators upgrade the driver intentionally; the blacklist only blocks the unattended path. Edit `base_unattended_upgrade_package_blacklist` in the role to add more entries.

## Targeted CVE mitigations

The base role applies focused CVE mitigations that don't fit the broader update schedule:

- **CVE-2026-31431 ("Copy Fail"):** Each converge checks the installed `kmod` version against the per-release fixed version in `base_copy_fail_fixed_kmod_versions` (see [Canonical's advisory](https://ubuntu.com/blog/copy-fail-vulnerability-fixes-available)). If the host is behind, Ansible runs `apt-get install --only-upgrade kmod` — never a full `dist-upgrade`. Already-patched hosts skip the upgrade with no APT activity. When Canonical publishes a fix for an additional release, add the codename → version entry to the variable in `roles/base/defaults/main.yml` and mirror it in `tests/integration/test_workstation.py::test_copy_fail_kmod_mitigation_is_applied`.

## Handling APT Lock Contention

Because `unattended-upgrades` and these maintenance scripts may attempt to run APT operations concurrently, all scripts in this repository use the `DPkg::Lock::Timeout=600` option. This tells `apt` to wait up to **10 minutes** for the `dpkg` lock to become available rather than failing immediately, so scheduled tasks "wait in line" instead of requiring manual intervention.

That option is not sufficient on its own. It covers only the dpkg frontend and administration locks taken by `apt-get install`. The `/var/lib/apt/lists/lock` that `apt-get update` takes, and the `/var/cache/apt/archives/lock`, ignore it entirely and fail immediately with `E: Could not get lock ...` and exit code 100.

That gap is reachable from this repo's own schedule: `apt-refresh.timer` runs `hourly` with no jitter, so it fires exactly on the hour, while `managed-package-updates.timer` (03:00) and `browser-package-updates.timer` (04:00) each add up to 15 minutes of jitter. A small jitter draw puts the daily upgrade inside the hourly refresh's `apt-get update` and kills it before it upgrades anything.

`scripts/lib/apt_lock.sh` closes it. Both `apt-refresh.sh` and `upgrade-installed-apt-packages.sh` call `apt_get_with_lock_retry` instead of `apt-get` directly; it re-runs the command while — and only while — apt reports lock contention, up to `APT_LOCK_RETRY_TIMEOUT_SEC` (default 600) in `APT_LOCK_RETRY_INTERVAL_SEC` (default 15) steps. Any other apt failure returns its original exit code on the first attempt, so a bad mirror or missing signing key still fails fast and still trips the unit's `OnFailure` Slack alert. `update-installed-browsers.sh` gets the same protection for its APT half by shelling out to `upgrade-installed-apt-packages`.

---

## Scripts

### `apt-refresh.sh`

A lightweight script designed to be run via a `systemd` timer to keep the local APT package index fresh.

**Purpose:**
Runs `apt-get update` to refresh the local package metadata.

**Usage:**
Typically executed by `systemd` as part of the `apt-refresh.timer`. It does not require arguments.

---

### `upgrade-installed-apt-packages.sh`

A more robust script used to upgrade a specific subset of packages that are already installed on the machine.

**Purpose:**
Upgrades only the packages listed in a provided file, provided they are already installed.

**Key Safety Features:**
- **`--only-upgrade`:** Uses `apt-get install --only-upgrade` to ensure that the script *never* installs a new package that wasn't already present. It only updates existing ones.
- **Candidate Validation:** Before attempting an upgrade, the script checks that each package in the list has a valid upgrade candidate in the current APT metadata.
- **Lock Tolerance:** Like `apt-refresh.sh`, it waits up to 10 minutes for the `dpkg` lock.

**Usage:**
```bash
sudo ./scripts/upgrade-installed-apt-packages.sh --label <description> --list-file <path-to-package-list>
```

**Arguments:**
- `--label <string>`: A descriptive label for the update (used in logging and Slack notifications).
- `--list-file <path>`: A path to a plain-text file containing one package name per line. Lines starting with `#` or empty lines are ignored.

**Example:**
To upgrade only the browsers listed in a specific file:
```bash
sudo ./scripts/upgrade-installed-apt-packages.sh --label "browser-updates" --list-file /etc/ansible/browser-packages.txt
```
