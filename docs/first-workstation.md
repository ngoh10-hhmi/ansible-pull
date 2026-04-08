# First Ubuntu Workstation Rollout

This guide is the shortest path to testing `ansible-pull` on one Ubuntu laptop or workstation.

## 1. Pick a test machine

Use a non-critical Ubuntu system first.

On that machine, record its hostname:

```bash
hostname -s
```

Assume the result is `ubuntu-test-laptop`.

## 2. Set the shared baseline in this repo

Edit [inventory/group_vars/all.yml](../inventory/group_vars/all.yml) for what every Ubuntu workstation should get.

Recommended shared baseline:

- keep unattended upgrades enabled
- keep `base_apt_maintenance_enabled: false`
- keep the shared package list small and intentional
- keep unattended upgrades security-only
- keep `base_workstation_update_package_lists_days: 30`
- keep `base_workstation_unattended_upgrade_days: 30`

## 3. Create a host-specific vars file only if this machine is special

If the machine can stay on the shared baseline, skip this section.

If it needs exceptions, copy the example file:

```bash
cp inventory/host_vars/ubuntu-test-laptop.yml.example inventory/host_vars/ubuntu-test-laptop.yml
```

Then edit it to match what you want on that machine.

- Example exception cases:

- add one-off packages like `tailscale`
- add one-off admin tools on a single host

Preferred host override style:

```yaml
base_workstation_extra_packages:
  - htop
  - nload
```

That appends packages to the shared baseline instead of replacing the whole list.

## 4. Commit and push the baseline change, plus any host file if needed

From this repo:

```bash
git add inventory/group_vars/all.yml inventory/host_vars/ubuntu-test-laptop.yml
git commit -m "Set workstation baseline"
git push
```

## 5. Bootstrap the Ubuntu machine

On the Ubuntu machine:

```bash
curl -fsSL https://raw.githubusercontent.com/ngoh10-hhmi/ansible-pull/main/scripts/bootstrap-ubuntu.sh -o /tmp/bootstrap-ubuntu.sh
chmod +x /tmp/bootstrap-ubuntu.sh
sudo /tmp/bootstrap-ubuntu.sh \
  --repo https://github.com/ngoh10-hhmi/ansible-pull.git \
  --branch main
```

The bootstrap script installs Ansible, clones the repo into `/var/lib/ansible-pull`, installs the `ansible-pull` wrapper, runs the playbook once, and enables the timer.
During bootstrap you will be prompted for an AD username and hidden password for the required `hhmi.org` domain join, and you can also enter a comma-separated list of existing local users that should be added to the `sudo` group as the final bootstrap action.

## 6. Verify the first run

Check the timer:

```bash
systemctl status ansible-pull.timer
systemctl list-timers ansible-pull.timer
```

Check the most recent log:

```bash
journalctl -u ansible-pull.service -n 100 --no-pager
tail -n 100 /var/log/ansible-pull/ansible-pull-$(hostname -s).log
```

Both commands should show the same run stream because the wrapper writes to the logfile and stdout/stderr for systemd.

Check unattended upgrade settings:

```bash
cat /etc/apt/apt.conf.d/20auto-upgrades
cat /etc/apt/apt.conf.d/52ansible-unattended-upgrades
```

## 7. Force another run after a repo change

After you change the repo and push:

```bash
sudo /usr/local/sbin/run-ansible-pull
```

## 8. What to watch for

- If you do not create a host file, the machine will use only the shared baseline.
- If the host file name does not match `hostname -s`, host-specific vars will not load.
- If the machine uses Firefox as a snap, browser updates are not controlled by the current APT tasks.
- If you do not want inbound SSH on every workstation, move `openssh-server` out of `inventory/group_vars/all.yml` and add it back only on the hosts that need it.
