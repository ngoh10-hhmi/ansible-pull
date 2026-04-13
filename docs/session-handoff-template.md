# Session Handoff Template

Use this when compacting a long Codex or ChatGPT coding session into a new chat.

The goal is to preserve the facts that matter for engineering continuity:

- what the task is
- which branch and commit you are on
- what already changed
- what was validated
- what is still broken or risky
- the exact next action to take

## How to use it

1. Start a new or compacted chat.
2. Paste the filled template below near the top.
3. Add one short instruction after it, for example:

```md
Continue from this state.

Next task:
- Fix the failing integration test on `testing`.
```

Keep the handoff factual. Do not waste space on conversational history if it does
not change the technical state.

## Template

```md
Task:
- What we were trying to do in one sentence.

Current state:
- Branch:
- Latest commit(s):
- Worktree clean/dirty:
- Main files changed:
- What is already implemented:

Key decisions:
- Decision 1:
- Decision 2:
- Things we explicitly chose not to do:

Validation:
- Checks run:
- Checks passing:
- Checks not run / blocked:

Open issues:
- Remaining bug / question:
- Suspected root cause:
- Important logs or symptoms:

Environment notes:
- Python/version/tooling details:
- Required local setup:
- Any auth or sandbox quirks:

Next best step:
- The exact next action to take.
```

## What to keep

- Current branch and latest commit
- Files changed or the main areas touched
- Exact validation status
- Known blockers or risks
- Environment details that can break the next step
- Any repo-specific rules that constrain future edits

## What to cut

- Repeated explanations
- Full command transcripts unless the exact output still matters
- Conversational back-and-forth
- Old hypotheses that were disproven
- File-by-file detail that does not affect the next action

## Example

```md
Task:
- Improve repo readability and local developer workflow for the `ansible-pull` repo.

Current state:
- Branch: `testing`
- Latest commit: `abc1234`
- Worktree: clean
- Main files changed:
  - `README.md`
  - `docs/dev-setup.md`
  - `scripts/setup-dev.sh`
- Implemented:
  - Added local setup docs
  - Added a helper script for developer onboarding

Key decisions:
- Keep the current one-role `base` structure.
- Improve readability through docs and comments instead of restructuring roles.
- Do not change AD behavior.

Validation:
- `pre-commit run --all-files`: passing
- `pytest --collect-only -q tests/integration/test_workstation.py`: passing
- Full integration suite: not run in this environment

Open issues:
- One GitHub Actions integration job is failing.
- Suspected root cause: new timer assertion is using regex-style matching by mistake.

Environment notes:
- Local dev setup expects Python 3.11+
- `shellcheck` must be installed separately
- Sandboxed `gh` checks may not see keychain-backed auth

Next best step:
- Fix the failing timer assertion in `tests/integration/test_workstation.py` and rerun checks.
```

## Repo-specific example

Use a more explicit handoff when the change touches bootstrap flow, timer
behavior, branch switching, or other operational paths in this repo.

```md
Task:
- Change the scheduled pull cadence and keep the operator docs and tests aligned.

Current state:
- Branch: `testing`
- Latest commit: `def5678`
- Worktree: dirty
- Main files changed:
  - `inventory/group_vars/all.yml`
  - `roles/base/tasks/main.yml`
  - `scripts/switch-pull-branch.sh`
  - `tests/integration/test_workstation.py`
  - `README.md`
- Implemented:
  - Updated `base_ansible_pull_timer_on_calendar`
  - Adjusted the systemd timer template path consumed by the base role
  - Updated operator docs for the new cadence

Key decisions:
- Keep `ansible-pull.service` timer-driven.
- Treat `/var/lib/ansible-pull` as disposable runtime state.
- Update tests and docs in the same change when timer behavior changes.
- Do not alter HHMI AD enrollment logic as part of this task.

Validation:
- `pre-commit run --all-files`: passing
- `pytest --collect-only -q tests/integration/test_workstation.py`: passing
- Manual validation:
  - `systemctl cat ansible-pull.timer` shows the new schedule
  - `systemctl list-timers ansible-pull.timer` shows the next run time
- Full integration suite: not run yet on a bootstrapped Ubuntu host

Open issues:
- Need one real-machine check to confirm the timer update survives a scheduled pull run.
- `switch-pull-branch.sh` and `/etc/ansible/bootstrap-vars.yml` must stay aligned if branch behavior changes.

Environment notes:
- Integration tests require root on a bootstrapped Ubuntu host
- Runtime inventory is generated under `${DEST}/inventory/runtime-hosts.yml`
- Host vars resolve by short hostname first, then FQDN

Next best step:
- Run the updated integration test on a bootstrapped Ubuntu machine and verify `journalctl -u ansible-pull.service` after the next timer fire.
```
