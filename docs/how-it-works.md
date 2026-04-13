# How This Repo Works

This document is a plain-English map of the repo.

It is meant for operators who need to understand the flow of the system without
having to read every script and Ansible task in detail.

## The Big Picture

Each Ubuntu workstation manages itself.

Instead of one central Ansible server pushing changes to every machine, each
machine:

1. clones this repo locally
2. pulls updates from Git on a schedule
3. runs the main playbook against itself

That is why this repo is built around `ansible-pull`.

## The Main Files

- `scripts/bootstrap-ubuntu.sh`
  First-time setup on a brand-new Ubuntu machine. It installs dependencies,
  clones the repo, asks a few setup questions, writes local config files, and
  runs the first convergence.
- `scripts/run-ansible-pull.sh`
  The recurring wrapper used by `systemd`. It refreshes the local checkout,
  builds a runtime inventory, and runs Ansible.
- `scripts/switch-pull-branch.sh`
  Updates the machine so future pull runs follow a different repo branch.
- `playbooks/workstation.yml`
  The main playbook. Today it applies one role: `base`.
- `roles/base/tasks/main.yml`
  The main workstation baseline tasks.
- `roles/base/tasks/ad_join.yml`
  The HHMI Active Directory and SSSD tasks. This is kept in a separate task
  file so the identity-management flow is easier to find and review.
- `inventory/group_vars/all.yml`
  Shared settings for every workstation.
- `inventory/host_vars/<hostname>.yml`
  Optional per-host exceptions.

## What Happens During Bootstrap

Bootstrap is the very first setup on a new machine.

The rough flow is:

1. install Ansible and a few required packages
2. create `/etc/ansible` and local runtime directories
3. clone this repo into `/var/lib/ansible-pull`
4. prompt for hostname, machine type, and optional local sudo users
5. write `/etc/ansible/pull.env`
6. write `/etc/ansible/bootstrap-vars.yml`
7. install `/usr/local/sbin/run-ansible-pull`
8. run the playbook once

The key idea is that bootstrap writes machine-local values into files under
`/etc/ansible/`. Those files persist on the workstation and are reused on later
scheduled runs.

## What Happens On Every Scheduled Run

The systemd timer starts `ansible-pull.service`, which runs
`/usr/local/sbin/run-ansible-pull`.

That wrapper script then:

1. loads settings from `/etc/ansible/pull.env`
2. acquires a lock so two runs do not overlap
3. syncs the local Git checkout to the configured branch
4. builds a runtime inventory inside the checkout
5. chooses the hostname or FQDN entry that matches available `host_vars`
6. passes `/etc/ansible/bootstrap-vars.yml` as `--extra-vars`
7. runs `playbooks/workstation.yml`

So the playbook is simple, but the wrapper around it is important. The wrapper
decides which checkout to run, which host identity to use, and which persisted
bootstrap values override inventory defaults.

## How The Ansible Layout Works

The main playbook is intentionally small. It applies one role:

- `base`

That role is the baseline HHMI workstation configuration. It handles:

- package repositories and package installation
- `ansible-pull` environment files and helper scripts
- systemd units and timers
- APT refresh and unattended-upgrades policy
- optional local users and local sudo access
- Active Directory enrollment and SSSD configuration

Although there is only one role today, the role is split internally:

- `roles/base/tasks/main.yml`
  general workstation baseline and timer/runtime setup
- `roles/base/tasks/ad_join.yml`
  HHMI domain enrollment and directory-backed access

This split does not change behavior. It mainly makes the risky HHMI-specific
identity tasks easier to find.

## Where Variables Come From

This is the part that usually confuses new readers.

Ansible variables come from multiple places, and not all of them are equal.
For a quick reference of the main operator-facing variables, read
[docs/variable-map.md](variable-map.md).

### 1. Role defaults

File:

- `roles/base/defaults/main.yml`

These are the lowest-priority fallback values. They are intentionally safe and
generic.

Example:

- `base_workstation_base_packages` defaults to an empty list there
- `base_ad_enroll` defaults to `false` there

### 2. Shared inventory

File:

- `inventory/group_vars/all.yml`

This is where the active shared workstation baseline lives.

Example:

- the default package list for every machine
- shared APT and unattended-upgrades policy

### 3. Host-specific inventory

Files:

- `inventory/host_vars/<hostname>.yml`

These are only for exceptions on a specific machine.

Example:

- one machine gets `htop`
- another machine gets `nload`

### 4. Bootstrap-persisted variables

File:

- `/etc/ansible/bootstrap-vars.yml`

This file is written on the machine during bootstrap and then passed to Ansible
as `--extra-vars` on every run. That gives it very high precedence.

This is how the workstation keeps machine-local values such as:

- selected repo URL
- selected branch
- selected playbook path
- local runtime/log directories
- bootstrap answers like hostname or machine type

In practice, that means:

- role defaults are the fallback
- shared inventory defines the standard baseline
- host vars add machine-specific exceptions
- bootstrap vars can override all of the above when the machine must remember a
  local decision

## Why The Repo Is Not Split Into Many Roles

Today the repo manages one main system type: an HHMI Ubuntu workstation that
uses `ansible-pull` and joins AD.

Because of that, one broad `base` role is still reasonable. Most machines share
the same behavior and differ mostly by a small amount of data, so inventory vars
carry most of the customization.

If the repo later grows to manage more distinct machine types or more reusable
subsystems, it might make sense to split out roles such as:

- `ansible_pull_runtime`
- `apt_policy`
- `ad_join`
- `desktop_packages`

Right now, that would mostly be an organization change, not a functional need.

## If You Want To Read The Repo In Order

This is the easiest reading path:

1. `README.md`
2. `docs/how-it-works.md`
3. `playbooks/workstation.yml`
4. `roles/base/tasks/main.yml`
5. `roles/base/tasks/ad_join.yml`
6. `inventory/group_vars/all.yml`
7. one sample file in `inventory/host_vars/`
8. `scripts/bootstrap-ubuntu.sh`
9. `scripts/run-ansible-pull.sh`

That order matches how the repo is operated: understand the policy first, then
the tasks, then the runtime flow.
