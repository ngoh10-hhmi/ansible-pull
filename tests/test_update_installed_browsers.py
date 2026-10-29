from __future__ import annotations

import os
import shlex
import subprocess
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def run_bash(script: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-lc", script],
        cwd=REPO_ROOT,
        check=check,
        text=True,
        capture_output=True,
        env=os.environ.copy(),
    )


def test_refresh_snaps_individually_succeeds_when_all_pass() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/update-installed-browsers.sh
            snap() { return 0; }
            refresh_snaps_individually firefox chromium
            """
        )
    )

    assert "Refreshing snap: firefox" in result.stdout
    assert "Refreshing snap: chromium" in result.stdout
    assert "completed with failures" not in result.stderr


def test_refresh_snaps_individually_continues_after_one_failure() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/update-installed-browsers.sh
            snap() {
              # Args: refresh <name>
              if [[ "$2" == "firefox" ]]; then
                echo "error: cannot refresh firefox"
                return 1
              fi
              echo "${2} refreshed"
              return 0
            }
            refresh_snaps_individually firefox chromium
            """
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "Refreshing snap: firefox" in result.stdout
    assert "Refreshing snap: chromium" in result.stdout
    assert "chromium refreshed" in result.stdout
    assert "Snap firefox refresh failed" in result.stdout
    assert "completed with failures: firefox" in result.stderr


def test_refresh_snaps_individually_aggregates_multiple_failures() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/update-installed-browsers.sh
            snap() {
              if [[ "$2" == "firefox" || "$2" == "brave" ]]; then
                echo "error: cannot refresh $2"
                return 1
              fi
              return 0
            }
            refresh_snaps_individually firefox chromium brave
            """
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "completed with failures: firefox brave" in result.stderr


def test_refresh_snaps_individually_defers_running_snap() -> None:
    # Exact output snapd produced on support-ws2 (2026-10-29), wrapped by the
    # snap CLI across several lines.
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/update-installed-browsers.sh
            snap() {
              if [[ "$2" == "firefox" ]]; then
                printf '%s\\n' \\
                  'error: cannot refresh "firefox": snap "firefox"' \\
                  '       has running apps (firefox), pids:' \\
                  '       8448,8624,8717'
                return 1
              fi
              echo "${2} refreshed"
            }
            refresh_snaps_individually firefox chromium
            """
        )
    )

    assert result.returncode == 0
    assert "Snap firefox is running; deferring to snapd auto-refresh" in result.stdout
    assert "deferred while running: firefox" in result.stdout
    assert "chromium refreshed" in result.stdout
    assert "failed" not in result.stdout + result.stderr


def test_refresh_snaps_individually_running_snap_does_not_mask_real_failure() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/update-installed-browsers.sh
            snap() {
              case "$2" in
                firefox) echo 'error: snap "firefox" has running apps (firefox)'; return 1 ;;
                chromium) echo 'error: cannot refresh "chromium": store unavailable'; return 1 ;;
              esac
            }
            refresh_snaps_individually firefox chromium
            """
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "deferred while running: firefox" in result.stdout
    assert "Snap chromium refresh failed with exit code 1" in result.stdout
    assert "completed with failures: chromium" in result.stderr


def test_read_requested_snaps_skips_comments_and_blanks(tmp_path: Path) -> None:
    snap_list = tmp_path / "browser-snap-updates.list"
    snap_list.write_text(
        textwrap.dedent(
            """\
            # browser snaps
            firefox

            chromium
              # indented comment
            brave
            """
        ),
        encoding="utf-8",
    )

    result = run_bash(
        "\n".join(
            [
                "source scripts/update-installed-browsers.sh",
                f"read_requested_snaps {shlex.quote(str(snap_list))}",
            ]
        )
    )

    lines = [line for line in result.stdout.splitlines() if line]
    assert lines == ["firefox", "chromium", "brave"]


def test_run_snap_browser_updates_skips_when_snap_command_missing(tmp_path: Path) -> None:
    snap_list = tmp_path / "browser-snap-updates.list"
    snap_list.write_text("firefox\n", encoding="utf-8")

    result = run_bash(
        "\n".join(
            [
                "source scripts/update-installed-browsers.sh",
                f'SNAP_LIST_FILE={shlex.quote(str(snap_list))}',
                "command() { return 1; }",
                "run_snap_browser_updates",
            ]
        )
    )

    assert "snap command not available" in result.stdout


def test_run_snap_browser_updates_no_op_when_no_installed_match(tmp_path: Path) -> None:
    snap_list = tmp_path / "browser-snap-updates.list"
    snap_list.write_text("firefox\nchromium\n", encoding="utf-8")

    result = run_bash(
        textwrap.dedent(
            f"""\
            source scripts/update-installed-browsers.sh
            SNAP_LIST_FILE={shlex.quote(str(snap_list))}
            snap() {{ return 1; }}
            run_snap_browser_updates
            """
        )
    )

    assert "No installed browser snaps matched the update list" in result.stdout
