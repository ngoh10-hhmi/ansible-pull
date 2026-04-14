# Git Worktree Setup

This repo works well with a small Git worktree layout:

- one working directory on `testing` for day-to-day changes
- one sibling working directory on `main` as a clean reference
- optional temporary feature worktrees for risky or isolated changes

## Recommended layout

Example:

```text
/Users/ngoh10/Documents/projects/
  ansible-pull/        # active testing worktree
  ansible-pull-main/   # clean main worktree
```

This keeps your normal `testing` work separate from a stable `main` checkout
without needing multiple full clones.

## Why use worktrees here

- You can keep `testing` and `main` open at the same time.
- You avoid repeated branch switching in one directory.
- You can compare risky changes against `main` side by side.
- Temporary experiments do not need to live in your normal working tree.

This is especially useful in this repo because bootstrap, timer, and AD-related
changes are easier to reason about when you can compare them directly against
the current `main` branch.

## Current recommended pattern

Keep your normal repo path on `testing`:

```bash
cd /Users/ngoh10/Documents/projects/ansible-pull
git branch --show-current
```

Add a sibling `main` worktree:

```bash
git worktree add ../ansible-pull-main main
```

That gives you:

- `/Users/ngoh10/Documents/projects/ansible-pull` on `testing`
- `/Users/ngoh10/Documents/projects/ansible-pull-main` on `main`

## Useful commands

List worktrees:

```bash
git worktree list
```

Create a temporary feature worktree:

```bash
git worktree add ../ansible-pull-feature-slack -b feature/slack-tuning
```

Remove a temporary worktree when you are done:

```bash
git worktree remove ../ansible-pull-feature-slack
git worktree prune
```

## Important caveat about renaming the main worktree

The original cloned repo directory is the main worktree.

Git can move linked worktrees with `git worktree move`, but it does **not** move
the main worktree that way.

If you ever want to rename the main worktree directory, the safe sequence is:

```bash
cd /Users/ngoh10/Documents/projects
mv ansible-pull ansible-pull-testing
cd ansible-pull-testing
git worktree repair
git worktree list
```

Why `git worktree repair` matters:

- linked worktrees store metadata pointing back to the main worktree
- after a manual rename, that metadata needs to be refreshed

## Practical guidance

- Keep `ansible-pull` as your active `testing` tree unless there is a strong
  reason to rename it.
- Use `ansible-pull-main` as a read-clean reference checkout.
- Create feature worktrees only for isolated or risky tasks.
- If you manually move the main worktree later, run `git worktree repair`
  immediately afterward.
