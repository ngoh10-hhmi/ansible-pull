from __future__ import annotations

import os
import shlex
import subprocess
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


def run(
    *args: str,
    cwd: Path | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        check=check,
        text=True,
        capture_output=True,
    )


def create_git_repo(path: Path) -> str:
    path.mkdir()
    run("git", "init", "--quiet", "-b", "main", cwd=path)
    run("git", "config", "user.name", "Git Sync Test", cwd=path)
    run("git", "config", "user.email", "git-sync-test@example.com", cwd=path)
    (path / "README.md").write_text("test repo\n", encoding="utf-8")
    run("git", "add", "README.md", cwd=path)
    run("git", "commit", "--quiet", "-m", "Initial commit", cwd=path)
    return run("git", "rev-parse", "HEAD", cwd=path).stdout.strip()


def test_sync_checkout_or_clone_supports_fresh_commit_pin(tmp_path: Path) -> None:
    repo_dir = tmp_path / "repo"
    checkout_dir = tmp_path / "checkout"
    commit_sha = create_git_repo(repo_dir)

    run_bash(
        "\n".join(
            [
                "source scripts/lib/git_sync.sh",
                (
                    "sync_checkout_or_clone "
                    f"{shlex.quote(str(checkout_dir))} "
                    f"{shlex.quote(str(repo_dir))} "
                    f"{commit_sha} "
                    "1"
                ),
            ]
        )
    )

    head_sha = run("git", "-C", str(checkout_dir), "rev-parse", "HEAD").stdout.strip()
    symbolic_ref = run(
        "git",
        "-C",
        str(checkout_dir),
        "symbolic-ref",
        "--quiet",
        "HEAD",
        check=False,
    )

    assert head_sha == commit_sha
    assert symbolic_ref.returncode != 0
