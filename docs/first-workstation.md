# First Ubuntu Workstation Rollout

This guide is the shortest path to testing `ansible-pull` on one Ubuntu laptop or workstation.

## 1. Pick a test machine

Use a non-critical Ubuntu system first.

On that machine, record its hostname:

```bash
hostname -s
```

Assume the result is `ubuntu-test-laptop`.

## 2. Create the host-specific vars file in this repo

Copy the example file:

```bash
cp inventory/host_vars/ubuntu-test-laptop.yml.example inventory/host_vars/ubuntu-test-laptop.yml
```

Then edit it to match what you want on that machine.

Recommended first test scope:

- keep unattended upgrades enabled
- keep `apt_maintenance_enabled: false`
- include `openssh-server` only if that machine should accept SSH
- keep optional packages minimal

## 3. Commit and push the host file

From this repo:

```bash
git add inventory/host_vars/ubuntu-test-laptop.yml
git commit -m "Add first workstation host vars"
git push
```

## 4. Bootstrap the Ubuntu machine

On the Ubuntu machine:

```bash
curl -fsSL https://raw.githubusercontent.com/ngoh10-hhmi/ansible-pull/main/scripts/bootstrap-ubuntu.sh -o /tmp/bootstrap-ubuntu.sh
chmod +x /tmp/bootstrap-ubuntu.sh
sudo /tmp/bootstrap-ubuntu.sh \
  --repo https://github.com/ngoh10-hhmi/ansible-pull.git \
  --branch main
```

The bootstrap script installs Ansible, clones the repo into `/var/lib/ansible-pull`, installs the `ansible-pull` wrapper, runs the playbook once, and enables the timer.

## 5. Verify the first run

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

## 6. Force another run after a repo change

After you change the repo and push:

```bash
sudo /usr/local/sbin/run-ansible-pull
```

## 7. What to watch for

- If the host file name does not match `hostname -s`, host-specific vars will not load.
- If the machine uses Firefox as a snap, browser updates are not controlled by the current APT tasks.
- If you do not want inbound SSH, remove `openssh-server` from the host file.
