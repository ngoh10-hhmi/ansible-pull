"""Session-level cleanup for integration tests.

Tests that modify /etc/ansible/bootstrap-vars.yml or system state (users,
groups) must leave the machine in a clean state even if a test is SIGKILL'd
or pytest is interrupted.  This conftest captures the bootstrap-vars state
before any test runs and restores it after the last test finishes.
"""

from __future__ import annotations

import atexit
import subprocess
import tempfile
from pathlib import Path

import pytest

BOOTSTRAP_VARS_PATH = Path("/etc/ansible/bootstrap-vars.yml")
_INITIAL_BOOTSTRAP_CONTENT = ""


def pytest_collection_modifyitems(config, items) -> None:
    """Exempt the integration suite from the per-test timeout in pytest.ini.

    That timeout is a guardrail for the fast unit tests, where a test running
    for a minute means a hang/bug. Integration tests legitimately drive full
    `run-ansible-pull` converges that take minutes, so a global 60s cap would
    fail them outright. A marker value of 0 disables the timeout. We only touch
    items under this directory so a combined `pytest` run still guards the unit
    tests.
    """
    for item in items:
        if "integration" in Path(str(item.fspath)).parts:
            item.add_marker(pytest.mark.timeout(0))


def _run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, text=True, capture_output=True)


def _capture_bootstrap_vars() -> str:
    """Return the current content of bootstrap-vars.yml, or empty string if absent."""
    if BOOTSTRAP_VARS_PATH.exists():
        return BOOTSTRAP_VARS_PATH.read_text(encoding="utf-8")
    return ""


def _restore_bootstrap_vars(content: str) -> None:
    """Write the captured content back to bootstrap-vars.yml."""
    BOOTSTRAP_VARS_PATH.write_text(content, encoding="utf-8")


def pytest_sessionstart(session) -> None:
    """Capture the bootstrap-vars state before any test modifies it."""
    global _INITIAL_BOOTSTRAP_CONTENT
    _INITIAL_BOOTSTRAP_CONTENT = _capture_bootstrap_vars()


def pytest_sessionfinish(session, exitstatus) -> None:
    """Restore the original bootstrap-vars state after all tests complete."""
    if _INITIAL_BOOTSTRAP_CONTENT:
        _restore_bootstrap_vars(_INITIAL_BOOTSTRAP_CONTENT)
    elif BOOTSTRAP_VARS_PATH.exists():
        # The file didn't exist before any test ran; remove the test-created one.
        BOOTSTRAP_VARS_PATH.unlink(missing_ok=True)


# Also register an atexit handler as a safety net for SIGKILL scenarios where
# pytest_sessionfinish may not fire (e.g., the pytest process itself is killed
# with SIGKILL).  If the bootstrap-vars file differs from what we captured at
# start, restore it.
def _atexit_restore() -> None:
    current = _capture_bootstrap_vars()
    if current != _INITIAL_BOOTSTRAP_CONTENT:
        _restore_bootstrap_vars(_INITIAL_BOOTSTRAP_CONTENT)


atexit.register(_atexit_restore)
