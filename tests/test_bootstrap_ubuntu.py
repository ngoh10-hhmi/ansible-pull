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


def bootstrap_fixture_assignments(tmp_path: Path) -> str:
    return "\n".join(
        [
            f'BOOTSTRAP_VARS_FILE={shlex.quote(str(tmp_path / "bootstrap-vars.yml"))}',
            'REPO_URL="https://github.com/example/ansible-pull.git"',
            'BRANCH="testing"',
            'PLAYBOOK="playbooks/workstation.yml"',
            f'DEST={shlex.quote(str(tmp_path / "checkout"))}',
            f'LOG_DIR={shlex.quote(str(tmp_path / "logs dir"))}',
            'SHORT_HOSTNAME="hhmi-test"',
            'MACHINE_TYPE="laptop"',
        ]
    )


def test_configure_git_credentials_rejects_both_token_sources(tmp_path: Path) -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                'GITHUB_USER="machine-reader"',
                'GITHUB_TOKEN="abc123"',
                f'GITHUB_TOKEN_FILE={shlex.quote(str(tmp_path / "token.txt"))}',
                "configure_git_credentials",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "Use either --github-token or --github-token-file, not both." in result.stderr


def test_configure_git_credentials_rejects_missing_token_file(tmp_path: Path) -> None:
    missing_file = tmp_path / "missing-token.txt"
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                f'GITHUB_TOKEN_FILE={shlex.quote(str(missing_file))}',
                "configure_git_credentials",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert f"Token file does not exist: {missing_file}" in result.stderr


def test_normalize_pull_ref_args_rejects_branch_and_commit_together() -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                'BRANCH_PROVIDED="true"',
                f"COMMIT={VALID_SHA}",
                "normalize_pull_ref_args",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "Use either --branch or --commit, not both." in result.stderr


def test_normalize_pull_ref_args_rejects_short_commit_pin() -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                'COMMIT="abc123"',
                "normalize_pull_ref_args",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "Commit pin must be a full 40-character SHA." in result.stderr


def test_commit_pin_is_persisted_as_pull_branch(tmp_path: Path) -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                bootstrap_fixture_assignments(tmp_path),
                f"COMMIT={VALID_SHA}",
                "normalize_pull_ref_args",
                "write_bootstrap_vars_initial_state",
                'cat "${BOOTSTRAP_VARS_FILE}"',
            ]
        )
    )

    assert f'base_ansible_pull_branch: "{VALID_SHA}"' in result.stdout


def test_sync_repository_checkout_supports_fresh_commit_pin(tmp_path: Path) -> None:
    repo_dir = tmp_path / "repo"
    checkout_dir = tmp_path / "checkout"
    result = run_bash(
        textwrap.dedent(
            f"""\
            repo_dir={shlex.quote(str(repo_dir))}
            checkout_dir={shlex.quote(str(checkout_dir))}
            mkdir -p "$repo_dir"
            git init --quiet -b main "$repo_dir"
            git -C "$repo_dir" config user.name "Bootstrap Test"
            git -C "$repo_dir" config user.email "bootstrap-test@example.com"
            printf 'test repo\\n' > "$repo_dir/README.md"
            git -C "$repo_dir" add README.md
            git -C "$repo_dir" commit --quiet -m "Initial commit"
            commit_sha="$(git -C "$repo_dir" rev-parse HEAD)"

            source scripts/bootstrap-ubuntu.sh
            REPO_URL="$repo_dir"
            DEST="$checkout_dir"
            COMMIT="$commit_sha"
            normalize_pull_ref_args
            sync_repository_checkout
            if git -C "$DEST" symbolic-ref --quiet HEAD; then
              exit 1
            fi
            git -C "$DEST" rev-parse HEAD
            """
        )
    )
    head_sha = result.stdout.strip().splitlines()[-1]
    expected_sha = subprocess.run(
        ["git", "-C", str(repo_dir), "rev-parse", "HEAD"],
        check=True,
        text=True,
        capture_output=True,
    ).stdout.strip()

    assert head_sha == expected_sha


def test_write_bootstrap_vars_initial_state_omits_bootstrap_only_keys(tmp_path: Path) -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                bootstrap_fixture_assignments(tmp_path),
                'SUDO_USERS=("alice" "bob")',
                "write_bootstrap_vars_initial_state",
                'cat "${BOOTSTRAP_VARS_FILE}"',
            ]
        )
    )

    assert 'base_ad_enroll: false' in result.stdout
    assert 'base_manage_bootstrap_sudo_users' not in result.stdout
    assert 'base_bootstrap_sudo_users' not in result.stdout
    assert 'ad_join_user' not in result.stdout


def test_write_bootstrap_vars_ad_phase_state_includes_bootstrap_only_keys(tmp_path: Path) -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                bootstrap_fixture_assignments(tmp_path),
                'SUDO_USERS=("alice" "bob")',
                "write_bootstrap_vars_ad_phase_state",
                'cat "${BOOTSTRAP_VARS_FILE}"',
            ]
        )
    )

    assert 'base_ad_enroll: true' in result.stdout
    assert 'base_manage_bootstrap_sudo_users: true' in result.stdout
    assert 'base_bootstrap_sudo_users:' in result.stdout
    assert '  - alice' in result.stdout
    assert '  - bob' in result.stdout
    assert 'ad_join_user' not in result.stdout


def test_cleanup_bootstrap_state_rewrites_initial_state_after_failed_ad_phase(tmp_path: Path) -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                bootstrap_fixture_assignments(tmp_path),
                'SUDO_USERS=("alice")',
                'BOOTSTRAP_PHASE="ad_phase"',
                'AD_CONVERGE_SUCCEEDED="false"',
                "write_bootstrap_vars_ad_phase_state",
                "cleanup_bootstrap_state_on_exit",
                'cat "${BOOTSTRAP_VARS_FILE}"',
            ]
        )
    )

    assert 'base_ad_enroll: false' in result.stdout
    assert 'base_manage_bootstrap_sudo_users' not in result.stdout
    assert 'base_bootstrap_sudo_users' not in result.stdout


def test_cleanup_bootstrap_state_rewrites_final_state_after_successful_ad_phase(tmp_path: Path) -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                bootstrap_fixture_assignments(tmp_path),
                'SUDO_USERS=("alice")',
                'BOOTSTRAP_PHASE="post_ad_converge"',
                'AD_CONVERGE_SUCCEEDED="true"',
                "write_bootstrap_vars_ad_phase_state",
                "cleanup_bootstrap_state_on_exit",
                'cat "${BOOTSTRAP_VARS_FILE}"',
            ]
        )
    )

    assert 'base_ad_enroll: true' in result.stdout
    assert 'base_manage_bootstrap_sudo_users' not in result.stdout
    assert 'base_bootstrap_sudo_users' not in result.stdout


def test_enable_pull_timer_failure_is_fatal() -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                "systemctl() { return 1; }",
                "enable_pull_timer",
            ]
        ),
        check=False,
    )

    assert result.returncode != 0
    assert "Failed to enable ansible-pull.timer." in result.stderr


def test_is_valid_short_hostname_accepts_expected_values() -> None:
    run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            valid_names=("hhmi-test" "ws01" "A" "node-9")
            for name in "${valid_names[@]}"; do
              is_valid_short_hostname "$name"
            done
            """
        )
    )


def test_is_valid_short_hostname_rejects_invalid_values() -> None:
    run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            invalid_names=("" "bad name" "-bad" "bad-" "bad_name" "bad.name" "hostname-that-is-too-long")
            for name in "${invalid_names[@]}"; do
              if is_valid_short_hostname "$name"; then
                printf 'unexpectedly accepted: %s\n' "$name" >&2
                exit 1
              fi
            done
            """
        )
    )


def test_cleanup_bootstrap_state_removes_git_credentials_on_partial_failure(tmp_path: Path) -> None:
    creds_file = tmp_path / "git-credentials"
    creds_file.write_text("https://example/secret\n", encoding="utf-8")
    config_file = tmp_path / "gitconfig"

    run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                bootstrap_fixture_assignments(tmp_path),
                f'GIT_CREDENTIALS_FILE={shlex.quote(str(creds_file))}',
                'GIT_CREDENTIALS_WRITTEN="true"',
                'BOOTSTRAP_PHASE="initial"',
                'AD_CONVERGE_SUCCEEDED="false"',
                'FINAL_STATE_WRITTEN="false"',
                # Pin the global git config the trap touches into the tmp_path
                # so this test does not mutate the developer's real ~/.gitconfig.
                f'export GIT_CONFIG_GLOBAL={shlex.quote(str(config_file))}',
                f'git config --file {shlex.quote(str(config_file))} credential.helper "store --file {creds_file}"',
                "cleanup_bootstrap_state_on_exit",
            ]
        )
    )

    assert not creds_file.exists()
    helper_check = subprocess.run(
        ["git", "config", "--file", str(config_file), "--get", "credential.helper"],
        check=False,
        text=True,
        capture_output=True,
    )
    assert helper_check.returncode != 0


def test_cleanup_bootstrap_state_keeps_git_credentials_after_final_state(tmp_path: Path) -> None:
    creds_file = tmp_path / "git-credentials"
    creds_file.write_text("https://example/secret\n", encoding="utf-8")

    run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                bootstrap_fixture_assignments(tmp_path),
                f'GIT_CREDENTIALS_FILE={shlex.quote(str(creds_file))}',
                'GIT_CREDENTIALS_WRITTEN="true"',
                'FINAL_STATE_WRITTEN="true"',
                "cleanup_bootstrap_state_on_exit",
            ]
        )
    )

    assert creds_file.exists()


def test_audit_log_invocation_is_no_op_when_logger_missing(tmp_path: Path) -> None:
    # Stub `command -v` so the function thinks logger is unavailable; the
    # script should continue without raising.
    run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                "command() { return 1; }",
                'audit_log_invocation "ansible-pull-bootstrap" "--repo" "https://example.invalid"',
            ]
        )
    )


def test_pull_env_round_trip_preserves_shell_metacharacters(tmp_path: Path) -> None:
    env_file = tmp_path / "pull.env"
    result = run_bash(
        textwrap.dedent(
            f"""\
            source scripts/lib/envfile.sh
            REPO_URL='https://example.invalid/repo?x=1&y=$HOME'
            BRANCH='testing/feature'
            PLAYBOOK='playbooks/workstation.yml'
            DEST={shlex.quote(str(tmp_path / "checkout dir"))}
            LOG_DIR={shlex.quote(str(tmp_path / "logs dir"))}
            SLACK_WEBHOOK_URL='https://hooks.slack.invalid/services/T000/B000/XYZ?foo=1&bar=$HOME'
            SLACK_NOTIFY_SUCCESS='true'
            write_pull_env_file {shlex.quote(str(env_file))}
            unset REPO_URL BRANCH PLAYBOOK DEST LOG_DIR SLACK_WEBHOOK_URL SLACK_NOTIFY_SUCCESS
            load_env_file {shlex.quote(str(env_file))}
            validate_pull_env
            printf 'REPO_URL=%s\\n' "$REPO_URL"
            printf 'DEST=%s\\n' "$DEST"
            printf 'LOG_DIR=%s\\n' "$LOG_DIR"
            printf 'SLACK_WEBHOOK_URL=%s\\n' "$SLACK_WEBHOOK_URL"
            printf 'SLACK_NOTIFY_SUCCESS=%s\\n' "$SLACK_NOTIFY_SUCCESS"
            """
        )
    )

    assert "REPO_URL=https://example.invalid/repo?x=1&y=$HOME" in result.stdout
    assert f"DEST={tmp_path / 'checkout dir'}" in result.stdout
    assert f"LOG_DIR={tmp_path / 'logs dir'}" in result.stdout
    assert "SLACK_WEBHOOK_URL=https://hooks.slack.invalid/services/T000/B000/XYZ?foo=1&bar=$HOME" in result.stdout
    assert "SLACK_NOTIFY_SUCCESS=true" in result.stdout


def _join_ad_harness(username: str) -> str:
    return textwrap.dedent(
        f"""\
        source scripts/bootstrap-ubuntu.sh

        _username_reads=0
        read() {{
          local var_name="${{@: -1}}"
          if [[ "$*" == *"Username"* ]]; then
            # Supply the username once, then simulate EOF (closed stdin) so a
            # rejected realm reprompts exactly once and then terminates instead
            # of looping forever. Valid-realm cases break on the first pass and
            # never reach the second read.
            _username_reads=$((_username_reads + 1))
            if (( _username_reads > 1 )); then
              return 1
            fi
            eval "${{var_name}}='{username}'"
          elif [[ "$*" == *"Password"* ]]; then
            eval "${{var_name}}='password123'"
          fi
        }}

        kinit() {{
          echo "KINIT_PRINCIPAL:$1"
          return 0
        }}

        command() {{
          if [[ "$2" == "kinit" ]]; then
            return 0
          fi
          builtin command "$@"
        }}

        write_bootstrap_vars_ad_phase_state() {{ :; }}
        /usr/local/sbin/run-ansible-pull() {{ :; }}

        join_active_directory
        """
    )


def test_join_active_directory_strips_lowercase_realm_suffix() -> None:
    result = run_bash(_join_ad_harness("duckd-a@hhmi.org"))
    assert "KINIT_PRINCIPAL:duckd-a@HHMI.ORG" in result.stdout


def test_join_active_directory_strips_uppercase_realm_suffix() -> None:
    result = run_bash(_join_ad_harness("duckd-a@HHMI.ORG"))
    assert "KINIT_PRINCIPAL:duckd-a@HHMI.ORG" in result.stdout


def test_join_active_directory_strips_mixed_case_realm_suffix() -> None:
    result = run_bash(_join_ad_harness("duckd-a@Hhmi.Org"))
    assert "KINIT_PRINCIPAL:duckd-a@HHMI.ORG" in result.stdout


def test_join_active_directory_passes_bare_username_through() -> None:
    result = run_bash(_join_ad_harness("duckd-a"))
    assert "KINIT_PRINCIPAL:duckd-a@HHMI.ORG" in result.stdout


def test_join_active_directory_rejects_other_realm_suffix() -> None:
    result = run_bash(_join_ad_harness("duckd-a@example.com"), check=False)
    assert result.returncode != 0
    assert "must be in the hhmi.org realm" in result.stderr
    assert "@example.com" in result.stderr
    assert "KINIT_PRINCIPAL:" not in result.stdout


def test_is_already_joined_to_ad_helper() -> None:
    # When realm command is missing
    result_missing = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            command() {
              if [[ "$2" == "realm" ]]; then
                return 1
              fi
              builtin command "$@"
            }
            if is_already_joined_to_ad; then
              echo "joined"
            else
              echo "not joined"
            fi
            """
        )
    )
    assert "not joined" in result_missing.stdout

    # When realm command exists but hhmi.org is not listed
    result_not_joined = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            command() {
              if [[ "$2" == "realm" ]]; then
                return 0
              fi
              builtin command "$@"
            }
            realm() {
              echo "otherdomain.com"
            }
            if is_already_joined_to_ad; then
              echo "joined"
            else
              echo "not joined"
            fi
            """
        )
    )
    assert "not joined" in result_not_joined.stdout

    # When realm command exists and hhmi.org is listed
    result_joined = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            command() {
              if [[ "$2" == "realm" ]]; then
                return 0
              fi
              builtin command "$@"
            }
            realm() {
              echo "hhmi.org"
            }
            if is_already_joined_to_ad; then
              echo "joined"
            else
              echo "not joined"
            fi
            """
        )
    )
    assert "joined" in result_joined.stdout


def test_main_skips_enrollment_if_already_joined() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh

            # Mock all setup functions
            audit_log_invocation() { :; }
            preload_existing_pull_env() { :; }
            parse_args() { :; }
            validate_prerequisites() { :; }
            install_bootstrap_dependencies() { :; }
            prepare_runtime_directories() { :; }
            configure_git_credentials() { :; }
            acquire_pull_sync_lock() { :; }
            release_pull_sync_lock() { :; }
            sync_repository_checkout() { :; }
            source_checkout_libs() { :; }
            install_runtime_support() { :; }
            write_pull_environment() { :; }
            prompt_slack_webhook() { :; }
            prompt_machine_identity() { :; }

            # Mock AD check to return true (already joined)
            is_already_joined_to_ad() {
              return 0
            }

            # Mock execution steps
            write_bootstrap_vars_final_state() {
              echo "WRITE_FINAL_STATE"
            }
            write_bootstrap_vars_initial_state() {
              echo "WRITE_INITIAL_STATE"
            }
            run_initial_configuration() {
              echo "RUN_CONVERGE"
            }
            join_active_directory() {
              echo "JOIN_ACTIVE_DIRECTORY"
            }
            mark_final_state_written() {
              echo "MARK_FINAL_STATE"
            }
            enable_pull_timer() {
              echo "ENABLE_PULL_TIMER"
            }
            run_final_upgrade() {
              echo "RUN_FINAL_UPGRADE"
            }
            print_ad_reboot_warning() {
              echo "PRINT_REBOOT_WARNING"
            }

            # Run main
            main
            """
        )
    )
    # Verify that Phase 1 & join_active_directory are skipped
    assert "WRITE_INITIAL_STATE" not in result.stdout
    assert "JOIN_ACTIVE_DIRECTORY" not in result.stdout

    # Verify that Phase 2 is run directly
    assert "WRITE_FINAL_STATE" in result.stdout
    assert "RUN_CONVERGE" in result.stdout
    assert "MARK_FINAL_STATE" in result.stdout
    assert "ENABLE_PULL_TIMER" in result.stdout
    assert "RUN_FINAL_UPGRADE" in result.stdout

    # Verify that reboot warning is skipped
    assert "PRINT_REBOOT_WARNING" not in result.stdout


def test_main_performs_full_two_phase_enrollment_if_not_joined() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh

            # Mock all setup functions
            audit_log_invocation() { :; }
            preload_existing_pull_env() { :; }
            parse_args() { :; }
            validate_prerequisites() { :; }
            install_bootstrap_dependencies() { :; }
            prepare_runtime_directories() { :; }
            configure_git_credentials() { :; }
            acquire_pull_sync_lock() { :; }
            release_pull_sync_lock() { :; }
            sync_repository_checkout() { :; }
            source_checkout_libs() { :; }
            install_runtime_support() { :; }
            write_pull_environment() { :; }
            prompt_slack_webhook() { :; }
            prompt_machine_identity() { :; }

            # Mock AD check to return false (not joined)
            is_already_joined_to_ad() {
              return 1
            }

            # Mock execution steps
            write_bootstrap_vars_final_state() {
              echo "WRITE_FINAL_STATE"
            }
            write_bootstrap_vars_initial_state() {
              echo "WRITE_INITIAL_STATE"
            }
            run_initial_configuration() {
              echo "RUN_CONVERGE"
            }
            join_active_directory() {
              echo "JOIN_ACTIVE_DIRECTORY"
            }
            mark_final_state_written() {
              echo "MARK_FINAL_STATE"
            }
            enable_pull_timer() {
              echo "ENABLE_PULL_TIMER"
            }
            run_final_upgrade() {
              echo "RUN_FINAL_UPGRADE"
            }
            print_ad_reboot_warning() {
              echo "PRINT_REBOOT_WARNING"
            }

            # Run main
            main
            """
        )
    )
    # Verify that Phase 1 and Phase 2 are both run
    assert "WRITE_INITIAL_STATE" in result.stdout
    assert "JOIN_ACTIVE_DIRECTORY" in result.stdout
    assert "WRITE_FINAL_STATE" in result.stdout
    assert "RUN_CONVERGE" in result.stdout
    assert "MARK_FINAL_STATE" in result.stdout
    assert "ENABLE_PULL_TIMER" in result.stdout
    assert "RUN_FINAL_UPGRADE" in result.stdout

    # Verify that reboot warning is printed
    assert "PRINT_REBOOT_WARNING" in result.stdout


def test_is_valid_username_accepts_expected_values() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            for name in alice duckd-a john_doe _svc b2 user.name a-b-c; do
              is_valid_username "$name" || echo "REJECTED:$name"
            done
            echo DONE
            """
        )
    )
    assert "REJECTED" not in result.stdout
    assert "DONE" in result.stdout


def test_is_valid_username_rejects_invalid_values() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            long="$(printf 'a%.0s' {1..33})"
            for name in "" "1abc" "bad name" 'a;b' 'a$(x)' '../etc' "$long"; do
              if is_valid_username "$name"; then echo "ACCEPTED:$name"; fi
            done
            echo DONE
            """
        )
    )
    assert "ACCEPTED" not in result.stdout
    assert "DONE" in result.stdout


def test_prompt_machine_identity_happy_path() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            hostname() { echo ignored-default; }
            prompt_machine_identity <<'INPUT'
            my-host
            desktop
            alice, bob
            y
            INPUT
            echo "HOST=$SHORT_HOSTNAME TYPE=$MACHINE_TYPE SUDO=${SUDO_USERS[*]}"
            """
        )
    )
    assert "HOST=my-host TYPE=desktop SUDO=alice bob" in result.stdout


def test_prompt_machine_identity_aborts_on_eof() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            hostname() { echo ignored-default; }
            prompt_machine_identity </dev/null
            """
        ),
        check=False,
    )
    assert result.returncode != 0
    assert "reached end of input while reading the short hostname" in result.stderr


def test_prompt_machine_type_reprompts_on_invalid() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            prompt_machine_type <<'INPUT'
            server
            laptop
            INPUT
            echo "TYPE=$MACHINE_TYPE"
            """
        )
    )
    assert "'laptop' or 'desktop'" in result.stderr
    assert "TYPE=laptop" in result.stdout


def test_prompt_sudo_users_blank_means_none() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            SUDO_USERS=("stale")
            prompt_sudo_users <<'INPUT'

            INPUT
            echo "COUNT=${#SUDO_USERS[@]}"
            """
        )
    )
    assert "COUNT=0" in result.stdout


def test_prompt_sudo_users_reprompts_on_invalid_username() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            prompt_sudo_users <<'INPUT'
            bad name!
            alice,bob
            INPUT
            echo "SUDO=${SUDO_USERS[*]}"
            """
        )
    )
    assert "invalid username" in result.stderr
    assert "SUDO=alice bob" in result.stdout


def test_prompt_machine_identity_restarts_when_not_confirmed() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            hostname() { echo ignored-default; }
            prompt_machine_identity <<'INPUT'
            first-host
            desktop

            n
            second-host
            laptop

            y
            INPUT
            echo "HOST=$SHORT_HOSTNAME TYPE=$MACHINE_TYPE"
            """
        )
    )
    assert "Restarting machine identity prompts" in result.stderr
    assert "HOST=second-host TYPE=laptop" in result.stdout


def test_confirm_machine_identity_aborts_on_eof() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            SHORT_HOSTNAME=h
            MACHINE_TYPE=laptop
            SUDO_USERS=()
            confirm_machine_identity </dev/null
            """
        ),
        check=False,
    )
    assert result.returncode != 0
    assert "reached end of input while reading the confirmation" in result.stderr


def test_join_active_directory_rejects_invalid_username_format() -> None:
    result = run_bash(_join_ad_harness("bad name!"), check=False)
    assert result.returncode != 0
    assert "not a valid username" in result.stderr
    assert "KINIT_PRINCIPAL:" not in result.stdout


def test_audit_log_invocation_redacts_secrets() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            logger() { echo "LOGGED: $*"; }
            command() { if [[ "$2" == "logger" ]]; then return 0; fi; builtin command "$@"; }
            audit_log_invocation tag --repo https://example.invalid \
              --github-token ghp_TOPSECRET \
              --slack-webhook https://hooks.slack.com/services/SECRETPATH
            """
        )
    )
    assert "ghp_TOPSECRET" not in result.stdout
    assert "SECRETPATH" not in result.stdout
    assert "***REDACTED***" in result.stdout
    assert "--repo https://example.invalid" in result.stdout


def test_is_plausible_repo_url() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            for u in https://github.com/x/y.git http://h/r git@github.com:x/y.git \
                     ssh://h/r file:///srv/r /srv/local ./rel ../rel; do
              is_plausible_repo_url "$u" || echo "REJECTED:$u"
            done
            for u in "" "not a url" "ftp://h/r" "has space"; do
              if is_plausible_repo_url "$u"; then echo "ACCEPTED:$u"; fi
            done
            echo DONE
            """
        )
    )
    assert "REJECTED" not in result.stdout
    assert "ACCEPTED" not in result.stdout
    assert "DONE" in result.stdout


def test_is_valid_webhook_url() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            is_valid_webhook_url "https://hooks.slack.com/services/T/B/X" || echo "REJECTED:good"
            for u in "" "http://insecure" "https://has space" "ftp://x"; do
              if is_valid_webhook_url "$u"; then echo "ACCEPTED:$u"; fi
            done
            echo DONE
            """
        )
    )
    assert "REJECTED" not in result.stdout
    assert "ACCEPTED" not in result.stdout
    assert "DONE" in result.stdout


def test_parse_args_rejects_invalid_slack_webhook() -> None:
    result = run_bash(
        "\n".join(
            [
                "source scripts/bootstrap-ubuntu.sh",
                "parse_args --repo https://example.invalid --slack-webhook http://insecure",
            ]
        ),
        check=False,
    )
    assert result.returncode != 0
    assert "must be an https:// URL" in result.stderr


def test_prompt_slack_webhook_blank_skips() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            SLACK_WEBHOOK_URL=""
            prompt_slack_webhook <<'INPUT'

            INPUT
            echo "WEBHOOK=[${SLACK_WEBHOOK_URL}]"
            """
        )
    )
    assert "WEBHOOK=[]" in result.stdout


def test_prompt_slack_webhook_accepts_and_reprompts() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            SLACK_WEBHOOK_URL=""
            prompt_slack_webhook <<'INPUT'
            http://insecure
            https://hooks.slack.com/services/ok
            INPUT
            echo "WEBHOOK=[${SLACK_WEBHOOK_URL}]"
            """
        )
    )
    assert "does not look like a webhook URL" in result.stderr
    assert "WEBHOOK=[https://hooks.slack.com/services/ok]" in result.stdout


def test_prompt_slack_webhook_respects_cli_value() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            SLACK_WEBHOOK_URL="https://hooks.slack.com/services/preset"
            prompt_slack_webhook </dev/null
            echo "WEBHOOK=[${SLACK_WEBHOOK_URL}]"
            """
        )
    )
    assert "WEBHOOK=[https://hooks.slack.com/services/preset]" in result.stdout


def test_join_active_directory_aborts_after_max_kinit_failures() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            read() {
              local var_name="${@: -1}"
              if [[ "$*" == *"Username"* ]]; then
                eval "${var_name}='duckd-a'"
              elif [[ "$*" == *"Password"* ]]; then
                eval "${var_name}='pw'"
              fi
            }
            kinit() { return 1; }
            command() { if [[ "$2" == "kinit" ]]; then return 0; fi; builtin command "$@"; }
            write_bootstrap_vars_ad_phase_state() { :; }
            /usr/local/sbin/run-ansible-pull() { :; }
            join_active_directory
            """
        ),
        check=False,
    )
    assert result.returncode != 0
    assert "failed AD authentication attempts" in result.stderr
    # 5-attempt cap: attempts 1-4 print a retry line, the 5th aborts.
    assert result.stderr.count("kinit failed (attempt") == 4


def test_preload_existing_pull_env_adopts_existing_values(tmp_path: Path) -> None:
    env_file = tmp_path / "pull.env"
    env_file.write_text(
        "REPO_URL=https://example.invalid/repo.git\n"
        "BRANCH=testing\n"
        "SLACK_WEBHOOK_URL=https://hooks.slack.com/services/EXISTING\n",
        encoding="utf-8",
    )
    result = run_bash(
        textwrap.dedent(
            f"""\
            source scripts/bootstrap-ubuntu.sh
            PULL_ENV_FILE={shlex.quote(str(env_file))}
            preload_existing_pull_env
            echo "BRANCH=${{BRANCH}} WEBHOOK=${{SLACK_WEBHOOK_URL}}"
            """
        )
    )
    assert "BRANCH=testing" in result.stdout
    assert "WEBHOOK=https://hooks.slack.com/services/EXISTING" in result.stdout


def test_cli_args_override_preloaded_pull_env(tmp_path: Path) -> None:
    env_file = tmp_path / "pull.env"
    env_file.write_text("BRANCH=testing\n", encoding="utf-8")
    result = run_bash(
        textwrap.dedent(
            f"""\
            source scripts/bootstrap-ubuntu.sh
            PULL_ENV_FILE={shlex.quote(str(env_file))}
            # Mirror main()'s order: preload first, then parse CLI on top.
            preload_existing_pull_env
            parse_args --repo https://example.invalid/repo.git --branch main
            echo "BRANCH=${{BRANCH}}"
            """
        )
    )
    # Explicit --branch wins over the preloaded value.
    assert "BRANCH=main" in result.stdout


def test_reset_env_flag_skips_preload_and_rebuilds_from_defaults(tmp_path: Path) -> None:
    env_file = tmp_path / "pull.env"
    env_file.write_text("BRANCH=testing\n", encoding="utf-8")
    result = run_bash(
        textwrap.dedent(
            f"""\
            source scripts/bootstrap-ubuntu.sh
            PULL_ENV_FILE={shlex.quote(str(env_file))}
            # Mirror main()'s gate: --reset-env present -> skip the preload.
            if ! args_contain_reset_env --repo https://example.invalid/repo.git --reset-env; then
              preload_existing_pull_env
            fi
            parse_args --repo https://example.invalid/repo.git --reset-env
            echo "BRANCH=${{BRANCH}} RESET=${{RESET_ENV}}"
            """
        )
    )
    # Existing BRANCH=testing is ignored; the built-in default wins.
    assert "BRANCH=main" in result.stdout
    assert "RESET=true" in result.stdout


def test_default_rerun_preserves_existing_when_no_reset_flag(tmp_path: Path) -> None:
    env_file = tmp_path / "pull.env"
    env_file.write_text("BRANCH=testing\n", encoding="utf-8")
    result = run_bash(
        textwrap.dedent(
            f"""\
            source scripts/bootstrap-ubuntu.sh
            PULL_ENV_FILE={shlex.quote(str(env_file))}
            if ! args_contain_reset_env --repo https://example.invalid/repo.git; then
              preload_existing_pull_env
            fi
            parse_args --repo https://example.invalid/repo.git
            echo "BRANCH=${{BRANCH}} RESET=${{RESET_ENV}}"
            """
        )
    )
    # No --reset-env: the existing branch is preserved.
    assert "BRANCH=testing" in result.stdout
    assert "RESET=false" in result.stdout


def test_preload_existing_pull_env_tolerates_missing_file(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist.env"
    result = run_bash(
        textwrap.dedent(
            f"""\
            source scripts/bootstrap-ubuntu.sh
            PULL_ENV_FILE={shlex.quote(str(missing))}
            preload_existing_pull_env
            echo "BRANCH=${{BRANCH}}"
            """
        )
    )
    # Falls through to the built-in default with no error.
    assert "BRANCH=main" in result.stdout


def test_preloaded_webhook_is_preserved_when_prompt_is_skipped(tmp_path: Path) -> None:
    env_file = tmp_path / "pull.env"
    env_file.write_text(
        "SLACK_WEBHOOK_URL=https://hooks.slack.com/services/KEEP\n",
        encoding="utf-8",
    )
    result = run_bash(
        textwrap.dedent(
            f"""\
            source scripts/bootstrap-ubuntu.sh
            PULL_ENV_FILE={shlex.quote(str(env_file))}
            preload_existing_pull_env
            # On a re-run the operator passes nothing; the prompt should see the
            # preloaded value and skip, leaving the webhook intact.
            prompt_slack_webhook </dev/null
            echo "WEBHOOK=${{SLACK_WEBHOOK_URL}}"
            """
        )
    )
    assert "WEBHOOK=https://hooks.slack.com/services/KEEP" in result.stdout


def test_run_final_upgrade_is_non_fatal_on_apt_failure() -> None:
    result = run_bash(
        textwrap.dedent(
            """\
            source scripts/bootstrap-ubuntu.sh
            apt-get() { return 1; }
            run_final_upgrade
            echo "CONTINUED rc=$?"
            """
        )
    )
    assert "final package upgrade did not complete" in result.stderr
    assert "CONTINUED rc=0" in result.stdout

