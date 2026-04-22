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


def bootstrap_fixture_assignments(tmp_path: Path) -> str:
    return "\n".join(
        [
            f'BOOTSTRAP_VARS_FILE={shlex.quote(str(tmp_path / "bootstrap-vars.yml"))}',
            'REPO_URL="https://github.com/example/ansible-pull.git"',
            'BRANCH="testing"',
            'PLAYBOOK="playbooks/workstation.yml"',
            f'DEST={shlex.quote(str(tmp_path / "checkout"))}',
            f'LOG_DIR={shlex.quote(str(tmp_path / "logs dir"))}',
            'SHORT_HOSTNAME="hhmi-test"',
            'MACHINE_TYPE="laptop"',
        ]
    )


def test_configure_git_credentials_rejects_both_token_sources(tmp_path: Path) -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                'GITHUB_USER="machine-reader"',
                'GITHUB_TOKEN="abc123"',
                f'GITHUB_TOKEN_FILE={shlex.quote(str(tmp_path / "token.txt"))}',
                "configure_git_credentials",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "Use either --github-token or --github-token-file, not both." in result.stderr


def test_configure_git_credentials_rejects_missing_token_file(tmp_path: Path) -> None:
    missing_file = tmp_path / "missing-token.txt"
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                f'GITHUB_TOKEN_FILE={shlex.quote(str(missing_file))}',
                "configure_git_credentials",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert f"Token file does not exist: {missing_file}" in result.stderr


def test_write_bootstrap_vars_initial_state_omits_bootstrap_only_keys(tmp_path: Path) -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                bootstrap_fixture_assignments(tmp_path),
                'SUDO_USERS=("alice" "bob")',
                "write_bootstrap_vars_initial_state",
                'cat "${BOOTSTRAP_VARS_FILE}"',
            ]
        )
    )

    assert 'base_ad_enroll: false' in result.stdout
    assert 'base_manage_bootstrap_sudo_users' not in result.stdout
    assert 'base_bootstrap_sudo_users' not in result.stdout
    assert 'ad_join_user' not in result.stdout


def test_write_bootstrap_vars_ad_phase_state_includes_bootstrap_only_keys(tmp_path: Path) -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                bootstrap_fixture_assignments(tmp_path),
                'SUDO_USERS=("alice" "bob")',
                "write_bootstrap_vars_ad_phase_state",
                'cat "${BOOTSTRAP_VARS_FILE}"',
            ]
        )
    )

    assert 'base_ad_enroll: true' in result.stdout
    assert 'base_manage_bootstrap_sudo_users: true' in result.stdout
    assert 'base_bootstrap_sudo_users:' in result.stdout
    assert '  - alice' in result.stdout
    assert '  - bob' in result.stdout
    assert 'ad_join_user' not in result.stdout


def test_cleanup_bootstrap_state_rewrites_initial_state_after_failed_ad_phase(tmp_path: Path) -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                bootstrap_fixture_assignments(tmp_path),
                'SUDO_USERS=("alice")',
                'BOOTSTRAP_PHASE="ad_phase"',
                'AD_CONVERGE_SUCCEEDED="false"',
                "write_bootstrap_vars_ad_phase_state",
                "cleanup_bootstrap_state_on_exit",
                'cat "${BOOTSTRAP_VARS_FILE}"',
            ]
        )
    )

    assert 'base_ad_enroll: false' in result.stdout
    assert 'base_manage_bootstrap_sudo_users' not in result.stdout
    assert 'base_bootstrap_sudo_users' not in result.stdout


def test_cleanup_bootstrap_state_rewrites_final_state_after_successful_ad_phase(tmp_path: Path) -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                bootstrap_fixture_assignments(tmp_path),
                'SUDO_USERS=("alice")',
                'BOOTSTRAP_PHASE="post_ad_converge"',
                'AD_CONVERGE_SUCCEEDED="true"',
                "write_bootstrap_vars_ad_phase_state",
                "cleanup_bootstrap_state_on_exit",
                'cat "${BOOTSTRAP_VARS_FILE}"',
            ]
        )
    )

    assert 'base_ad_enroll: true' in result.stdout
    assert 'base_manage_bootstrap_sudo_users' not in result.stdout
    assert 'base_bootstrap_sudo_users' not in result.stdout


def test_enable_pull_timer_failure_is_fatal() -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                "systemctl() { return 1; }",
                "enable_pull_timer",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "Failed to enable ansible-pull.timer." in result.stderr


def test_is_valid_short_hostname_accepts_expected_values() -> None:
    run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            valid_names=("hhmi-test" "ws01" "A" "node-9")
            for name in "${valid_names[@]}"; do
              is_valid_short_hostname "$name"
            done
            """
        )
    )


def test_is_valid_short_hostname_rejects_invalid_values() -> None:
    run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            invalid_names=("" "bad name" "-bad" "bad-" "bad_name" "bad.name" "hostname-that-is-too-long")
            for name in "${invalid_names[@]}"; do
              if is_valid_short_hostname "$name"; then
                printf 'unexpectedly accepted: %s\n' "$name" >&2
                exit 1
              fi
            done
            """
        )
    )


def test_pull_env_round_trip_preserves_shell_metacharacters(tmp_path: Path) -> None:
    env_file = tmp_path / "pull.env"
    result = run_bash(
        textwrap.dedent(
            f"""\
            source scripts/lib/envfile.sh
            REPO_URL='https://example.invalid/repo?x=1&y=$HOME'
            BRANCH='testing/feature'
            PLAYBOOK='playbooks/workstation.yml'
            DEST={shlex.quote(str(tmp_path / "checkout dir"))}
            LOG_DIR={shlex.quote(str(tmp_path / "logs dir"))}
            SLACK_WEBHOOK_URL='https://hooks.slack.invalid/services/T000/B000/XYZ?foo=1&bar=$HOME'
            SLACK_NOTIFY_SUCCESS='true'
            write_pull_env_file {shlex.quote(str(env_file))}
            unset REPO_URL BRANCH PLAYBOOK DEST LOG_DIR SLACK_WEBHOOK_URL SLACK_NOTIFY_SUCCESS
            load_env_file {shlex.quote(str(env_file))}
            validate_pull_env
            printf 'REPO_URL=%s\\n' "$REPO_URL"
            printf 'DEST=%s\\n' "$DEST"
            printf 'LOG_DIR=%s\\n' "$LOG_DIR"
            printf 'SLACK_WEBHOOK_URL=%s\\n' "$SLACK_WEBHOOK_URL"
            printf 'SLACK_NOTIFY_SUCCESS=%s\\n' "$SLACK_NOTIFY_SUCCESS"
            """
        )
    )

    assert "REPO_URL=https://example.invalid/repo?x=1&y=$HOME" in result.stdout
    assert f"DEST={tmp_path / 'checkout dir'}" in result.stdout
    assert f"LOG_DIR={tmp_path / 'logs dir'}" in result.stdout
    assert "SLACK_WEBHOOK_URL=https://hooks.slack.invalid/services/T000/B000/XYZ?foo=1&bar=$HOME" in result.stdout
    assert "SLACK_NOTIFY_SUCCESS=true" in result.stdout
