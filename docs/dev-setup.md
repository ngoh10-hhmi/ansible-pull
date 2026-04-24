# Developer Setup

This repo keeps the local developer workflow intentionally small.

The expected local setup is:

1. use Python 3.12 or newer for the full Ansible toolchain
2. create a repo-local virtualenv
3. install the pinned Python tools
4. install `shellcheck`
5. install the local `pre-commit` hook

## Quick Start

On a new development machine:

```bash
git clone https://github.com/ngoh10-hhmi/ansible-pull.git
cd ansible-pull
./scripts/setup-dev.sh
```

If you already have the repo cloned, run this from the repo root:

```bash
./scripts/setup-dev.sh
```

That script:

- prefers `python3.12` when it is installed
- otherwise uses `python3.13`, `python3.14`, or `python3` when available and
  Python 3.12 or newer
- installs the pinned toolchain from `requirements-dev.txt`
- checks for `shellcheck`
- installs the local `pre-commit` hook

For full local parity with CI and the pinned Ansible toolchain, use Python 3.12
or newer. Older interpreters may still create a virtualenv, but not every
Ansible-related check is expected to work there.

## Manual Setup

If you prefer to do the steps yourself:

```bash
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install -U pip
python -m pip install -r requirements-dev.txt
brew install shellcheck
PRE_COMMIT_HOME=.pre-commit-cache pre-commit install
```

If `python3.12` is not installed but your default `python3` is already 3.12 or
newer, use that instead.

## Why Python 3.12

The pinned toolchain in `requirements-ci.txt` currently expects Python 3.12 or
newer for the full Ansible workflow. CI exercises Python 3.12 and 3.14 so the
supported path stays explicit and tested.

On macOS, the system `python3` may still be 3.9, which is too old for the
pinned `ansible-core` version used here.

The repo includes `.python-version` to make that expectation more obvious for
people using `pyenv` or similar tools.

## Common Commands

After setup:

```bash
source .venv/bin/activate
make doctor
make lint
```

Or run the helper directly:

```bash
./scripts/check.sh
```

If you want a fast sanity check before linting everything:

```bash
make doctor
```

For integration tests on a bootstrapped Ubuntu host:

```bash
source .venv/bin/activate
make integration
```

## Gotchas

- `pre-commit` runs locally. It does not upload anything to GitHub.
- The Git hook is installed only for this clone.
- `shellcheck` is not installed by `pip`; it must exist on the machine.
- If `pre-commit` complains about missing tools, make sure the repo virtualenv
  is still present at `.venv`.
- If you are in a constrained environment where `~/.cache/pre-commit` is not
  writable, set `PRE_COMMIT_HOME=.pre-commit-cache` before running it.
- If you need a quick local diagnosis, run `make doctor`.

For broader local and workstation troubleshooting, see
[docs/troubleshooting.md](troubleshooting.md).
