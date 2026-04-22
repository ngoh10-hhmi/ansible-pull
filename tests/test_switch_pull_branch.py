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


def switch_fixture_assignments(tmp_path: Path) -> str:
    return "\n".join(
        [
            f'ENV_FILE={shlex.quote(str(tmp_path / "pull.env"))}',
            f'BOOTSTRAP_VARS_FILE={shlex.quote(str(tmp_path / "bootstrap-vars.yml"))}',
        ]
    )


def test_require_bootstrap_vars_file_fails_when_missing(tmp_path: Path) -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/switch-pull-branch.sh",
                switch_fixture_assignments(tmp_path),
                "require_bootstrap_vars_file",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert f"Missing {tmp_path / 'bootstrap-vars.yml'}." in result.stderr


def test_write_bootstrap_vars_preserves_existing_machine_local_keys(tmp_path: Path) -> None:
    bootstrap_vars_file = tmp_path / "bootstrap-vars.yml"
    bootstrap_vars_file.write_text(
        textwrap.dedent(
            """\
            base_ansible_pull_repo_url: "https://github.com/example/old.git"
            base_ansible_pull_branch: "main"
            base_ansible_pull_playbook: "playbooks/workstation.yml"
            base_ansible_pull_directory: "/var/lib/ansible-pull"
            base_ansible_pull_log_dir: "/var/log/ansible-pull"
            target_hostname: "ws-01"
            machine_type: "laptop"
            base_ad_enroll: true
            extra_flag: true
            """
        ),
        encoding="utf-8",
    )

    result = run_bash(
        "\n".join(
            [
                "source scripts/switch-pull-branch.sh",
                switch_fixture_assignments(tmp_path),
                'REPO_URL="https://github.com/example/new.git"',
                'BRANCH="testing"',
                'PLAYBOOK="playbooks/workstation.yml"',
                'DEST="/srv/ansible-pull"',
                'LOG_DIR="/srv/ansible-pull/logs"',
                "write_bootstrap_vars",
                'cat "${BOOTSTRAP_VARS_FILE}"',
            ]
        )
    )

    assert 'base_ansible_pull_repo_url: "https://github.com/example/new.git"' in result.stdout
    assert 'base_ansible_pull_branch: "testing"' in result.stdout
    assert 'base_ansible_pull_directory: "/srv/ansible-pull"' in result.stdout
    assert 'target_hostname: "ws-01"' in result.stdout
    assert 'machine_type: "laptop"' in result.stdout
    assert 'base_ad_enroll: true' in result.stdout
    assert 'extra_flag: true' in result.stdout


def test_write_pull_env_preserves_existing_slack_settings(tmp_path: Path) -> None:
    env_file = tmp_path / "pull.env"
    env_file.write_text(
        "\n".join(
            [
                'REPO_URL="https://github.com/example/old.git"',
                'BRANCH="main"',
                'PLAYBOOK="playbooks/workstation.yml"',
                'DEST="/var/lib/ansible-pull"',
                'LOG_DIR="/var/log/ansible-pull"',
                'SLACK_WEBHOOK_URL="https://hooks.slack.invalid/services/T000/B000/XYZ"',
                'SLACK_NOTIFY_SUCCESS="true"',
                "",
            ]
        ),
        encoding="utf-8",
    )

    result = run_bash(
        "\n".join(
            [
                "source scripts/switch-pull-branch.sh",
                switch_fixture_assignments(tmp_path),
                "load_existing_pull_env",
                'NEW_BRANCH="testing"',
                'NEW_REPO_URL="https://github.com/example/new.git"',
                "apply_branch_settings",
                "write_pull_env",
                'cat "${ENV_FILE}"',
            ]
        )
    )

    assert "REPO_URL=https://github.com/example/new.git" in result.stdout
    assert "BRANCH=testing" in result.stdout
    assert "SLACK_WEBHOOK_URL=https://hooks.slack.invalid/services/T000/B000/XYZ" in result.stdout
    assert "SLACK_NOTIFY_SUCCESS=true" in result.stdout
