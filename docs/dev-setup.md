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

## Local CI mirror via Multipass

The `integration` job in CI cannot be reproduced by running pytest on your dev
box directly — the playbook is Ubuntu-only and converges the *running host*, so
running it locally would mutate your workstation (and your dev box may not even
be one of the CI matrix releases). `scripts/local-ci.sh` spins up disposable
Ubuntu 22.04 and 24.04 KVM VMs via Multipass, copies the working tree in, and
runs the same converge + integration pytest sequence GitHub Actions runs on the
hosted runners.

Multipass gives real VMs (not containers), so kernel-level steps — NVIDIA
driver pinning, the kmod mitigation, SSSD/AD enrollment — behave the same way
they do on CI's runners.

One-time host setup on Ubuntu:

```bash
sudo snap install multipass
```

(Earlier revisions of this repo used a Vagrant + libvirt mirror. Vagrant was
dropped from the Ubuntu archive after its BSL relicense, so the local mirror
moved to Multipass, which is native on an Ubuntu dev box.)

Run the local CI matrix from the repo root:

```bash
make local-integration              # both 22.04 and 24.04
make local-integration MP_TARGET=22.04
multipass delete --purge ansible-pull-ci-22-04 ansible-pull-ci-24-04   # tear down
```

The VMs converge against the working tree exactly as you have it locally
(uncommitted changes included, except `.git/` and the volatile `.venv/`,
`.pre-commit-cache/`, `.ansible/` dirs), so this catches the same failures CI
would catch before pushing. The branch name persisted into the in-VM
`/etc/ansible/pull.env` defaults to whatever the local checkout is on; set
`TEST_GIT_BRANCH=other-branch make local-integration` to override.

Each run recreates the VM from scratch to match CI's ephemeral runners. On
failure the VM is left running so you can inspect it with
`multipass shell ansible-pull-ci-22-04`.

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
