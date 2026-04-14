# GEMINI.md

## Repository Overview
**Path:** `/Users/ngoh10/Documents/projects/ansible-pull`
**Purpose:** This repository manages Ubuntu workstations at HHMI using `ansible-pull`. Machines clone this repository and apply the configurations locally via a `systemd` timer. 
The main entrypoint playbook is `playbooks/workstation.yml`. 
Key features include baseline configurations, unattended security upgrades, and HHMI-specific Active Directory enrollment with SSSD setup.

## AI Assistant Guidelines

### Understanding the Architecture
- **Ansible-Pull:** This is a **decentralized** "pull" architecture (default check-in every 15 minutes). Do NOT treat this as a traditional push-based Ansible setup.
- **Logging:** `run-ansible-pull` logs to both `/var/log/ansible-pull/ansible-pull-<hostname>.log` and stdout/stderr. These logs are managed and compressed weekly via a standard `logrotate` configuration deployed during the base role.
- **Disposable Runtime State:** `/var/lib/ansible-pull` on target machines is highly volatile. Automation resets the state with `git reset --hard` and `git clean -fdx`. Do not store persistent local state in the checkout directory.
- **Timer Driven Services:** `ansible-pull.service` is triggered by a timer. Do not advise redesigning it as a directly enabled, long-running service.

### Critical Repository Structure
- **Bootstrapping:** `scripts/bootstrap-ubuntu.sh` (first run on fresh Ubuntu)
- **Ongoing Automation:** `scripts/run-ansible-pull.sh` (recurring converge wrapper)
- **Primary Playbooks and Roles:**
  - `playbooks/workstation.yml`: Core execution playbook.
  - `roles/base/tasks/main.yml`: Baseline package setup, un-attended upgrades, and local users.
  - `roles/base/tasks/ad_join.yml`: HHMI AD join and SSSD configuration. **(High Risk Area)**
- **Variable Precedence:**
  - `inventory/group_vars/all.yml`: Primary shared workstation baseline.
  - `inventory/host_vars/<hostname>.yml`: Host-specific exceptions.
  - `/etc/ansible/bootstrap-vars.yml`: Values provided during bootstrap on the machine. These **override** role defaults and inventory vars!

### Validation & Testing Requirements
When making code modifications, run the following validations:
1. **Setup:** `python -m pip install -r requirements-dev.txt`
2. **Linting (Pre-commit matches CI):** 
   - `pre-commit run --all-files`
   - Individual linters available: `yamllint`, `ansible-lint`, `ansible-syntax-check`, `shellcheck`
3. **Integration Testing:** Requires root on a bootstrapped Ubuntu host.
   - `sudo -E env "PATH=$PATH" python -m pytest -q tests/integration`

### Operational Invariants & Gotchas
- **AD Join & SSSD:** Edits involving Active Directory enrollment or sudo policies are considered high-risk operational changes, not cosmetic. Assume HHMI-specific realms and DNS behaviors.
- **Sudo Access Management:** Local users use the `user` module in `roles/base/tasks/main.yml`. AD-backed sudo access is modeled via sudoers entries/groups in `ad_join.yml`. Do not mix the two.
- **Package Management:** The active initial package baseline lives in `inventory/group_vars/all.yml` (do not be fooled by empty defaults in the base role).
- **Overrides:** Prefer using `base_workstation_extra_packages` to override or add software to specific hosts rather than rewriting the baseline list.

### Change Protocols
- Modifying bootstrap logic requires synchronized updates to both `scripts/bootstrap-ubuntu.sh` and `scripts/run-ansible-pull.sh`.
- AD end-to-end, third-party APT onboarding, and specific idempotency tests have gaps in current CI coverage; always flag these for heavy manual validation.
- **NO SECRETS:** Ensure zero credentials exist in git. Active repo credentials or local secrets belong strictly on the target machine.
  - **Slack Notifications:** Set `SLACK_WEBHOOK_URL` natively inside `/etc/ansible/pull.env`. You can inject this during initial enrollment via `./bootstrap-ubuntu.sh --slack-webhook <url>` or push it in manually. It defaults to alerting on successes but this can be muted by modifying `SLACK_NOTIFY_SUCCESS=false` in the same environment file.
