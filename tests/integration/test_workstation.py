from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import testinfra

host = testinfra.get_host("local://")
REPO_ROOT = Path(__file__).resolve().parents[2]
TEST_BRANCH = os.environ.get("TEST_GIT_BRANCH", "main")


def run(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        check=True,
        text=True,
        capture_output=True,
    )


def create_repo_variant(workspace: Path, name: str, marker_name: str, marker_contents: str) -> Path:
    repo_dir = workspace / name
    run("git", "clone", "--quiet", "--branch", TEST_BRANCH, str(REPO_ROOT), str(repo_dir))
    run("git", "config", "user.name", "Codex CI", cwd=repo_dir)
    run("git", "config", "user.email", "codex-ci@example.com", cwd=repo_dir)
    (repo_dir / marker_name).write_text(marker_contents, encoding="utf-8")
    run("git", "add", "-A", cwd=repo_dir)
    run("git", "commit", "--quiet", "-m", f"Prepare {name}", cwd=repo_dir)
    return repo_dir


def configure_pull_environment(repo_url: Path, dest: Path, log_dir: Path) -> None:
    Path("/etc/ansible/pull.env").write_text(
        "\n".join(
            [
                f"REPO_URL={repo_url}",
                f"BRANCH={TEST_BRANCH}",
                "PLAYBOOK=playbooks/workstation.yml",
                f"DEST={dest}",
                f"LOG_DIR={log_dir}",
                "",
            ]
        ),
        encoding="utf-8",
    )
    Path("/etc/ansible/bootstrap-vars.yml").write_text(
        "\n".join(
            [
                f"base_ansible_pull_repo_url: {repo_url}",
                f"base_ansible_pull_branch: {TEST_BRANCH}",
                "base_ansible_pull_playbook: playbooks/workstation.yml",
                f"base_ansible_pull_directory: {dest}",
                f"base_ansible_pull_log_dir: {log_dir}",
                "base_ad_enroll: false",
                "",
            ]
        ),
        encoding="utf-8",
    )


def current_short_hostname() -> str:
    return run("hostname", "-s").stdout.strip()


def test_ansible_pull_timer_is_installed() -> None:
    timer = host.file("/etc/systemd/system/ansible-pull.timer")
    assert timer.exists
    assert timer.contains("OnCalendar=*:0/15")
    assert timer.contains("RandomizedDelaySec=2m")
    assert host.run("systemctl is-enabled ansible-pull.timer").stdout.strip() == "enabled"


def test_ansible_pull_service_logs_to_journal_with_identifier() -> None:
    service = host.file("/etc/systemd/system/ansible-pull.service")
    assert service.exists
    assert service.contains("SyslogIdentifier=ansible-pull")


def test_apt_refresh_timer_is_installed() -> None:
    timer = host.file("/etc/systemd/system/apt-refresh.timer")
    service = host.file("/etc/systemd/system/apt-refresh.service")

    assert timer.exists
    assert timer.contains("OnCalendar=hourly")
    assert timer.contains("RandomizedDelaySec=0")
    assert service.exists
    assert service.contains("ExecStart=/usr/local/sbin/apt-refresh")
    assert host.run("systemctl is-enabled apt-refresh.timer").stdout.strip() == "enabled"


def test_unattended_upgrades_policy_is_installed() -> None:
    auto_upgrades = host.file("/etc/apt/apt.conf.d/20auto-upgrades")
    unattended = host.file("/etc/apt/apt.conf.d/52ansible-unattended-upgrades")

    assert auto_upgrades.exists
    assert auto_upgrades.contains('APT::Periodic::Update-Package-Lists "0";')
    assert auto_upgrades.contains('APT::Periodic::Unattended-Upgrade "30";')
    assert unattended.exists
    assert unattended.contains("archive=\\${distro_codename}-security")
    assert unattended.contains('Unattended-Upgrade::Automatic-Reboot "false";')


def test_branch_switch_updates_origin_and_cleans_checkout() -> None:
    workspace = Path(tempfile.mkdtemp(prefix="ansible-pull-verify-"))
    try:
        repo_one = create_repo_variant(workspace, "remote-one", "repo-one-marker.txt", "remote one\n")
        repo_two = create_repo_variant(workspace, "remote-two", "repo-two-marker.txt", "remote two\n")

        dest = workspace / "checkout"
        log_dir = workspace / "logs"
        configure_pull_environment(repo_one, dest, log_dir)

        run("/usr/local/sbin/run-ansible-pull")
        assert (dest / "repo-one-marker.txt").exists()
        run_log = log_dir / f"ansible-pull-{current_short_hostname()}.log"
        assert run_log.exists()
        run_log_text = run_log.read_text(encoding="utf-8")
        assert "Starting ansible-pull run" in run_log_text
        assert "Completed ansible-pull run successfully." in run_log_text

        stray_file = dest / "untracked-file.txt"
        stray_file.write_text("remove me\n", encoding="utf-8")

        run(
            "/usr/local/sbin/switch-pull-branch",
            "--branch",
            TEST_BRANCH,
            "--repo",
            str(repo_two),
            "--run-now",
        )

        assert (dest / "repo-two-marker.txt").exists()
        assert not (dest / "repo-one-marker.txt").exists()
        assert not stray_file.exists()
        assert f"url = {repo_two}" in (dest / ".git" / "config").read_text(encoding="utf-8")
        rerun_log_text = run_log.read_text(encoding="utf-8")
        assert rerun_log_text.count("Starting ansible-pull run") >= 2
    finally:
        shutil.rmtree(workspace)
