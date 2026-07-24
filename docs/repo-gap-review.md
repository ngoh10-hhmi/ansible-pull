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

### 2. Sudo-user handling now lives in the bootstrap script (resolved)

Update:

- This gap is closed. The old role-side path — which used the Ansible `user`
  module and tolerated names NSS could not resolve — has been removed.

Current behavior:

- Sudo-group membership is granted entirely by the bootstrap script's
  `add_bootstrap_sudo_users`, not the role. It runs once, after the AD join and
  SSSD are up, so requested AD names can be resolved.
- Each requested name is resolved with `getent` (retried for SSSD cache
  warmup). A name that does not resolve is reported and the whole list is
  reprompted interactively; a `gpasswd` failure on a name that *did* resolve is
  fatal.
- Local accounts to be created later are out of scope: `gpasswd` cannot add an
  account that does not exist yet, so create the user and run
  `usermod -aG sudo <user>` by hand after bootstrap.
- The sudo-user list is never written into `/etc/ansible/bootstrap-vars.yml`, so
  scheduled converges never re-assert it. `base_sudo_users` /
  `base_local_sudo_users` are dead legacy variables and are no longer consulted.

Why this was a gap:

- The old role-side implementation was more permissive than bootstrap: a typo in
  `base_local_sudo_users` could silently create a new local account, and the
  operator-facing docs did not match the actual behavior.

Suggested validation:

- Keep script-focused coverage for both a resolvable name and an unresolvable
  (reprompt) path.

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

### 5. `switch-pull-branch.sh` validates the target before rewriting state

Current behavior:

- [`scripts/switch-pull-branch.sh`](../scripts/switch-pull-branch.sh) validates
  the target branch with `git ls-remote --heads` before rewriting
  `/etc/ansible/pull.env` or `/etc/ansible/bootstrap-vars.yml`.
- If the requested branch cannot be found, both persisted files are left
  untouched.

Why this is a gap:

- Network, credential, or remote availability problems can now block branch
  switching up front.
- That is intentional: failing before rewrite is safer than persisting a branch
  that the next scheduled run cannot fetch.

Recommended follow-up:

- Keep the validation behavior covered by fast unit tests.
- If private-repo credential handling changes, retest this path on a real
  bootstrapped host.

Suggested validation:

- Keep one test for a valid branch lookup and one for an invalid branch that
  leaves both persisted files untouched.

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
2. Align sudo-user naming and behavior with the documented contract. (Done —
   the grant now lives in the bootstrap post-join step; see section 2.)
3. Harden Slack delivery and add coverage for notification settings.
4. Add a lightweight script-test layer.
5. Improve APT maintenance lock tolerance.

## Review Note

I would treat items 1 and 5 as the best next tranche because they reduce
operator surprise without changing the repo's overall model. (Item 2 is now
done.)
