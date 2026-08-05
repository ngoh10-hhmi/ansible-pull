from __future__ import annotations

import os
import subprocess
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = "scripts/lib/apt_lock.sh"

# The exact stderr apt produced when managed-package-updates.service lost the
# lists-lock race with apt-refresh.service on 2026-08-05.
LISTS_LOCK_ERROR = (
    "E: Could not get lock /var/lib/apt/lists/lock. "
    "It is held by process 130630 (apt-get)\\n"
    "E: Unable to lock directory /var/lib/apt/lists/"
)


def run_bash(script: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-lc", script],
        cwd=REPO_ROOT,
        check=check,
        text=True,
        capture_output=True,
        env=os.environ.copy(),
    )


def test_detects_lists_lock_contention() -> None:
    result = run_bash(
        textwrap.dedent(
            f"""\
            source {HELPER}
            if apt_output_is_lock_contention "{LISTS_LOCK_ERROR}"; then
              echo MATCHED
            else
              echo UNMATCHED
            fi
            """
        )
    )

    assert "MATCHED" in result.stdout


def test_detects_dpkg_frontend_lock_contention() -> None:
    result = run_bash(
        textwrap.dedent(
            f"""\
            source {HELPER}
            message="E: Could not get lock /var/lib/dpkg/lock-frontend."
            message+=" It is held by process 4242 (unattended-upgr)"
            message+=$'\\n'"E: Unable to acquire the dpkg frontend lock"
            if apt_output_is_lock_contention "${{message}}"; then
              echo MATCHED
            else
              echo UNMATCHED
            fi
            """
        )
    )

    assert "MATCHED" in result.stdout


def test_does_not_treat_genuine_apt_failure_as_lock_contention() -> None:
    result = run_bash(
        textwrap.dedent(
            f"""\
            source {HELPER}
            message="E: The repository 'https://example.invalid stable Release'"
            message+=" does not have a Release file."
            if apt_output_is_lock_contention "${{message}}"; then
              echo MATCHED
            else
              echo UNMATCHED
            fi
            """
        )
    )

    assert "UNMATCHED" in result.stdout


def test_succeeds_without_retrying_when_apt_succeeds(tmp_path: Path) -> None:
    attempts = tmp_path / "attempts"

    result = run_bash(
        textwrap.dedent(
            f"""\
            set -euo pipefail
            source {HELPER}
            apt-get() {{
              echo "call" >> {attempts}
              echo "Reading package lists..."
              return 0
            }}
            sleep() {{ echo "UNEXPECTED SLEEP" ; return 1 ; }}
            apt_get_with_lock_retry update
            echo "STATUS=$?"
            """
        )
    )

    assert "STATUS=0" in result.stdout
    assert "Reading package lists..." in result.stdout
    assert attempts.read_text().count("call") == 1


def test_retries_until_lock_is_released(tmp_path: Path) -> None:
    attempts = tmp_path / "attempts"
    sleeps = tmp_path / "sleeps"

    result = run_bash(
        textwrap.dedent(
            f"""\
            set -euo pipefail
            export APT_LOCK_RETRY_INTERVAL_SEC=15
            export APT_LOCK_RETRY_TIMEOUT_SEC=600
            source {HELPER}
            apt-get() {{
              echo "call" >> {attempts}
              if (( $(grep -c call {attempts}) < 3 )); then
                printf '%s\\n' "{LISTS_LOCK_ERROR}" >&2
                return 100
              fi
              echo "Hit:1 http://us.archive.ubuntu.com/ubuntu resolute InRelease"
              return 0
            }}
            sleep() {{ echo "slept $1" >> {sleeps} ; }}
            apt_get_with_lock_retry update
            echo "STATUS=$?"
            """
        )
    )

    assert "STATUS=0" in result.stdout
    assert attempts.read_text().count("call") == 3
    assert sleeps.read_text().count("slept 15") == 2
    # The lock error is still surfaced on stderr rather than swallowed.
    assert "Could not get lock /var/lib/apt/lists/lock" in result.stderr
    assert "retrying in 15s (waited 0s of 600s)" in result.stdout


def test_returns_apt_exit_code_immediately_on_non_lock_failure(tmp_path: Path) -> None:
    attempts = tmp_path / "attempts"

    result = run_bash(
        textwrap.dedent(
            f"""\
            source {HELPER}
            apt-get() {{
              echo "call" >> {attempts}
              echo "E: Unable to locate package bogus-package" >&2
              return 100
            }}
            sleep() {{ echo "UNEXPECTED SLEEP" ; }}
            status=0
            apt_get_with_lock_retry install -y bogus-package || status=$?
            echo "STATUS=${{status}}"
            """
        )
    )

    assert "STATUS=100" in result.stdout
    assert "UNEXPECTED SLEEP" not in result.stdout
    assert attempts.read_text().count("call") == 1
    assert "Unable to locate package bogus-package" in result.stderr


def test_gives_up_and_fails_after_retry_budget_is_exhausted(tmp_path: Path) -> None:
    attempts = tmp_path / "attempts"
    sleeps = tmp_path / "sleeps"

    result = run_bash(
        textwrap.dedent(
            f"""\
            export APT_LOCK_RETRY_INTERVAL_SEC=15
            export APT_LOCK_RETRY_TIMEOUT_SEC=45
            source {HELPER}
            apt-get() {{
              echo "call" >> {attempts}
              printf '%s\\n' "{LISTS_LOCK_ERROR}" >&2
              return 100
            }}
            sleep() {{ echo "slept" >> {sleeps} ; }}
            status=0
            apt_get_with_lock_retry update || status=$?
            echo "STATUS=${{status}}"
            """
        )
    )

    # 45s budget at a 15s interval allows three sleeps, so four apt-get calls.
    assert "STATUS=100" in result.stdout
    assert attempts.read_text().count("call") == 4
    assert sleeps.read_text().count("slept") == 3
    assert "still blocked on an APT lock after 45s" in result.stderr


def test_removes_its_temporary_stderr_file(tmp_path: Path) -> None:
    tmpdir = tmp_path / "tmp"
    tmpdir.mkdir()

    result = run_bash(
        textwrap.dedent(
            f"""\
            set -euo pipefail
            export TMPDIR={tmpdir}
            source {HELPER}
            apt-get() {{ return 0 ; }}
            apt_get_with_lock_retry update
            echo "LEFTOVER=$(find {tmpdir} -name 'apt-lock-retry.*' | wc -l)"
            """
        )
    )

    assert "LEFTOVER=0" in result.stdout


def test_apt_helpers_route_every_apt_get_call_through_the_retry_wrapper() -> None:
    """apt-refresh and upgrade-installed-apt-packages must not call apt-get raw.

    A bare apt-get in either helper reintroduces the 2026-08-05 failure, where
    the daily upgrade timer lost the lists-lock race with the hourly refresh and
    exited 100 without upgrading anything.
    """
    result = run_bash(
        textwrap.dedent(
            """\
            grep -nE '(^|[^_[:alnum:]-])apt-get ' \
              scripts/apt-refresh.sh \
              scripts/upgrade-installed-apt-packages.sh \
              | grep -v '^\\s*#' | grep -vE '^[^:]+:[0-9]+:\\s*#' || true
            """
        )
    )

    assert result.stdout.strip() == "", f"raw apt-get call found:\n{result.stdout}"
