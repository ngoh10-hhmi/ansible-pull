from __future__ import annotations

import os
import shlex
import stat
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


def write_fake_python(path: Path, version: str) -> None:
    path.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            if [ "$1" = "-c" ]; then
              printf '%s\\n' {shlex.quote(version)}
              exit 0
            fi
            exit 0
            """
        ),
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def test_pick_python_prefers_python312(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    write_fake_python(bin_dir / "python3.12", "3.12")
    write_fake_python(bin_dir / "python3", "3.14")

    result = run_bash(
        "\n".join(
            [
                "source scripts/setup-dev.sh",
                f"PATH={shlex.quote(str(bin_dir))}",
                "pick_python",
                'printf "%s\\n" "${PYTHON_BIN}"',
            ]
        )
    )

    assert result.stdout.strip() == str(bin_dir / "python3.12")


def test_pick_python_accepts_python3_when_new_enough(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    write_fake_python(bin_dir / "python3", "3.14")

    result = run_bash(
        "\n".join(
            [
                "source scripts/setup-dev.sh",
                f"PATH={shlex.quote(str(bin_dir))}",
                "pick_python",
                'printf "%s\\n" "${PYTHON_BIN}"',
            ]
        )
    )

    assert result.stdout.strip() == str(bin_dir / "python3")


def test_pick_python_rejects_python311(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    write_fake_python(bin_dir / "python3.11", "3.11")
    write_fake_python(bin_dir / "python3", "3.11")

    result = run_bash(
        "\n".join(
            [
                "source scripts/setup-dev.sh",
                f"PATH={shlex.quote(str(bin_dir))}",
                "pick_python",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "Python 3.12 or newer is required." in result.stderr
