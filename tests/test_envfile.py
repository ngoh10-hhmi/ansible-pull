from __future__ import annotations

import os
import shlex
import subprocess
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
VENV_BIN = REPO_ROOT / ".venv" / "bin"


def run_bash(script: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    # bash -l sources /etc/profile.d, which on this machine prepends linuxbrew
    # and other paths in front of whatever PATH we pass through env=. Force
    # the venv's python3 to win by prepending inside the script itself, after
    # the login profile has finished. The validator shells out to python3 and
    # needs PyYAML; production hosts get it from the apt-installed `ansible`
    # package, but in tests it lives in .venv.
    prelude = f'export PATH="{VENV_BIN}{os.pathsep}$PATH"\n'
    return subprocess.run(
        ["bash", "-lc", prelude + script],
        cwd=REPO_ROOT,
        check=check,
        text=True,
        capture_output=True,
        env=os.environ.copy(),
    )


def call_validator(vars_file: Path) -> subprocess.CompletedProcess[str]:
    return run_bash(
        "\n".join(
            [
                "source scripts/lib/envfile.sh",
                f"validate_bootstrap_vars_file {shlex.quote(str(vars_file))}",
            ]
        ),
        check=False,
    )


VALID_VARS = textwrap.dedent(
    """\
    base_ansible_pull_repo_url: "https://github.com/example/ansible-pull.git"
    base_ansible_pull_branch: "testing"
    base_ansible_pull_playbook: "playbooks/workstation.yml"
    base_ansible_pull_directory: "/var/lib/ansible-pull"
    base_ansible_pull_log_dir: "/var/log/ansible-pull"
    target_hostname: "ws-test"
    machine_type: "laptop"
    base_ad_enroll: true
    """
)


def test_validate_bootstrap_vars_accepts_well_formed_file(tmp_path: Path) -> None:
    vars_file = tmp_path / "bootstrap-vars.yml"
    vars_file.write_text(VALID_VARS, encoding="utf-8")

    result = call_validator(vars_file)

    assert result.returncode == 0, result.stderr


def test_validate_bootstrap_vars_accepts_commit_pin_as_branch(tmp_path: Path) -> None:
    vars_file = tmp_path / "bootstrap-vars.yml"
    vars_file.write_text(
        VALID_VARS.replace(
            'base_ansible_pull_branch: "testing"',
            'base_ansible_pull_branch: "0123456789abcdef0123456789abcdef01234567"',
        ),
        encoding="utf-8",
    )

    result = call_validator(vars_file)

    assert result.returncode == 0, result.stderr


def test_validate_bootstrap_vars_rejects_missing_required_key(tmp_path: Path) -> None:
    vars_file = tmp_path / "bootstrap-vars.yml"
    vars_file.write_text(
        VALID_VARS.replace('target_hostname: "ws-test"\n', ""),
        encoding="utf-8",
    )

    result = call_validator(vars_file)

    assert result.returncode != 0
    assert "missing or empty required key: target_hostname" in result.stderr


def test_validate_bootstrap_vars_rejects_invalid_machine_type(tmp_path: Path) -> None:
    vars_file = tmp_path / "bootstrap-vars.yml"
    vars_file.write_text(
        VALID_VARS.replace('machine_type: "laptop"', 'machine_type: "tablet"'),
        encoding="utf-8",
    )

    result = call_validator(vars_file)

    assert result.returncode != 0
    assert "machine_type must be 'laptop' or 'desktop'" in result.stderr


def test_validate_bootstrap_vars_rejects_malformed_yaml(tmp_path: Path) -> None:
    vars_file = tmp_path / "bootstrap-vars.yml"
    vars_file.write_text("base_ansible_pull_branch: 'testing\n", encoding="utf-8")

    result = call_validator(vars_file)

    assert result.returncode != 0
    assert "is not valid YAML" in result.stderr


def test_validate_bootstrap_vars_rejects_missing_file(tmp_path: Path) -> None:
    missing = tmp_path / "no-such-file.yml"

    result = call_validator(missing)

    assert result.returncode != 0
    assert f"Missing {missing}" in result.stderr


def test_validate_bootstrap_vars_rejects_garbage_branch_name(tmp_path: Path) -> None:
    vars_file = tmp_path / "bootstrap-vars.yml"
    vars_file.write_text(
        VALID_VARS.replace(
            'base_ansible_pull_branch: "testing"',
            'base_ansible_pull_branch: "bad branch with spaces"',
        ),
        encoding="utf-8",
    )

    result = call_validator(vars_file)

    assert result.returncode != 0
    assert "not a recognizable branch name" in result.stderr
