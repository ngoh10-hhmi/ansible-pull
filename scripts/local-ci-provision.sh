#!/usr/bin/env bash
# Mirror of the GitHub Actions "integration" job, run inside a fresh
# Vagrant-managed Ubuntu VM. Invoked by the Vagrantfile at repo root.
# Vagrant runs shell provisioners as root, so the "sudo" wrappers CI uses
# are unnecessary here.
set -euo pipefail

REPO_DIR="${REPO_DIR:-/vagrant}"
TEST_GIT_BRANCH="${TEST_GIT_BRANCH:-testing}"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y git python3-apt shellcheck

# CI uses actions/setup-python to get a managed Python 3.12 regardless of
# distro. 24.04 ships 3.12 in the binary but not its venv module; 22.04
# does not have 3.12 at all. Add the deadsnakes PPA on releases where
# python3.12 is missing, then install 3.12 + its venv package on both —
# setup-dev.sh needs `python3.12 -m venv` to succeed.
if ! command -v python3.12 >/dev/null 2>&1; then
  apt-get install -y software-properties-common
  add-apt-repository -y ppa:deadsnakes/ppa
  apt-get update
fi
apt-get install -y python3.12 python3.12-venv

cd "${REPO_DIR}"

# The integration tests invoke run-ansible-pull against /vagrant as a git
# remote on TEST_GIT_BRANCH (REPO_URL in pull.env, BRANCH in pull.env).
# Without a real commit on that branch, git_sync.sh's fetch/reset/clean
# pipeline aborts. Stage a disposable single-commit repo here, and refresh
# it on every provision so the snapshot tracks the latest rsynced files.
# setup-dev.sh's terminal `pre-commit install` also needs .git/ to exist,
# so doing this before the venv build covers both needs.
rm -rf .git
git init --quiet --initial-branch="${TEST_GIT_BRANCH}"
git -c user.email=vagrant@local -c user.name=vagrant add -A
git -c user.email=vagrant@local -c user.name=vagrant \
  commit --quiet -m "vagrant snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# A venv rsynced in from the Fedora host would be wired to a different
# Python and would not work here. Rebuild from scratch every provision
# so the inside-the-VM venv is always self-consistent.
rm -rf .venv .pre-commit-cache
./scripts/setup-dev.sh

PATH="${REPO_DIR}/.venv/bin:${PATH}"
export PATH
export TEST_GIT_BRANCH

# Match CI's "Converge workstation playbook" step.
env "PATH=${PATH}" ansible-playbook \
  --inventory inventory/hosts.yml \
  playbooks/workstation.yml \
  --extra-vars "base_ansible_pull_repo_url=${REPO_DIR}" \
  --extra-vars "base_ansible_pull_branch=${TEST_GIT_BRANCH}"

# Match CI's "Run integration tests" step.
env "PATH=${PATH}" python -m pytest -q tests/integration
