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

### 1. `/etc/ansible/pull.env` handling was fragile, but is now in better shape

Current behavior:

- [`scripts/lib/envfile.sh`](../scripts/lib/envfile.sh) now writes shell-escaped
  `KEY=value` lines into `/etc/ansible/pull.env`.
- [`scripts/bootstrap-ubuntu.sh`](../scripts/bootstrap-ubuntu.sh) and
  [`scripts/switch-pull-branch.sh`](../scripts/switch-pull-branch.sh) both use
  that shared helper.
- [`scripts/run-ansible-pull.sh`](../scripts/run-ansible-pull.sh) now loads the
  file through the same shared helper and validates required keys after load.

Why it still matters:

- Manual edits can still create malformed shell syntax.
- The env file is still machine-local operational state and should not be
  casually hand-maintained.

Suggested validation:

- Keep script-level tests that prove `REPO_URL`, `PLAYBOOK`, `DEST`, `LOG_DIR`,
  and Slack-related values survive a write/load round-trip.

### 2. Sudo-user naming and behavior drifted from intent

Update:

- We are keeping the historical `/etc/group` model for now.
- The fix is to stop using the `user` module here and instead add requested
  usernames to the local `sudo` group after the AD join and SSSD steps have
  completed.

Current behavior:

- Bootstrap can carry a temporary sudo-user list into the AD enrollment
  converge.
- The role now waits until after the AD join and SSSD configuration before
  resolving those usernames through NSS.
- The role updates the local `sudo` group with `gpasswd` instead of using the
  Ansible `user` module.
- The final persisted bootstrap vars intentionally omit that temporary sudo-user
  list so later scheduled converges do not keep re-applying local sudo-group
  membership.

Why this was a gap:

- The old implementation was more permissive than bootstrap.
- A typo in `base_local_sudo_users` could silently create a new local account.
- The operator-facing docs did not match the actual convergence behavior.

Recommended change:

- Keep the historical `/etc/group` model for now.
- Treat the bootstrap-only sudo-user list as "usernames that must resolve
  through NSS" before the local `sudo` group is updated.
- Do not persist those one-time bootstrap sudo-user choices into the final
  scheduled-run state.

Suggested validation:

- Add integration or script-focused coverage for both an existing user and a
  missing user path.

### 3. Slack delivery is useful and more hardened than before

Current behavior:

- [`scripts/run-ansible-pull.sh`](../scripts/run-ansible-pull.sh) now builds the
  Slack JSON payload through a small inline Python serializer.
- The `curl` call includes explicit retry and timeout settings.

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

### 6. Targeted package update helpers should stay lock-tolerant

Current behavior:

- [`scripts/apt-refresh.sh`](../scripts/apt-refresh.sh) uses
  `DPkg::Lock::Timeout=600`.
- [`scripts/upgrade-installed-apt-packages.sh`](../scripts/upgrade-installed-apt-packages.sh)
  also uses `DPkg::Lock::Timeout=600`.

Why this still matters:

- The daily managed-package and browser-package timers can still collide with
  unattended upgrades or other APT work if this tolerance regresses later.
- The refresh helper and targeted-update helper should stay aligned.

Recommended change:

- Keep the same lock-timeout strategy on both helper paths as the scripts evolve.
- Keep documenting the expected interaction with unattended-upgrades.

Suggested validation:

- Add at least one script-level or integration test that confirms the helper
  keeps invoking APT with the intended lock-tolerant flags.

## Recommended Change Order

1. Harden env-file serialization and add branch validation.
2. Align sudo-user naming and behavior with the documented contract.
3. Harden Slack delivery and add coverage for notification settings.
4. Add a lightweight script-test layer.
5. Improve APT maintenance lock tolerance.

## Review Note

I would treat items 1, 2, and 5 as the best next tranche because they reduce
operator surprise without changing the repo's overall model.
