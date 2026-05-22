# Slack Webhook Setup Guide

This guide walks operators through generating a Slack Webhook URL to enable automated reporting for scheduled `ansible-pull` workstation runs.

## 1. Create a Slack App
1. Go to the Slack API platform: [api.slack.com/apps](https://api.slack.com/apps) and authenticate to the workspace.
2. Click the green **"Create New App"** button in the top right corner.
3. Select **"From scratch"**.
4. **App Name:** Name it something recognizable (e.g., `ansible-pull-alerts`).
5. **Pick a workspace:** Choose the target workspace where you want the alerts to land.
6. Click **"Create App"**.

## 2. Enable Incoming Webhooks
1. Under the **"Add features and functionality"** section on the Basic Information page, click **"Incoming Webhooks"**.
2. Toggle the **"Activate Incoming Webhooks"** switch to **On**.

## 3. Authorize and Select a Channel
1. After activating webhooks, click the **"Add New Webhook to Workspace"** button at the bottom of the page.
2. Select the specific channel (e.g., `#devops-alerts` or a test channel) from the dropdown where you want the logs emitted.
3. Click **"Allow"**.

## 4. Grab the Webhook URL
1. Scroll to the **"Webhook URLs for Your Workspace"** table at the bottom of the Incoming Webhooks settings page.
2. Click the **"Copy"** button next to your new Webhook URL. 
   *(Format: `https://hooks.slack.com/services/T0000/B0000/XXXXX`)*

---

## 5. Implement on Workstation

Because Webhook URLs act as deployment secrets, **do not commit them to Git**. You inject them directly on the local machine context.

### Option A: During Initial Bootstrap
Pass the webhook URL along with the bootstrapping arguments:
```bash
sudo ./bootstrap-ubuntu.sh \
  --repo https://github.com/ngoh10-hhmi/ansible-pull.git \
  --branch main \
  --slack-webhook "https://hooks.slack.com/services/..."
```

If you also want success notifications, opt in explicitly:
```bash
sudo ./bootstrap-ubuntu.sh \
  --repo https://github.com/ngoh10-hhmi/ansible-pull.git \
  --branch main \
  --slack-webhook "https://hooks.slack.com/services/..." \
  --slack-notify-success true
```

### Option B: On an Already Running Machine
Edit the untracked runtime file on the machine:
```bash
sudoedit /etc/ansible/pull.env
```

The runtime file is now written through a shared helper that shell-escapes its
values. If you hand-edit it, keep the existing shell-style `KEY=value` format.

### Option C: Operator-Run Backfill from the AD-Protected Share

For fleet-wide rollout without committing the webhook URL anywhere, the base role drops a helper script onto every converged host. The operator runs it once per host (as themselves, not via `sudo`) and the URL is read from a Kerberos-authenticated SMB share and written into `/etc/ansible/pull.env`. From then on, the existing notify path works unchanged — the share is never touched by the scheduled timer.

**Why operator-run and not fully automated?**

The share that holds the webhook (`\\prfs.hhmi.org\public\test_henry\slack_webhook.txt`) is ACL'd to AD users, not to the machine account. SSSD stores user Kerberos tickets in a per-session kernel KEYRING that `root` cannot read, so neither the timer-driven converge (which runs as `root`) nor a `sudo` shell can use the operator's TGT to reach the share. The helper script therefore runs **as the operator** and only escalates to `root` for the final write of `/etc/ansible/pull.env`.

**Workflow on a new or existing host**

1. Log in to the host as your normal AD user (this gives you a fresh TGT via PAM/SSSD).
2. Run:
   ```bash
   install-slack-webhook
   ```
   (Run as yourself — *not* `sudo install-slack-webhook`; see above for why.)
3. The script:
   - Loads share location from `/etc/ansible/slack-webhook.conf`.
   - Verifies your TGT is valid (`klist -s`).
   - Reads the webhook via `smbclient //prfs.hhmi.org/public --use-kerberos=required`.
   - Validates the result looks like `https://hooks.slack.com/services/...`.
   - Prompts for `sudo` and writes the value atomically into `/etc/ansible/pull.env`.
4. The next ansible-pull timer fire (within 15 minutes) — or a manual `sudo /usr/local/sbin/run-ansible-pull` — starts emitting Slack notifications.

The helper is idempotent: if `pull.env` already has `SLACK_WEBHOOK_URL=https…`, the script exits without touching anything.

**Manual verification of share connectivity from one host**

Before running `install-slack-webhook`, you can confirm your account can read the file directly:

```bash
smbclient //prfs.hhmi.org/public --use-kerberos=required \
  -c 'get "test_henry\slack_webhook.txt" -'
```

The webhook URL should print to stdout. If `smbclient` reports `NT_STATUS_ACCESS_DENIED`, the share ACL doesn't grant your account read access. If it reports `NT_STATUS_INVALID_PARAMETER` from `gensec_spnego_client_negTokenInit_step`, you're hitting a DFS namespace rather than a real SMB server — connect to the resolved backing host (e.g. `prfs.hhmi.org`) instead of the DFS root.

**Forcing a re-fetch (after the webhook rotates)**

Clear the current value on the host and re-run the helper:

```bash
sudo sed -i 's/^SLACK_WEBHOOK_URL=.*/SLACK_WEBHOOK_URL=/' /etc/ansible/pull.env
install-slack-webhook
```

**Disabling the backfill on a specific host**

Set one of the three share variables to an empty string in that host's `host_vars`. The base role will then skip dropping the helper and the conf file:

```yaml
base_slack_webhook_share_host: ""
```

### Configuring Alert Behavior
Webhook integrations are configured natively within the identical `/etc/ansible/pull.env` runtime file.
- **Failures**: The wrapper always alerts on play failures.
- **Successes**: The wrapper skips success notifications by default (`SLACK_NOTIFY_SUCCESS=false`).
- **Opt-in heartbeat**: To send success notifications too, set `SLACK_NOTIFY_SUCCESS=true` in `/etc/ansible/pull.env` or pass `--slack-notify-success true` during bootstrap.

### What Failure Notifications Include
When the wrapper can detect it from the current run output, failed-run Slack
notifications now include:

- the wrapper phase that failed (for example `sync_repository_checkout` or `run_playbook`)
- the last detected Ansible task name
- a short error excerpt from the run log
- the local logfile path on disk

This is meant to make the alert immediately more actionable without sending the
entire run log to Slack.

> [!NOTE]
> **Activation Delay**: When you first add a Webhook URL to an existing machine, you may need to run `sudo /usr/local/sbin/run-ansible-pull` **twice**. 
> 
> The first run pulls the new notification logic from GitHub and installs it to the disk, but the process already running in memory won't have the new `notify_slack` function yet. The second run loads the new script from disk and will successfully fire the notification.
