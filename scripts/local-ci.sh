#!/usr/bin/env bash
# Local CI mirror via Multipass: boot disposable Ubuntu 22.04 + 24.04 KVM VMs,
# copy the working tree in, and run the same converge + integration pytest
# sequence GitHub Actions runs on the hosted runners.
#
# This replaces the earlier Vagrant + libvirt mirror. Vagrant was dropped from
# the Ubuntu archive (BSL relicense), so on an Ubuntu dev box Multipass is the
# native way to get disposable Ubuntu VMs. The in-VM steps still live in
# scripts/local-ci-provision.sh, shared with this orchestrator.
#
# Usage from the repo root:
#   ./scripts/local-ci.sh                 # both releases, sequentially
#   MP_TARGET=22.04 ./scripts/local-ci.sh # one release only
#   TEST_GIT_BRANCH=other ./scripts/...   # label the working-tree snapshot as
#                                         # this branch (must match BRANCH in
#                                         # pull.env); it does not check out or
#                                         # converge a different branch
#
# Or via make:
#   make local-integration
#   make local-integration MP_TARGET=24.04
#
# One-time host setup on Ubuntu:
#   sudo snap install multipass
#
# Tear down leftover instances:
#   multipass delete --purge ansible-pull-ci-22-04 ansible-pull-ci-24-04
set -euo pipefail
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TEST_GIT_BRANCH="${TEST_GIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

# Guest-local copy of the tree. This is deliberately NOT a Multipass mount of
# the host working tree: local-ci-provision.sh does `rm -rf .git` and rebuilds
# the venv inside REPO_DIR, which on a live mount would destroy the host repo.
# We stream a copy in instead, mirroring what Vagrant's rsync synced-folder did.
GUEST_REPO="/home/ubuntu/ansible-pull"

CPUS="${MP_CPUS:-2}"
MEM="${MP_MEM:-2G}"
DISK="${MP_DISK:-10G}"

# Releases mirror the GitHub Actions integration matrix.
ALL_RELEASES=(22.04 24.04)
if [[ -n "${MP_TARGET:-}" ]]; then
  RELEASES=("${MP_TARGET}")
else
  RELEASES=("${ALL_RELEASES[@]}")
fi

instance_name() { printf 'ansible-pull-ci-%s' "${1//./-}"; }

run_release() {
  local release="$1"
  local name
  name="$(instance_name "$release")"

  echo "==> [$release] (re)launching $name"
  # Fresh VM every run, matching CI's ephemeral runners.
  if multipass info "$name" >/dev/null 2>&1; then
    multipass delete --purge "$name"
  fi

  multipass launch "$release" --name "$name" \
      --cpus "$CPUS" --memory "$MEM" --disk "$DISK" \
    && multipass exec "$name" -- mkdir -p "$GUEST_REPO" \
    && echo "==> [$release] copying working tree into $GUEST_REPO" \
    && tar -cf - \
        --exclude=./.git \
        --exclude=./.venv \
        --exclude=./.pre-commit-cache \
        --exclude=./.ansible \
        --exclude=./.vagrant \
        --exclude='*/__pycache__' \
        -C "$REPO_ROOT" . \
      | multipass exec "$name" -- tar -xf - -C "$GUEST_REPO" \
    && echo "==> [$release] converge + pytest (branch=$TEST_GIT_BRANCH)" \
    && multipass exec "$name" -- \
        sudo env TEST_GIT_BRANCH="$TEST_GIT_BRANCH" REPO_DIR="$GUEST_REPO" \
          bash "$GUEST_REPO/scripts/local-ci-provision.sh"
}

failed=()
for release in "${RELEASES[@]}"; do
  if run_release "$release"; then
    echo "==> [$release] PASS"
  else
    echo "==> [$release] FAIL"
    failed+=("$release")
  fi
done

if ((${#failed[@]})); then
  echo "Local CI FAILED on: ${failed[*]}" >&2
  echo "Inspect a failed VM with: multipass shell $(instance_name "${failed[0]}")" >&2
  exit 1
fi

echo "Local CI passed on: ${RELEASES[*]}"
