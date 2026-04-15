from __future__ import annotations

import os
import shlex
import subprocess
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def run_bash(script: str) -> str:
    # bash -lc runs as a login shell so that ~/.bashrc / /etc/profile.d are
    # sourced, which is necessary when bash is invoked from a non-interactive
    # context (e.g. pytest) and PATH or shell functions would otherwise differ
    # from what a normal terminal session sees.
    result = subprocess.run(
        ["bash", "-lc", script],
        cwd=REPO_ROOT,
        check=True,
        text=True,
        capture_output=True,
        env=os.environ.copy(),
    )
    return result.stdout


def test_failure_notification_includes_phase_task_excerpt_and_log_path(tmp_path: Path) -> None:
    run_log = tmp_path / "ansible-pull-test.log"
    run_log.write_text(
        textwrap.dedent(
            """\
            [2026-04-15 11:00:00] Starting ansible-pull run for host 'host1' on branch 'testing'.
            TASK [base : Install baseline packages] ***************************************
            fatal: [host1]: FAILED! => changed=false
              msg: No package matching 'example-package' is available
            PLAY RECAP *********************************************************************
            """
        ),
        encoding="utf-8",
    )

    output = run_bash(
        "\n".join(
            [
                "source scripts/run-ansible-pull.sh",
                f"RUN_LOG={shlex.quote(str(run_log))}",
                "HOSTNAME_SHORT=host1",
                "BRANCH=testing",
                "CURRENT_PHASE=run_playbook",
                "RUN_STARTED_AT=$(( $(date +%s) - 42 ))",
                "build_failure_notification_text 2",
            ]
        )
    )

    assert "*Phase:* `run_playbook`" in output
    assert "*Task:* `base : Install baseline packages`" in output
    assert "No package matching 'example-package' is available" in output
    assert f"*Log:* `{run_log}`" in output


def test_failure_notification_falls_back_to_non_ansible_fatal_excerpt(tmp_path: Path) -> None:
    run_log = tmp_path / "ansible-pull-test.log"
    run_log.write_text(
        textwrap.dedent(
            """\
            [2026-04-15 11:00:00] Starting ansible-pull run for host 'host1' on branch 'testing'.
            fatal: couldn't find remote ref missing-branch
            """
        ),
        encoding="utf-8",
    )

    output = run_bash(
        "\n".join(
            [
                "source scripts/run-ansible-pull.sh",
                f"RUN_LOG={shlex.quote(str(run_log))}",
                "HOSTNAME_SHORT=host1",
                "BRANCH=testing",
                "CURRENT_PHASE=sync_repository_checkout",
                "RUN_STARTED_AT=$(( $(date +%s) - 3 ))",
                "build_failure_notification_text 128",
            ]
        )
    )

    assert "*Phase:* `sync_repository_checkout`" in output
    assert "fatal: couldn't find remote ref missing-branch" in output
    assert "*Task:*" not in output
