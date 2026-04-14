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

### Option B: On an Already Running Machine
Append the environment variable directly into the un-tracked runtime file:
```bash
sudo bash -c 'echo "SLACK_WEBHOOK_URL=\"https://hooks.slack.com/services/...\"" >> /etc/ansible/pull.env'
```

### Configuring Alert Behavior
Webhook integrations are configured natively within the identical `/etc/ansible/pull.env` runtime file.
- **Failures**: The wrapper always alerts on play failures.
- **Successes**: The wrapper defaults to alerting on successes (`SLACK_NOTIFY_SUCCESS=true`) to provide a "heartbeat" during initial deployment.
- **Muting**: To disable constant success pings every 15 minutes, add `SLACK_NOTIFY_SUCCESS=false` to `/etc/ansible/pull.env`.

> [!NOTE]
> **Activation Delay**: When you first add a Webhook URL to an existing machine, you may need to run `sudo /usr/local/sbin/run-ansible-pull` **twice**. 
> 
> The first run pulls the new notification logic from GitHub and installs it to the disk, but the process already running in memory won't have the new `notify_slack` function yet. The second run loads the new script from disk and will successfully fire the notification.
