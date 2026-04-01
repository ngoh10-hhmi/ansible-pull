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

Edit [vars/baseline.yml](/Users/ngoh10/Documents/ChatGPT_Projects/ansible-pull/vars/baseline.yml) for what every Ubuntu workstation should get.

Recommended shared baseline:

- keep unattended upgrades enabled
- keep `base_apt_maintenance_enabled: false`
- keep optional packages minimal

## 3. Create a host-specific vars file only if this machine is special

If the machine can stay on the shared baseline, skip this section.

If it needs exceptions, copy the example file:

```bash
cp inventory/host_vars/ubuntu-test-laptop.yml.example inventory/host_vars/ubuntu-test-laptop.yml
```

Then edit it to match what you want on that machine.

- Example exception cases:

- include `openssh-server` only if that machine should accept SSH
- add one-off packages like `tailscale`
- override optional package choices on a single host

## 4. Commit and push the baseline change, plus any host file if needed

From this repo:

```bash
git add vars/baseline.yml inventory/host_vars/ubuntu-test-laptop.yml
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

## 6. Verify the first run

Check the timer:

```bash
systemctl status ansible-pull.timer
systemctl list-timers ansible-pull.timer
```

Check the most recent log:

```bash
tail -n 100 /var/log/ansible-pull/ansible-pull-$(hostname -s).log
```

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
- If you do not want inbound SSH, remove `openssh-server` from the host file.
