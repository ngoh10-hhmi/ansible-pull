# Targeted Package Updates

This repository is intentionally conservative by default:

- unattended upgrades are security-only
- A dedicated systemd timer refreshes APT package lists hourly
- installed packages from `base_workstation_base_packages` are upgraded daily
- installed packages from `base_browser_update_packages` are upgraded daily
- installed browser snaps from `base_browser_update_snaps` are refreshed daily
- unattended upgrades run every 30 days
- host-specific one-off packages are not broadly auto-updated

When a specific package needs attention, such as a browser or another vulnerable app, use one of the patterns below.

## Default behavior

By default, the repo now has three update paths:

- `apt-refresh.timer` refreshes package metadata hourly
- `managed-package-updates.timer` upgrades only installed packages from `base_workstation_base_packages`
- `browser-package-updates.timer` upgrades only installed packages from `base_browser_update_packages` and refreshes only installed snaps from `base_browser_update_snaps`

This means:

- the shared baseline gets daily non-security updates
- installed browsers in the browser list get daily non-security updates
- installed browser snaps in the snap list get daily refreshes
- packages added only through `base_workstation_extra_packages` stay outside the daily managed update path unless you intentionally promote them
- absent browser packages are never installed just because they appear in the browser list
- absent browser snaps are never installed just because they appear in the browser snap list

Firefox installed as a snap is now covered by the browser timer when the `firefox` snap is already present.

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

This ensures the package is installed and remains present. It does not add that package to the shared daily managed update list unless you also move it into `base_workstation_base_packages` or `base_browser_update_packages`.

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

This is the simplest operational response for a one-off vulnerability that is not already covered by the daily managed baseline/browser timers or unattended security updates.

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

Use this carefully. `state: latest` is useful for emergency response, but it is broader than the normal shared daily baseline update path.

## Option 4. Manage third-party repositories and PPAs

If a package requires an external repository (like Google Chrome, VS Code, or a PPA), you can define it in `inventory/group_vars/all.yml` or a host override file.

### Adding a PPA

```yaml
base_workstation_ppas:
  - ppa:ansible/ansible
```

### Adding an external APT repository with a GPG key

Modern Ubuntu systems prefer GPG keys in `/etc/apt/keyrings/`.

```yaml
base_workstation_apt_repos:
  - name: google-chrome
    key_url: "https://dl.google.com/linux/linux_signing_key.pub"
    key_filename: "google-chrome.asc"
    repo: "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.asc] http://dl.google.com/linux/chrome/deb/ stable main"
```

Then add the package to the right package list:

```yaml
base_workstation_extra_packages:
  - google-chrome-stable
```

Or, if the browser should stay in the shared browser exception path, keep it in:

```yaml
base_browser_update_packages:
  - google-chrome-stable
```

For snap-managed browsers such as Firefox on modern Ubuntu, use:

```yaml
base_browser_update_snaps:
  - firefox
```

## Choosing the right option

- Use the default behavior when the package is part of the shared baseline or browser exception list.
- Use Option 1 when a package should be installed on one specific host but should not become part of the shared daily update policy.
- Use Option 2 when you need a quick manual bump for one package.
- Use Option 3 when you want the targeted update captured and repeated through Git-managed automation.

## Manual validation of browser updates

If you want to prove that `browser-package-updates.service` actually upgrades an
installed browser, the simplest path is usually Firefox when it is installed as
a snap.

### Firefox snap validation

1. Check the current Firefox snap revision:

```bash
snap list firefox
snap info firefox
```

2. Revert to the previous installed revision:

```bash
sudo snap revert firefox
firefox --version
```

3. Trigger the browser update service manually:

```bash
sudo systemctl start browser-package-updates.service
```

4. Confirm Firefox moved back to the newer revision:

```bash
snap list firefox
firefox --version
journalctl -u browser-package-updates.service -n 100 --no-pager
```

This works only when the machine already has a previous Firefox snap revision
available to revert to.

### APT browser validation

For an APT-managed browser such as Google Chrome, Edge, or Brave, you can test
the same flow by downgrading to an older package version and then starting the
browser update service.

Pattern:

```bash
apt-cache policy google-chrome-stable
sudo apt-get install --allow-downgrades google-chrome-stable=<older-version>
google-chrome --version
sudo systemctl start browser-package-updates.service
google-chrome --version
journalctl -u browser-package-updates.service -n 100 --no-pager
```

This path depends on the vendor repository still serving the older version, so
it is often less convenient than the Firefox snap test.

## Good PoC rule

For this proof of concept, prefer:

1. security-only unattended upgrades for the baseline
2. daily targeted upgrades for shared baseline packages and installed browsers
3. manual or temporary targeted upgrades for everything else
