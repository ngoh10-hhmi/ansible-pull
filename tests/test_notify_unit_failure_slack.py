from __future__ import annotations

import json
import os
import subprocess
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = "scripts/notify-unit-failure-slack.sh"


def run_bash(script: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-lc", script],
        cwd=REPO_ROOT,
        check=check,
        text=True,
        capture_output=True,
        env=os.environ.copy(),
    )


def test_main_exits_2_without_unit_argument() -> None:
    result = run_bash(f"bash {SCRIPT}", check=False)
    assert result.returncode == 2
    assert "Usage:" in result.stderr


def test_main_is_noop_when_no_webhook_configured(tmp_path: Path) -> None:
    # Point env discovery at non-existent files so no webhook is found.
    result = run_bash(
        textwrap.dedent(
            f"""\
            export ANSIBLE_PULL_ENV_FILE={tmp_path}/absent.env
            export ANSIBLE_PULL_ENVFILE_LIB={tmp_path}/absent-lib.sh
            bash {SCRIPT} managed-package-updates.service
            """
        )
    )
    assert result.returncode == 0
    assert "skipping Slack alert" in result.stdout


def test_send_alert_posts_payload_with_unit_and_context() -> None:
    # Stub curl, systemctl, journalctl, and hostname; capture the JSON payload
    # curl would POST so we can assert on its structure.
    result = run_bash(
        textwrap.dedent(
            f"""\
            source {SCRIPT}
            SLACK_WEBHOOK_URL="https://hooks.example/T/B/XYZ"
            hostname() {{ echo "ws-test"; }}
            systemctl() {{ echo "● managed-package-updates.service failed"; }}
            journalctl() {{ echo "sssd is not active after restart"; }}
            curl() {{
              # The payload is the argument following --data.
              while [[ $# -gt 0 ]]; do
                if [[ "$1" == "--data" ]]; then echo "$2" > payload.json; fi
                shift
              done
              return 0
            }}
            send_alert "managed-package-updates.service"
            cat payload.json
            rm -f payload.json
            """
        )
    )

    assert "Sent Slack failure alert for managed-package-updates.service" in result.stdout
    payload_line = result.stdout.splitlines()[-1]
    payload = json.loads(payload_line)
    attachment = payload["attachments"][0]
    assert attachment["color"] == "#ff0000"
    assert "ws-test" in attachment["title"]
    assert "managed-package-updates.service" in attachment["text"]
    assert "sssd is not active after restart" in attachment["text"]


def test_send_alert_warns_when_curl_fails() -> None:
    result = run_bash(
        textwrap.dedent(
            f"""\
            source {SCRIPT}
            SLACK_WEBHOOK_URL="https://hooks.example/T/B/XYZ"
            hostname() {{ echo "ws-test"; }}
            systemctl() {{ echo "status"; }}
            journalctl() {{ echo "logs"; }}
            curl() {{ return 1; }}
            send_alert "apt-refresh.service"
            """
        ),
        check=False,
    )

    assert "failed to send Slack alert for apt-refresh.service" in result.stderr


def test_load_webhook_prefers_already_exported_value(tmp_path: Path) -> None:
    result = run_bash(
        textwrap.dedent(
            f"""\
            source {SCRIPT}
            export ANSIBLE_PULL_ENVFILE_LIB={tmp_path}/absent-lib.sh
            SLACK_WEBHOOK_URL="https://preset.example/hook"
            load_webhook
            echo "WEBHOOK=${{SLACK_WEBHOOK_URL}}"
            """
        )
    )
    assert "WEBHOOK=https://preset.example/hook" in result.stdout


def test_load_webhook_reads_pull_env_via_envfile_lib(tmp_path: Path) -> None:
    env_file = tmp_path / "pull.env"
    env_file.write_text(
        'SLACK_WEBHOOK_URL=https://fromfile.example/hook\n', encoding="utf-8"
    )
    lib = REPO_ROOT / "scripts" / "lib" / "envfile.sh"

    result = run_bash(
        textwrap.dedent(
            f"""\
            source {SCRIPT}
            export ANSIBLE_PULL_ENV_FILE={env_file}
            export ANSIBLE_PULL_ENVFILE_LIB={lib}
            load_webhook
            echo "WEBHOOK=${{SLACK_WEBHOOK_URL}}"
            """
        )
    )
    assert "WEBHOOK=https://fromfile.example/hook" in result.stdout


def test_truncate_context_caps_long_text() -> None:
    result = run_bash(
        textwrap.dedent(
            f"""\
            source {SCRIPT}
            CONTEXT_MAX_CHARS=10
            truncate_context "0123456789ABCDEFGH"
            """
        )
    )
    # First 10 chars, then a truncation marker on its own line.
    assert result.stdout.splitlines()[0] == "0123456789"
    assert result.stdout.splitlines()[1] == "..."
