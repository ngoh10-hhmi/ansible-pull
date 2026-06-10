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


def test_git_verify_head_matches_ref_accepts_matching_commit(tmp_path: Path) -> None:
    repo_dir = tmp_path / "repo"
    commit_sha = create_git_repo(repo_dir)

    result = run_bash(
        "\n".join(
            [
                "source scripts/lib/git_sync.sh",
                f"git_verify_head_matches_ref {shlex.quote(str(repo_dir))} {commit_sha} true",
            ]
        ),
        check=False,
    )

    assert result.returncode == 0, result.stderr


def test_git_verify_head_matches_ref_rejects_wrong_commit(tmp_path: Path) -> None:
    repo_dir = tmp_path / "repo"
    create_git_repo(repo_dir)
    wrong_sha = "0123456789abcdef0123456789abcdef01234567"

    result = run_bash(
        "\n".join(
            [
                "source scripts/lib/git_sync.sh",
                f"git_verify_head_matches_ref {shlex.quote(str(repo_dir))} {wrong_sha} true",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "does not match expected" in result.stderr or "does not match expected" in result.stdout


def test_git_verify_head_matches_ref_rejects_missing_branch(tmp_path: Path) -> None:
    repo_dir = tmp_path / "repo"
    create_git_repo(repo_dir)

    result = run_bash(
        "\n".join(
            [
                "source scripts/lib/git_sync.sh",
                f"git_verify_head_matches_ref {shlex.quote(str(repo_dir))} unknown-branch false",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "could not resolve expected ref" in result.stderr or "could not resolve expected ref" in result.stdout


def test_sync_checkout_or_clone_fresh_branch_clone_lands_on_expected_head(tmp_path: Path) -> None:
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
                    "main "
                    "1"
                ),
            ]
        )
    )

    head_sha = run("git", "-C", str(checkout_dir), "rev-parse", "HEAD").stdout.strip()
    assert head_sha == commit_sha


def create_git_repo_with_two_commits(path: Path) -> tuple[str, str]:
    path.mkdir()
    run("git", "init", "--quiet", "-b", "main", cwd=path)
    run("git", "config", "user.name", "Git Sync Test", cwd=path)
    run("git", "config", "user.email", "git-sync-test@example.com", cwd=path)
    (path / "README.md").write_text("rev one\n", encoding="utf-8")
    run("git", "add", "README.md", cwd=path)
    run("git", "commit", "--quiet", "-m", "First commit", cwd=path)
    older = run("git", "rev-parse", "HEAD", cwd=path).stdout.strip()
    (path / "README.md").write_text("rev two\n", encoding="utf-8")
    run("git", "add", "README.md", cwd=path)
    run("git", "commit", "--quiet", "-m", "Second commit", cwd=path)
    newer = run("git", "rev-parse", "HEAD", cwd=path).stdout.strip()
    return older, newer


def test_sync_existing_worktree_fails_and_keeps_checkout_on_fetch_failure(
    tmp_path: Path,
) -> None:
    # A fetch failure (expired PAT, network blip) must NOT report success
    # against the stale origin ref, and must NOT wipe a perfectly good
    # checkout -- wiping would leave the host with no code to run and a fresh
    # clone would fail the same way. Point origin at a non-existent repo so the
    # fetch fails after the worktree is already valid.
    repo_dir = tmp_path / "repo"
    checkout_dir = tmp_path / "checkout"
    create_git_repo(repo_dir)
    run("git", "clone", "--quiet", str(repo_dir), str(checkout_dir))
    bogus_repo = tmp_path / "does-not-exist"

    result = run_bash(
        "\n".join(
            [
                "source scripts/lib/git_sync.sh",
                (
                    "sync_checkout_or_clone "
                    f"{shlex.quote(str(checkout_dir))} "
                    f"{shlex.quote(str(bogus_repo))} "
                    "main"
                ),
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "Successfully synced" not in result.stdout
    assert "leaving the current checkout untouched" in result.stdout
    # The existing checkout survived the transient failure.
    assert (checkout_dir / ".git").exists()


def test_sync_checkout_or_clone_supports_pinning_to_older_commit(tmp_path: Path) -> None:
    # Pinning to a commit older than the branch tip exercises the part of
    # the rollback path that the "same-commit-as-tip" test does not: the
    # initial --depth 1 fetch may not surface the older commit, so the
    # fallback in git_fetch_commit_ref has to broaden the fetch until the
    # SHA is reachable. Without that fallback this test would clone HEAD,
    # fail to resolve the older SHA on reset --hard, and exit non-zero.
    repo_dir = tmp_path / "repo"
    checkout_dir = tmp_path / "checkout"
    older_sha, newer_sha = create_git_repo_with_two_commits(repo_dir)

    run_bash(
        "\n".join(
            [
                "source scripts/lib/git_sync.sh",
                (
                    "sync_checkout_or_clone "
                    f"{shlex.quote(str(checkout_dir))} "
                    f"{shlex.quote(str(repo_dir))} "
                    f"{older_sha} "
                    "1"
                ),
            ]
        )
    )

    head_sha = run("git", "-C", str(checkout_dir), "rev-parse", "HEAD").stdout.strip()
    assert head_sha == older_sha
    assert head_sha != newer_sha
