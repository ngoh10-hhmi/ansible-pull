# Variable Map

This document is a quick reference for the main variables in this repo.

It is not meant to explain every line of Ansible. It is meant to answer four
practical questions:

1. what the variable does
2. where it is usually set
3. where it is used
4. whether an operator normally changes it

For a broader walkthrough of the repo flow, read
[docs/how-it-works.md](how-it-works.md).

## How To Read This

In most cases, variables come from one of these places:

- `roles/base/defaults/main.yml`
  Safe fallback values
- `inventory/group_vars/all.yml`
  Shared fleet baseline
- `inventory/host_vars/<hostname>.yml`
  Per-host exceptions
- `/etc/ansible/bootstrap-vars.yml`
  Machine-local values written during bootstrap and reused on later runs

As a rule:

- edit `group_vars/all.yml` for normal fleet policy
- edit `host_vars` only for exceptions
- do not edit `roles/base/defaults/main.yml` unless you are changing the role's
  fallback behavior
- do not hand-edit `/etc/ansible/bootstrap-vars.yml` unless you intentionally
  want to change machine-local state

## Package And Repository Variables

| Variable | What it controls | Usually set in | Used by |
| --- | --- | --- | --- |
| `base_workstation_base_packages` | Shared package list for every workstation | `inventory/group_vars/all.yml` | package install task in `roles/base/tasks/main.yml` |
| `base_workstation_extra_packages` | Extra packages for one host or small subset of hosts | usually `inventory/host_vars/<hostname>.yml` | package install task in `roles/base/tasks/main.yml` |
| `base_browser_update_packages` | Browser packages to upgrade daily when already installed | `inventory/group_vars/all.yml` unless fleet policy changes | browser package update list in `roles/base/tasks/main.yml` |
| `base_browser_update_snaps` | Browser snaps to refresh daily when already installed | `inventory/group_vars/all.yml` unless fleet policy changes | browser snap update list in `roles/base/tasks/main.yml` |
| `base_workstation_ppas` | Ubuntu PPA list to add before package install | shared or host inventory | PPA task in `roles/base/tasks/main.yml` |
| `base_workstation_apt_repos` | Third-party APT repos and signing keys | shared or host inventory | key download and repo tasks in `roles/base/tasks/main.yml` |

Notes:

- `base_workstation_base_packages` is the main fleet baseline.
- `base_workstation_extra_packages` is the preferred way to add one-off host
  packages without replacing the shared baseline.
- `base_workstation_base_packages` also drives the daily managed package update
  list.
- `base_browser_update_packages` does not install browsers. It only defines
  which already-installed browser APT packages the daily browser timer should
  try to upgrade.
- `base_browser_update_snaps` does not install snaps. It only defines which
  already-installed browser snaps the daily browser timer should try to
  refresh.
- `base_workstation_apt_repos` entries are expected to include fields like
  `key_url`, `key_filename`, and `repo`.

## ansible-pull Runtime Variables

| Variable | What it controls | Usually set in | Used by |
| --- | --- | --- | --- |
| `base_ansible_pull_repo_url` | Git repo URL each workstation pulls from | role defaults, then usually persisted by bootstrap | `/etc/ansible/pull.env` written by `base` |
| `base_ansible_pull_branch` | Git branch the workstation tracks | role defaults, then usually persisted by bootstrap | `/etc/ansible/pull.env` and timer-driven runs |
| `base_ansible_pull_playbook` | Playbook path to execute inside the repo | role defaults, then usually persisted by bootstrap | `/etc/ansible/pull.env` |
| `base_ansible_pull_directory` | Local checkout path on the workstation | role defaults, then usually persisted by bootstrap | directory creation and `/etc/ansible/pull.env` |
| `base_ansible_pull_log_dir` | Per-host log directory | role defaults, then usually persisted by bootstrap | directory creation and `/etc/ansible/pull.env` |
| `base_ansible_pull_timer_on_calendar` | Schedule for `ansible-pull.timer` | role defaults unless fleet policy changes | `roles/base/templates/ansible-pull.timer.j2` |
| `base_ansible_pull_randomized_delay_sec` | Spread applied to scheduled pull runs | role defaults unless fleet policy changes | `roles/base/templates/ansible-pull.timer.j2` |

Notes:

- Bootstrap writes the repo, pull ref, playbook, directory, and log values into
  `/etc/ansible/bootstrap-vars.yml` so the machine keeps using the same pull
  settings on later runs. The pull ref is usually a branch name, but it can be
  a full commit SHA for rollback or pinning.
- The runtime copy in `/etc/ansible/pull.env` is written through a shared
  helper that shell-escapes values before runtime scripts source them.
- `switch-pull-branch.sh` updates these persisted values when you change a
  machine from `main` to `testing`, switch back, or pin to a commit SHA.

## APT Refresh And Upgrade Policy Variables

| Variable | What it controls | Usually set in | Used by |
| --- | --- | --- | --- |
| `base_apt_refresh_enabled` | Whether the hourly `apt-refresh.timer` is installed and enabled | `inventory/group_vars/all.yml` | conditional tasks in `roles/base/tasks/main.yml` |
| `base_apt_refresh_timer_on_calendar` | Schedule for apt metadata refresh | role defaults unless policy changes | `roles/base/templates/apt-refresh.timer.j2` |
| `base_apt_refresh_randomized_delay_sec` | Delay spread for apt metadata refresh | role defaults unless policy changes | `roles/base/templates/apt-refresh.timer.j2` |
| `base_managed_package_updates_enabled` | Whether the daily managed-package update timer is installed and enabled | `inventory/group_vars/all.yml` | conditional tasks in `roles/base/tasks/main.yml` |
| `base_managed_package_updates_timer_on_calendar` | Schedule for managed baseline package upgrades | role defaults unless policy changes | `roles/base/templates/managed-package-updates.timer.j2` |
| `base_browser_package_updates_enabled` | Whether the daily browser-package update timer is installed and enabled | `inventory/group_vars/all.yml` | conditional tasks in `roles/base/tasks/main.yml` |
| `base_browser_package_updates_timer_on_calendar` | Schedule for browser package upgrades | role defaults unless policy changes | `roles/base/templates/browser-package-updates.timer.j2` |
| `base_workstation_enable_unattended_upgrades` | Whether unattended upgrades are enabled | `inventory/group_vars/all.yml` | APT config tasks in `roles/base/tasks/main.yml` |
| `base_workstation_update_package_lists_days` | Day-based APT periodic refresh value | `inventory/group_vars/all.yml` | `/etc/apt/apt.conf.d/20auto-upgrades` |
| `base_workstation_unattended_upgrade_days` | Day-based unattended-upgrades cadence | `inventory/group_vars/all.yml` | `/etc/apt/apt.conf.d/20auto-upgrades` |
| `base_unattended_upgrade_origins_patterns` | Which package origins unattended-upgrades may install from | role defaults unless policy changes | `/etc/apt/apt.conf.d/52ansible-unattended-upgrades` |

Notes:

- This repo separates hourly package-list refresh from unattended upgrades.
- Managed baseline packages and already-installed browser packages are upgraded
  through their own daily timers instead of a broad `dist-upgrade`.
- The browser timer can refresh a small named set of installed browser snaps
  without taking over general snap refresh policy.
- `base_workstation_update_package_lists_days` is set to `0` in the shared
  baseline because the dedicated `apt-refresh.timer` handles that path instead.

## Local User Variables

| Variable | What it controls | Usually set in | Used by |
| --- | --- | --- | --- |
| `base_workstation_extra_users` | Optional local user accounts to create | shared or host inventory | user creation task in `roles/base/tasks/main.yml` |
| `base_manage_bootstrap_sudo_users` | Whether bootstrap should do the one-time local `sudo` group update | temporary bootstrap-written value | `when` guard for NSS lookup plus `gpasswd` tasks in `roles/base/tasks/main.yml` |
| `base_bootstrap_sudo_users` | Usernames to validate through NSS and add to the local `sudo` group during bootstrap only | temporary bootstrap-written value | NSS lookup plus `gpasswd` tasks in `roles/base/tasks/main.yml` |
| `base_sudo_users` | Legacy persisted sudo-user list from older hosts | older bootstrap state or legacy inventory | retained for compatibility context; no longer enforced on scheduled runs |
| `base_local_sudo_users` | Older alias for `base_sudo_users` | older bootstrap state or legacy inventory | retained for compatibility context; no longer enforced on scheduled runs |

Notes:

- `base_bootstrap_sudo_users` may include local users or AD-backed usernames.
- AD-backed usernames are added to the local `sudo` group only during bootstrap,
  after the AD join and SSSD configuration steps run.
- Entries in `base_bootstrap_sudo_users` must resolve through NSS before the
  role will update the local `sudo` group.
- Scheduled `ansible-pull` runs do not keep re-applying local sudo-group
  membership from persisted bootstrap data.
- `base_sudo_users` and `base_local_sudo_users` may still appear on older
  machines, but they are no longer acted on by normal converges.

## AD And Identity Variables

| Variable | What it controls | Usually set in | Used by |
| --- | --- | --- | --- |
| `base_ad_enroll` | Whether the AD join tasks run | defaults to `false`, usually set by bootstrap | `when` on `import_tasks: ad_join.yml` |
| `target_hostname` | Short hostname used to set the machine FQDN | bootstrap-persisted value | `roles/base/tasks/ad_join.yml` |
| `machine_type` | `desktop` or `laptop`; affects AD/SSSD behavior | bootstrap-persisted value | `roles/base/tasks/ad_join.yml` and `roles/base/templates/sssd.conf.j2` |
| `ad_sudo_group` | Optional AD group granted sudo access | host or shared inventory if needed | sudoers file in `roles/base/tasks/ad_join.yml` |

Notes:

- `target_hostname` and `machine_type` are required when `base_ad_enroll` is
  true.
- `machine_type` changes the generated SSSD config. Laptops get explicit AD
  server fallbacks in `sssd.conf.j2`.
- `ad_sudo_group` is optional. If it is not set, only the built-in
  `scicompsys` group entry is written by the current task.

## Informational Variables

| Variable | What it controls | Usually set in | Used by |
| --- | --- | --- | --- |
| `base_security_focus_notes` | Human-readable notes about the current security posture | role defaults | currently documentation/reference only |

This variable is not driving tasks today. It is more of a reminder of the
intended update posture.

## Variables Written By Bootstrap

The bootstrap script normally writes these into
`/etc/ansible/bootstrap-vars.yml`:

- `base_ansible_pull_repo_url`
- `base_ansible_pull_branch`
- `base_ansible_pull_playbook`
- `base_ansible_pull_directory`
- `base_ansible_pull_log_dir`
- `target_hostname`
- `machine_type`
- `base_ad_enroll`

These values are then passed to Ansible as `--extra-vars` on every later run,
which gives them high precedence.

During the bootstrap-only AD enrollment converge, the script may also write
these temporary values before immediately removing them from the final
persisted state:

- `base_manage_bootstrap_sudo_users`
- `base_bootstrap_sudo_users`

Bootstrap rewrites the final stable state before it enables
`ansible-pull.timer`, so timer failures should not leave the machine tracking a
temporary bootstrap-only sudo-user list.

That is why a workstation can remember:

- which branch it should follow
- where its runtime checkout lives
- what hostname it should use
- whether bootstrap intended the machine to enroll in AD

## The Variables Most Operators Will Actually Touch

If you are just operating the repo, these are the variables you will probably
care about most:

- `base_workstation_base_packages`
- `base_workstation_extra_packages`
- `base_workstation_ppas`
- `base_workstation_apt_repos`
- `base_apt_refresh_enabled`
- `base_managed_package_updates_enabled`
- `base_browser_package_updates_enabled`
- `base_browser_update_packages`
- `base_browser_update_snaps`
- `base_workstation_enable_unattended_upgrades`
- `base_workstation_unattended_upgrade_days`
- `ad_sudo_group`

If you are troubleshooting bootstrap or branch behavior, also look at:

- `base_ansible_pull_repo_url`
- `base_ansible_pull_branch`
- `base_ansible_pull_playbook`
- `target_hostname`
- `machine_type`
- `base_ad_enroll`
