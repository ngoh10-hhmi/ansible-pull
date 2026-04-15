# Repo Gap Review

This is a focused review of the current repo shape as of April 15, 2026.

The goal is not to redesign the project. It is to highlight the main gaps that
still look operationally meaningful after the recent cleanup, docs work, and
integration coverage additions.

## What Looks Solid

- The main `ansible-pull` runtime flow is documented clearly.
- The branch-switch workflow is implemented and integration-tested.
- The timer-based operational model is consistent across docs, scripts, and
  role tasks.
- Shared-vs-host variable placement is much easier to follow than before.

## Priority Gaps

### 1. `/etc/ansible/pull.env` handling is still fragile

Current behavior:

- [`scripts/bootstrap-ubuntu.sh`](../scripts/bootstrap-ubuntu.sh) writes raw
  `KEY=value` lines into `/etc/ansible/pull.env`.
- [`scripts/switch-pull-branch.sh`](../scripts/switch-pull-branch.sh) rewrites
  the same file the same way.
- [`scripts/run-ansible-pull.sh`](../scripts/run-ansible-pull.sh) then loads the
  file with `source`.

Why this is a gap:

- Values are not shell-escaped before being persisted.
- Manual edits can easily create malformed shell syntax.
- Slack webhook values, repo URLs, or future settings with spaces or shell
  metacharacters can become hard to round-trip safely.

Recommended change:

- Add one shared shell helper for writing env files safely.
- Serialize values with shell-safe quoting instead of raw interpolation.
- Add a small validation step after load so missing or malformed required keys
  fail fast with a clear error.

Suggested validation:

- Add script-level tests that prove `REPO_URL`, `PLAYBOOK`, `DEST`, `LOG_DIR`,
  and Slack-related values survive a write/load round-trip.

### 2. `base_local_sudo_users` behavior does not match the docs

Update:

- We are keeping the historical `/etc/group` model for now.
- The fix is to stop using the `user` module here and instead add requested
  usernames to the local `sudo` group after the AD join and SSSD steps have
  completed.

Current behavior:

- Bootstrap persists the requested usernames into
  `base_local_sudo_users` before the AD enrollment converge.
- The role now waits until after the AD join and SSSD configuration before
  resolving those usernames through NSS.
- The role updates the local `sudo` group with `gpasswd` instead of using the
  Ansible `user` module.

Why this was a gap:

- The old implementation was more permissive than bootstrap.
- A typo in `base_local_sudo_users` could silently create a new local account.
- The operator-facing docs did not match the actual convergence behavior.

Recommended change:

- Keep the historical `/etc/group` model for now.
- Treat `base_local_sudo_users` as "usernames that must resolve through NSS"
  before the local `sudo` group is updated.
- Keep the docs explicit that the name is legacy and may include AD-backed
  usernames after SSSD is active.

Suggested validation:

- Add integration or script-focused coverage for both an existing user and a
  missing user path.

### 3. Slack delivery is useful but not hardened yet

Current behavior:

- [`scripts/run-ansible-pull.sh`](../scripts/run-ansible-pull.sh) constructs the
  Slack JSON payload with inline shell interpolation.
- The `curl` call has no explicit connect timeout, overall timeout, or retry
  policy.

Why this is a gap:

- Payload text is not JSON-escaped before submission.
- A slow or unhealthy webhook endpoint can delay or hang a scheduled run longer
  than necessary.
- This path is important during failures, which is when the runtime should stay
  especially predictable.

Recommended change:

- Add a small JSON-escape helper or generate the payload through a safer
  mechanism.
- Add conservative `curl` timeouts and a small retry policy.
- Log the notification result clearly without turning Slack failure into a full
  converge failure.

Suggested validation:

- Add tests around payload generation and success/failure notification gating.

### 4. The automated coverage still skews toward convergence, not script safety

Current behavior:

- [`tests/integration/test_workstation.py`](../tests/integration/test_workstation.py)
  covers timer installation, host var resolution, and branch switching well.
- It does not directly cover bootstrap argument handling, pull-env
  serialization, Slack preservation, or invalid-branch/operator-error flows.

Why this is a gap:

- The highest-risk operator mistakes happen in shell-entry paths.
- Several repo invariants depend on script coordination, not just on the
  playbook converging successfully.

Recommended change:

- Add a small `tests/scripts/` layer for non-root shell behavior.
- Focus first on:
  - env file round-tripping
  - branch-switch validation before rewrite
  - Slack setting preservation
  - bootstrap argument validation
  - local sudo user semantics

Suggested validation:

- Keep these tests tempdir-based and mock external commands so they stay fast
  and safe on developer machines.

### 5. `switch-pull-branch.sh` updates state before it proves the target is valid

Current behavior:

- [`scripts/switch-pull-branch.sh`](../scripts/switch-pull-branch.sh) rewrites
  `/etc/ansible/pull.env` and `/etc/ansible/bootstrap-vars.yml` immediately.
- If `--run-now` is omitted, a typo in `--branch` or `--repo` is not caught
  until a later scheduled run.

Why this is a gap:

- Operator mistakes can be persisted into the machine's steady-state runtime
  config.
- Recovery is easy, but the failure is delayed and noisier than it needs to be.

Recommended change:

- Validate the requested repo/branch before writing the new state.
- Fail fast if the remote branch cannot be fetched or does not exist.
- Keep the current `--run-now` behavior, but make it optional confirmation
  rather than the only validation path.

Suggested validation:

- Add one test for a valid branch switch and one for an invalid branch that
  must leave both persisted files untouched.

### 6. APT maintenance is less lock-tolerant than APT refresh

Current behavior:

- [`scripts/apt-refresh.sh`](../scripts/apt-refresh.sh) uses
  `DPkg::Lock::Timeout=600`.
- [`scripts/apt-maintenance.sh`](../scripts/apt-maintenance.sh) does not.

Why this is a gap:

- The maintenance timer can collide with unattended upgrades or other APT work.
- The refresh helper already encodes the more resilient behavior.

Recommended change:

- Apply the same lock-timeout strategy to the maintenance helper's update,
  dist-upgrade, autoremove, and autoclean path where appropriate.
- Consider documenting the expected interaction with unattended-upgrades.

Suggested validation:

- Add at least one script-level test that confirms the helper invokes APT with
  the intended lock-tolerant flags.

## Recommended Change Order

1. Harden env-file serialization and add branch validation.
2. Align `base_local_sudo_users` behavior with the documented contract.
3. Harden Slack delivery and add coverage for notification settings.
4. Add a lightweight script-test layer.
5. Improve APT maintenance lock tolerance.

## Review Note

I would treat items 1, 2, and 5 as the best next tranche because they reduce
operator surprise without changing the repo's overall model.
