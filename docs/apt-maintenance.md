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

Because `unattended-upgrades` and these maintenance scripts may attempt to run APT operations concurrently, all scripts in this repository use the `DPkg::Lock::Timeout=600` option.

This tells `apt` to wait up to **10 minutes** for the `dpkg` lock to become available rather than failing immediately. This allows scheduled tasks to "wait in line" for a maintenance window instead of requiring complex retry logic or manual intervention.

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
