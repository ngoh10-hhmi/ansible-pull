from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Callable

import pytest
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


def yaml_scalar(value: object) -> str:
    if isinstance(value, bool):
        return str(value).lower()
    return str(value)


def append_text(path: Path, content: str) -> None:
    path.write_text(path.read_text(encoding="utf-8") + content, encoding="utf-8")


def create_repo_variant(
    workspace: Path,
    name: str,
    marker_name: str,
    marker_contents: str,
    mutate: Callable[[Path], None] | None = None,
) -> Path:
    repo_dir = workspace / name
    run("git", "clone", "--quiet", "--branch", TEST_BRANCH, str(REPO_ROOT), str(repo_dir))
    run("git", "config", "user.name", "Codex CI", cwd=repo_dir)
    run("git", "config", "user.email", "codex-ci@example.com", cwd=repo_dir)
    (repo_dir / marker_name).write_text(marker_contents, encoding="utf-8")
    if mutate is not None:
        mutate(repo_dir)
    run("git", "add", "-A", cwd=repo_dir)
    run("git", "commit", "--quiet", "-m", f"Prepare {name}", cwd=repo_dir)
    return repo_dir


def configure_pull_environment(
    repo_url: Path,
    dest: Path,
    log_dir: Path,
    extra_vars: dict[str, object] | None = None,
) -> None:
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
    bootstrap_lines = [
        f"base_ansible_pull_repo_url: \"{repo_url}\"",
        f"base_ansible_pull_branch: \"{TEST_BRANCH}\"",
        "base_ansible_pull_playbook: \"playbooks/workstation.yml\"",
        f"base_ansible_pull_directory: \"{dest}\"",
        f"base_ansible_pull_log_dir: \"{log_dir}\"",
        "base_ad_enroll: false",
    ]
    for key, value in (extra_vars or {}).items():
        bootstrap_lines.append(f"{key}: {yaml_scalar(value)}")
    Path("/etc/ansible/bootstrap-vars.yml").write_text(
        "\n".join(bootstrap_lines + [""]),
        encoding="utf-8",
    )


def current_short_hostname() -> str:
    return run("hostname", "-s").stdout.strip()


def current_fqdn() -> str:
    result = subprocess.run(
        ("hostname", "-f"),
        check=False,
        text=True,
        capture_output=True,
    )
    return result.stdout.strip()


def run_pull(
    repo_url: Path,
    dest: Path,
    log_dir: Path,
    extra_vars: dict[str, object] | None = None,
) -> None:
    configure_pull_environment(repo_url, dest, log_dir, extra_vars=extra_vars)
    run("/usr/local/sbin/run-ansible-pull")


def restore_default_pull_state(workspace: Path) -> None:
    run_pull(
        REPO_ROOT,
        workspace / "restore-checkout",
        workspace / "restore-logs",
        extra_vars={
            "base_apt_refresh_enabled": True,
            "base_apt_maintenance_enabled": False,
        },
    )


def test_ansible_pull_timer_is_installed() -> None:
    timer = host.file("/etc/systemd/system/ansible-pull.timer")
    assert timer.exists
    assert "OnCalendar=*:0/15" in timer.content_string
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


def test_apt_maintenance_timer_can_be_enabled() -> None:
    workspace = Path(tempfile.mkdtemp(prefix="ansible-pull-maint-"))
    try:
        run_pull(
            REPO_ROOT,
            workspace / "checkout",
            workspace / "logs",
            extra_vars={"base_apt_maintenance_enabled": True},
        )

        timer = host.file("/etc/systemd/system/apt-maintenance.timer")
        service = host.file("/etc/systemd/system/apt-maintenance.service")

        assert timer.exists
        assert "OnCalendar=Sat *-*-* 03:00:00" in timer.content_string
        assert service.exists
        assert service.contains("ExecStart=/usr/local/sbin/apt-maintenance")
        assert host.run("systemctl is-enabled apt-maintenance.timer").stdout.strip() == "enabled"
    finally:
        restore_default_pull_state(workspace)
        shutil.rmtree(workspace)


def test_apt_refresh_timer_can_be_disabled() -> None:
    workspace = Path(tempfile.mkdtemp(prefix="ansible-pull-refresh-"))
    try:
        run_pull(
            REPO_ROOT,
            workspace / "checkout",
            workspace / "logs",
            extra_vars={"base_apt_refresh_enabled": False},
        )

        refresh_enabled = host.run("systemctl is-enabled apt-refresh.timer")
        refresh_active = host.run("systemctl is-active apt-refresh.timer")

        assert refresh_enabled.stdout.strip() == "disabled"
        assert refresh_enabled.rc != 0
        assert refresh_active.stdout.strip() == "inactive"
        assert refresh_active.rc != 0
    finally:
        restore_default_pull_state(workspace)
        shutil.rmtree(workspace)


def test_runtime_inventory_can_match_fqdn_host_vars() -> None:
    workspace = Path(tempfile.mkdtemp(prefix="ansible-pull-fqdn-"))
    marker_path = workspace / "fqdn-hostvars-marker.txt"
    short_hostname = current_short_hostname()
    fqdn = current_fqdn()

    if not fqdn or "." not in fqdn:
        pytest.skip("hostname -f is not returning an FQDN on this test host")

    def mutate(repo_dir: Path) -> None:
        short_host_var = repo_dir / "inventory" / "host_vars" / f"{short_hostname}.yml"
        if short_host_var.exists():
            short_host_var.unlink()

        fqdn_host_var = repo_dir / "inventory" / "host_vars" / f"{fqdn}.yml"
        fqdn_host_var.write_text(
            "\n".join(
                [
                    "---",
                    f"variant_marker_path: {marker_path}",
                    "",
                ]
            ),
            encoding="utf-8",
        )

        append_text(
            repo_dir / "roles" / "base" / "tasks" / "main.yml",
            "\n".join(
                [
                    "",
                    "- name: Write variant hostvars marker",
                    "  ansible.builtin.copy:",
                    "    dest: \"{{ variant_marker_path }}\"",
                    "    content: \"{{ inventory_hostname }}\\n\"",
                    "    owner: root",
                    "    group: root",
                    "    mode: \"0644\"",
                    "  when: variant_marker_path is defined",
                    "",
                ]
            ),
        )

    try:
        repo_variant = create_repo_variant(
            workspace,
            "fqdn-variant",
            "repo-marker.txt",
            "fqdn host vars\n",
            mutate=mutate,
        )
        run_pull(repo_variant, workspace / "checkout", workspace / "logs")

        assert marker_path.exists()
        assert marker_path.read_text(encoding="utf-8").strip() == fqdn
    finally:
        restore_default_pull_state(workspace)
        shutil.rmtree(workspace)


def test_runtime_inventory_prefers_short_hostname_host_vars() -> None:
    workspace = Path(tempfile.mkdtemp(prefix="ansible-pull-short-host-"))
    marker_path = workspace / "short-hostvars-marker.txt"
    short_hostname = current_short_hostname()
    fqdn = current_fqdn()

    if not fqdn or "." not in fqdn:
        pytest.skip("hostname -f is not returning an FQDN on this test host")

    def mutate(repo_dir: Path) -> None:
        short_host_var = repo_dir / "inventory" / "host_vars" / f"{short_hostname}.yml"
        short_host_var.write_text(
            "\n".join(
                [
                    "---",
                    f"variant_marker_path: {marker_path}",
                    "variant_marker_content: short-hostname",
                    "",
                ]
            ),
            encoding="utf-8",
        )

        fqdn_host_var = repo_dir / "inventory" / "host_vars" / f"{fqdn}.yml"
        fqdn_host_var.write_text(
            "\n".join(
                [
                    "---",
                    f"variant_marker_path: {marker_path}",
                    "variant_marker_content: fqdn",
                    "",
                ]
            ),
            encoding="utf-8",
        )

        append_text(
            repo_dir / "roles" / "base" / "tasks" / "main.yml",
            "\n".join(
                [
                    "",
                    "- name: Write hostvars precedence marker",
                    "  ansible.builtin.copy:",
                    "    dest: \"{{ variant_marker_path }}\"",
                    "    content: \"{{ variant_marker_content }}\\n\"",
                    "    owner: root",
                    "    group: root",
                    "    mode: \"0644\"",
                    "  when: variant_marker_path is defined and variant_marker_content is defined",
                    "",
                ]
            ),
        )

    try:
        repo_variant = create_repo_variant(
            workspace,
            "short-host-variant",
            "repo-marker.txt",
            "short hostname host vars\n",
            mutate=mutate,
        )
        run_pull(repo_variant, workspace / "checkout", workspace / "logs")

        assert marker_path.exists()
        assert marker_path.read_text(encoding="utf-8").strip() == "short-hostname"
    finally:
        restore_default_pull_state(workspace)
        shutil.rmtree(workspace)


def test_branch_switch_updates_pull_settings_without_running_immediately() -> None:
    workspace = Path(tempfile.mkdtemp(prefix="ansible-pull-switch-no-run-"))
    try:
        repo_one = create_repo_variant(workspace, "remote-one", "repo-one-marker.txt", "remote one\n")
        repo_two = create_repo_variant(workspace, "remote-two", "repo-two-marker.txt", "remote two\n")

        dest = workspace / "checkout"
        log_dir = workspace / "logs"
        configure_pull_environment(repo_one, dest, log_dir)

        run("/usr/local/sbin/run-ansible-pull")
        assert (dest / "repo-one-marker.txt").exists()
        run_log = log_dir / f"ansible-pull-{current_short_hostname()}.log"
        original_log_text = run_log.read_text(encoding="utf-8")
        assert original_log_text.count("Starting ansible-pull run") == 1

        run(
            "/usr/local/sbin/switch-pull-branch",
            "--branch",
            TEST_BRANCH,
            "--repo",
            str(repo_two),
        )

        assert (dest / "repo-one-marker.txt").exists()
        assert not (dest / "repo-two-marker.txt").exists()

        pull_env = Path("/etc/ansible/pull.env").read_text(encoding="utf-8")
        bootstrap_vars = Path("/etc/ansible/bootstrap-vars.yml").read_text(encoding="utf-8")
        assert f"REPO_URL={repo_two}" in pull_env
        assert f"BRANCH={TEST_BRANCH}" in pull_env
        assert f"base_ansible_pull_repo_url: \"{repo_two}\"" in bootstrap_vars
        assert f"base_ansible_pull_branch: \"{TEST_BRANCH}\"" in bootstrap_vars

        rerun_log_text = run_log.read_text(encoding="utf-8")
        assert rerun_log_text.count("Starting ansible-pull run") == 1
    finally:
        restore_default_pull_state(workspace)
        shutil.rmtree(workspace)


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
        restore_default_pull_state(workspace)
        shutil.rmtree(workspace)
