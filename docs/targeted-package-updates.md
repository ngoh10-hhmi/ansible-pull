# Targeted Package Updates

This repository is intentionally conservative by default:

- unattended upgrades are security-only
- unattended upgrades run every 30 days
- non-security updates are not applied automatically

When a specific package needs attention, such as a browser or another vulnerable app, use one of the patterns below.

## Option 1. Keep the package installed on one host

If the package should exist on one specific machine, add it to that host's override file:

```yaml
base_workstation_extra_packages:
  - google-chrome-stable
```

Then run:

```bash
git add inventory/host_vars/<hostname>.yml
git commit -m "Add package for <hostname>"
git push
```

On that host:

```bash
sudo /usr/local/sbin/run-ansible-pull
```

This ensures the package is installed and remains present. It does not enable broad non-security auto-updates for the whole fleet.

## Option 2. Perform a one-time targeted upgrade

If a package is already installed and you want to update just that package intentionally, run on the host:

```bash
sudo apt-get update
sudo apt-get install --only-upgrade <package-name>
```

Examples:

```bash
sudo apt-get install --only-upgrade openssh-server
sudo apt-get install --only-upgrade google-chrome-stable
```

This is the simplest operational response for a one-off vulnerability that is not covered by unattended security updates.

## Option 3. Add a temporary Ansible task for a controlled rollout

If you want the update to be tracked in Git, add a temporary task to the playbook or a dedicated role that upgrades only the target package.

Pattern:

```yaml
- name: Upgrade one package intentionally
  ansible.builtin.apt:
    name: google-chrome-stable
    state: latest
    update_cache: true
```

Use this carefully. `state: latest` is useful for emergency response, but it is broader than the normal conservative baseline.

## Choosing the right option

- Use Option 1 when a package should be installed on a specific host long-term.
- Use Option 2 when you need a quick manual bump for one package.
- Use Option 3 when you want the targeted update captured and repeated through Git-managed automation.

## Good PoC rule

For this proof of concept, prefer:

1. security-only unattended upgrades for the baseline
2. manual targeted upgrades for exceptions
3. Ansible-based targeted package upgrades only when you want a repeatable tracked change
