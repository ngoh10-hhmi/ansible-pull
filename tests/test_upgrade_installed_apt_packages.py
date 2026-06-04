from __future__ import annotations

import os
import shlex
import subprocess
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = "scripts/upgrade-installed-apt-packages.sh"


def run_bash(script: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-lc", script],
        cwd=REPO_ROOT,
        check=check,
        text=True,
        capture_output=True,
        env=os.environ.copy(),
    )


def test_parse_args_collects_repeated_restart_verify() -> None:
    result = run_bash(
        textwrap.dedent(
            f"""\
            source {HELPER}
            parse_args --label managed-baseline --list-file /tmp/list \
              --restart-verify sssd:sssd,sssd-common \
              --restart-verify foo:bar
            echo "LABEL=${{LABEL}}"
            echo "LIST=${{LIST_FILE}}"
            printf 'SPEC=%s\\n' "${{RESTART_VERIFY_SPECS[@]}}"
            """
        )
    )

    assert "LABEL=managed-baseline" in result.stdout
    assert "LIST=/tmp/list" in result.stdout
    assert "SPEC=sssd:sssd,sssd-common" in result.stdout
    assert "SPEC=foo:bar" in result.stdout


def test_restart_verify_restarts_service_when_trigger_package_upgraded() -> None:
    result = run_bash(
        textwrap.dedent(
            f"""\
            source {HELPER}
            LABEL=managed-baseline
            RESTART_VERIFY_SPECS=("sssd:sssd,sssd-common,sssd-tools")
            systemctl() {{
              case "$1" in
                restart) echo "restart $2"; return 0 ;;
                is-active) return 0 ;;
              esac
            }}
            restart_verify_services "sssd-common vim"
            """
        )
    )

    assert "Critical service sssd had upgraded packages" in result.stdout
    assert "restart sssd" in result.stdout
    assert "sssd is active after the post-upgrade restart" in result.stdout


def test_restart_verify_is_noop_when_no_trigger_package_upgraded() -> None:
    # systemctl is stubbed to fail loudly if called; the service should not be
    # touched because none of its trigger packages were in the upgraded set.
    result = run_bash(
        textwrap.dedent(
            f"""\
            source {HELPER}
            LABEL=managed-baseline
            RESTART_VERIFY_SPECS=("sssd:sssd,sssd-common,sssd-tools")
            systemctl() {{ echo "UNEXPECTED systemctl $*" >&2; return 1; }}
            restart_verify_services "vim curl"
            """
        )
    )

    assert result.returncode == 0
    assert "UNEXPECTED systemctl" not in result.stderr
    assert "had upgraded packages" not in result.stdout


def test_restart_verify_fails_when_service_not_active_after_restart() -> None:
    result = run_bash(
        textwrap.dedent(
            f"""\
            source {HELPER}
            LABEL=managed-baseline
            RESTART_VERIFY_SPECS=("sssd:sssd,sssd-common,sssd-tools")
            systemctl() {{
              case "$1" in
                restart) return 0 ;;
                is-active) return 3 ;;
              esac
            }}
            restart_verify_services "sssd"
            """
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "sssd is not active after restart" in result.stderr
    assert "Critical services not healthy after managed-baseline upgrade: sssd" in result.stderr


def test_restart_verify_fails_when_restart_command_fails() -> None:
    result = run_bash(
        textwrap.dedent(
            f"""\
            source {HELPER}
            LABEL=managed-baseline
            RESTART_VERIFY_SPECS=("sssd:sssd")
            systemctl() {{
              case "$1" in
                restart) return 1 ;;
                is-active) return 0 ;;
              esac
            }}
            restart_verify_services "sssd"
            """
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "failed to restart sssd" in result.stderr


def test_restart_verify_skips_malformed_spec_without_colon() -> None:
    result = run_bash(
        textwrap.dedent(
            f"""\
            source {HELPER}
            LABEL=managed-baseline
            RESTART_VERIFY_SPECS=("sssd-no-colon")
            systemctl() {{ echo "UNEXPECTED systemctl $*" >&2; return 1; }}
            restart_verify_services "sssd"
            """
        )
    )

    assert result.returncode == 0
    assert "UNEXPECTED systemctl" not in result.stderr


def test_run_upgrade_restarts_when_watched_trigger_dependency_changes(
    tmp_path: Path,
) -> None:
    package_list = tmp_path / "managed-package-updates.list"
    package_list.write_text("sssd\n", encoding="utf-8")

    result = run_bash(
        textwrap.dedent(
            f"""\
            source {HELPER}
            LABEL=managed-baseline
            LIST_FILE={shlex.quote(str(package_list))}
            RESTART_VERIFY_SPECS=("sssd:sssd,libpam-sss")
            APT_INSTALL_DONE=0

            dpkg-query() {{
              local package="${{@: -1}}"
              case "$*" in
                *'${{Status}}'*)
                  case "${{package}}" in
                    sssd|libpam-sss) echo "install ok installed"; return 0 ;;
                    *) return 1 ;;
                  esac
                  ;;
                *'${{Version}}'*)
                  case "${{package}}" in
                    sssd) echo "1.0"; return 0 ;;
                    libpam-sss)
                      if [[ "${{APT_INSTALL_DONE}}" == 1 ]]; then
                        echo "2.0"
                      else
                        echo "1.0"
                      fi
                      return 0
                      ;;
                    *) return 1 ;;
                  esac
                  ;;
              esac
            }}

            apt-cache() {{ echo "  Candidate: 1.0"; }}
            apt-get() {{
              case "$1" in
                update) echo "apt update"; return 0 ;;
                install) APT_INSTALL_DONE=1; echo "apt install $*"; return 0 ;;
              esac
            }}
            systemctl() {{
              case "$1" in
                restart) echo "restart $2"; return 0 ;;
                is-active) return 0 ;;
              esac
            }}

            run_upgrade
            """
        )
    )

    assert "apt install install -y --only-upgrade" in result.stdout
    assert "Critical service sssd had upgraded packages" in result.stdout
    assert "restart sssd" in result.stdout
    assert "sssd is active after the post-upgrade restart" in result.stdout


def test_read_requested_packages_skips_comments_and_blanks(tmp_path: Path) -> None:
    package_list = tmp_path / "managed-package-updates.list"
    package_list.write_text(
        textwrap.dedent(
            """\
            # baseline packages
            sssd

            vim
              # indented comment
            curl
            """
        ),
        encoding="utf-8",
    )

    result = run_bash(
        "\n".join(
            [
                f"source {HELPER}",
                f"read_requested_packages {shlex.quote(str(package_list))}",
            ]
        )
    )

    lines = [line for line in result.stdout.splitlines() if line]
    assert lines == ["sssd", "vim", "curl"]


def test_run_upgrade_reports_missing_list_file(tmp_path: Path) -> None:
    missing = tmp_path / "absent.list"
    result = run_bash(
        textwrap.dedent(
            f"""\
            source {HELPER}
            LABEL=managed-baseline
            LIST_FILE={shlex.quote(str(missing))}
            run_upgrade
            """
        )
    )

    assert "No readable package list found for managed-baseline" in result.stdout
