#!/usr/bin/env bash
# Pre-push gate. Runs the fast unit tests first and, only if they pass, the
# full Multipass VM integration mirror — so nothing reaches the remote without
# both the quality unit suite and the integration matrix passing locally.
#
# Installed as .git/hooks/pre-push by scripts/setup-dev.sh (via a thin shim that
# execs this tracked file, so edits here take effect without reinstalling).
#
# Escape hatches:
#   git push --no-verify           # skip the gate entirely
#   SKIP_VM_TESTS=1 git push       # run unit tests only, skip the (slow) VMs
#   MP_TARGET=22.04 git push       # run a single release instead of both
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

if [[ ! -x .venv/bin/python ]]; then
  echo "pre-push: .venv not found — run ./scripts/setup-dev.sh first." >&2
  exit 1
fi

echo "pre-push: [1/2] running unit tests..."
# Redirect stdin from /dev/null: git feeds the hook ref data on stdin, and a
# unit test that reads stdin should see EOF rather than the push payload.
.venv/bin/python -m pytest -q tests/test_*.py </dev/null
echo "pre-push: unit tests passed."

if [[ "${SKIP_VM_TESTS:-}" == "1" ]]; then
  echo "pre-push: SKIP_VM_TESTS=1 — skipping VM integration; push NOT fully verified." >&2
  exit 0
fi

echo "pre-push: [2/2] running VM integration mirror (Multipass; takes a few minutes)..."
./scripts/local-ci.sh
echo "pre-push: all checks passed."
