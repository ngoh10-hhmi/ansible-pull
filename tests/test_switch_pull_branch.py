from __future__ import annotations

import os
import shlex
import subprocess
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
VALID_SHA = "0123456789abcdef0123456789abcdef01234567"


def run_bash(script: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-lc", script],
        cwd=REPO_ROOT,
        check=check,
        text=True,
        capture_output=True,
        env=os.environ.copy(),
    )


def run(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        check=True,
        text=True,
        capture_output=True,
    )


def switch_fixture_assignments(tmp_path: Path) -> str:
    return "\n".join(
        [
            f'ENV_FILE={shlex.quote(str(tmp_path / "pull.env"))}',
            f'BOOTSTRAP_VARS_FILE={shlex.quote(str(tmp_path / "bootstrap-vars.yml"))}',
        ]
    )


def create_git_repo(path: Path) -> str:
    path.mkdir()
    run("git", "init", "--quiet", "-b", "main", cwd=path)
    run("git", "config", "user.name", "Switch Test", cwd=path)
    run("git", "config", "user.email", "switch-test@example.com", cwd=path)
    (path / "README.md").write_text("test repo\n", encoding="utf-8")
    run("git", "add", "README.md", cwd=path)
    run("git", "commit", "--quiet", "-m", "Initial commit", cwd=path)
    return run("git", "rev-parse", "HEAD", cwd=path).stdout.strip()


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


def test_validate_target_branch_accepts_existing_branch(tmp_path: Path) -> None:
    repo_dir = tmp_path / "repo"
    create_git_repo(repo_dir)

    run_bash(
        "\n".join(
            [
                "source scripts/switch-pull-branch.sh",
                f"REPO_URL={shlex.quote(str(repo_dir))}",
                'BRANCH="main"',
                "validate_target_branch",
            ]
        )
    )


def test_parse_args_rejects_branch_and_commit_together() -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/switch-pull-branch.sh",
                f"parse_args --branch main --commit {VALID_SHA}",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "Use either --branch or --commit, not both." in result.stderr


def test_parse_args_rejects_short_commit_pin() -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/switch-pull-branch.sh",
                "parse_args --commit abc123",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "Commit pin must be a full 40-character SHA." in result.stderr


def test_invalid_target_branch_leaves_state_untouched(tmp_path: Path) -> None:
    repo_dir = tmp_path / "repo"
    create_git_repo(repo_dir)
    env_file = tmp_path / "pull.env"
    bootstrap_vars_file = tmp_path / "bootstrap-vars.yml"
    env_file.write_text(
        "\n".join(
            [
                f"REPO_URL={shlex.quote(str(repo_dir))}",
                'BRANCH="main"',
                'PLAYBOOK="playbooks/workstation.yml"',
                'DEST="/var/lib/ansible-pull"',
                'LOG_DIR="/var/log/ansible-pull"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    bootstrap_vars_text = textwrap.dedent(
        f"""\
        base_ansible_pull_repo_url: "{repo_dir}"
        base_ansible_pull_branch: "main"
        base_ansible_pull_playbook: "playbooks/workstation.yml"
        base_ansible_pull_directory: "/var/lib/ansible-pull"
        base_ansible_pull_log_dir: "/var/log/ansible-pull"
        target_hostname: "ws-01"
        machine_type: "laptop"
        base_ad_enroll: true
        """
    )
    bootstrap_vars_file.write_text(bootstrap_vars_text, encoding="utf-8")

    result = run_bash(
        "\n".join(
            [
                "source scripts/switch-pull-branch.sh",
                switch_fixture_assignments(tmp_path),
                "require_root() { :; }",
                "main --branch missing-branch",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "Could not find branch 'missing-branch'" in result.stderr
    assert env_file.read_text(encoding="utf-8").splitlines()[1] == 'BRANCH="main"'
    assert bootstrap_vars_file.read_text(encoding="utf-8") == bootstrap_vars_text


def test_unreachable_commit_pin_leaves_state_untouched(tmp_path: Path) -> None:
    repo_dir = tmp_path / "repo"
    create_git_repo(repo_dir)
    missing_sha = "f" * 40
    env_file = tmp_path / "pull.env"
    bootstrap_vars_file = tmp_path / "bootstrap-vars.yml"
    env_file.write_text(
        "\n".join(
            [
                f"REPO_URL={shlex.quote(str(repo_dir))}",
                'BRANCH="main"',
                'PLAYBOOK="playbooks/workstation.yml"',
                'DEST="/var/lib/ansible-pull"',
                'LOG_DIR="/var/log/ansible-pull"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    bootstrap_vars_text = textwrap.dedent(
        f"""\
        base_ansible_pull_repo_url: "{repo_dir}"
        base_ansible_pull_branch: "main"
        base_ansible_pull_playbook: "playbooks/workstation.yml"
        base_ansible_pull_directory: "/var/lib/ansible-pull"
        base_ansible_pull_log_dir: "/var/log/ansible-pull"
        target_hostname: "ws-01"
        machine_type: "laptop"
        base_ad_enroll: true
        """
    )
    bootstrap_vars_file.write_text(bootstrap_vars_text, encoding="utf-8")

    result = run_bash(
        "\n".join(
            [
                "source scripts/switch-pull-branch.sh",
                switch_fixture_assignments(tmp_path),
                "require_root() { :; }",
                f"main --commit {missing_sha}",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "Could not fetch commit" in result.stderr
    assert env_file.read_text(encoding="utf-8").splitlines()[1] == 'BRANCH="main"'
    assert bootstrap_vars_file.read_text(encoding="utf-8") == bootstrap_vars_text


def test_commit_pin_updates_pull_env_and_bootstrap_vars(tmp_path: Path) -> None:
    repo_dir = tmp_path / "repo"
    commit_sha = create_git_repo(repo_dir)
    env_file = tmp_path / "pull.env"
    bootstrap_vars_file = tmp_path / "bootstrap-vars.yml"
    env_file.write_text(
        "\n".join(
            [
                f"REPO_URL={shlex.quote(str(repo_dir))}",
                'BRANCH="main"',
                'PLAYBOOK="playbooks/workstation.yml"',
                'DEST="/var/lib/ansible-pull"',
                'LOG_DIR="/var/log/ansible-pull"',
                'SLACK_WEBHOOK_URL="https://hooks.slack.invalid/services/T000/B000/XYZ"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    bootstrap_vars_file.write_text(
        textwrap.dedent(
            f"""\
            base_ansible_pull_repo_url: "{repo_dir}"
            base_ansible_pull_branch: "main"
            base_ansible_pull_playbook: "playbooks/workstation.yml"
            base_ansible_pull_directory: "/var/lib/ansible-pull"
            base_ansible_pull_log_dir: "/var/log/ansible-pull"
            target_hostname: "ws-01"
            machine_type: "laptop"
            base_ad_enroll: true
            """
        ),
        encoding="utf-8",
    )

    run_bash(
        "\n".join(
            [
                "source scripts/switch-pull-branch.sh",
                switch_fixture_assignments(tmp_path),
                "require_root() { :; }",
                f"main --commit {commit_sha}",
            ]
        )
    )

    assert f"BRANCH={commit_sha}" in env_file.read_text(encoding="utf-8")
    assert (
        f'base_ansible_pull_branch: "{commit_sha}"'
        in bootstrap_vars_file.read_text(encoding="utf-8")
    )
    assert (
        "SLACK_WEBHOOK_URL=https://hooks.slack.invalid/services/T000/B000/XYZ"
        in env_file.read_text(encoding="utf-8")
    )


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
