#!/usr/bin/env bash

# Shared APT lock-contention retry helper.
#
# Why this exists: apt has two families of locks and only one of them honors
# DPkg::Lock::Timeout.
#
#   * /var/lib/dpkg/lock-frontend and /var/lib/dpkg/lock, taken by
#     "apt-get install", DO honor DPkg::Lock::Timeout.
#   * /var/lib/apt/lists/lock, taken by "apt-get update", and
#     /var/cache/apt/archives/lock do NOT. apt fails those immediately with
#     "E: Could not get lock ... It is held by process N" and exits 100.
#
# apt-refresh.timer (hourly, no jitter, so exactly on the hour) and the daily
# managed-package-updates.timer / browser-package-updates.timer (03:00 and
# 04:00 plus up to 15 minutes of jitter) all run "apt-get update". When a daily
# timer draws a jitter of a few seconds it lands inside apt-refresh's ~1s run,
# loses the lists lock race, and dies having upgraded nothing -- observed on
# 2026-08-05, where managed-package-updates started at 03:00:04 while
# apt-refresh held the lock and exited 100 after 0.79s. Retrying here gives the
# unit the wait-for-the-other-guy behavior DPkg::Lock::Timeout was already
# meant to provide.
#
# Retry is deliberately keyed to the lock-contention signature only, so genuine
# apt failures (unreachable mirror, missing signing key, unmet dependency)
# still fail fast and loudly instead of being retried for ten minutes.

# Total time to keep retrying, and the pause between attempts. Both are
# overridable through the environment so tests can drive the loop without
# sleeping and operators can tune a slow host without a code change. The
# default matches the DPkg::Lock::Timeout=600 the callers already pass.
APT_LOCK_RETRY_TIMEOUT_SEC="${APT_LOCK_RETRY_TIMEOUT_SEC:-600}"
APT_LOCK_RETRY_INTERVAL_SEC="${APT_LOCK_RETRY_INTERVAL_SEC:-15}"

apt_lock_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$*"
  else
    printf '%s\n' "$*"
  fi
}

# True when apt's stderr shows it gave up waiting for one of its own locks.
# Covers the lists lock ("apt-get update"), the archives/download lock, and the
# dpkg frontend/administration locks -- the last of those normally waits via
# DPkg::Lock::Timeout, but it still reports this way when that budget runs out
# or when a caller forgets the option.
apt_output_is_lock_contention() {
  local output="$1"

  printf '%s' "${output}" | grep -qiE \
    'could not get lock|unable to lock (the )?(directory|administration directory|download directory)|unable to acquire the dpkg (frontend )?lock'
}

# Run apt-get, retrying only while it is blocked on an APT lock.
#
# stdout streams live so long transactions stay visible in the journal as they
# progress; stderr is captured per attempt because that is where apt reports
# lock contention, and is re-emitted on stderr after each attempt so nothing is
# swallowed. Returns apt-get's own exit code, so callers under "set -e" behave
# exactly as they did before.
apt_get_with_lock_retry() {
  local err_file=""
  local status=0

  err_file="$(mktemp "${TMPDIR:-/tmp}/apt-lock-retry.XXXXXX")" || {
    echo "ERROR: could not create a temporary file for apt-get stderr" >&2
    return 1
  }

  apt_get_retry_loop "${err_file}" "$@"
  status=$?

  rm -f "${err_file}"
  return "${status}"
}

# Retry loop body. Split out from apt_get_with_lock_retry so that function can
# clean up its temporary file on every exit path without a trap.
apt_get_retry_loop() {
  local err_file="$1"
  shift

  local waited_sec=0
  local attempt=1
  local status=0
  local stderr_output=""

  while true; do
    status=0
    apt-get "$@" 2>"${err_file}" || status=$?
    stderr_output="$(cat "${err_file}")"

    if [[ -n "${stderr_output}" ]]; then
      printf '%s\n' "${stderr_output}" >&2
    fi

    if (( status == 0 )); then
      if (( attempt > 1 )); then
        apt_lock_log "apt-get succeeded on attempt ${attempt} after waiting ${waited_sec}s for the APT lock"
      fi
      return 0
    fi

    if ! apt_output_is_lock_contention "${stderr_output}"; then
      return "${status}"
    fi

    if (( waited_sec + APT_LOCK_RETRY_INTERVAL_SEC > APT_LOCK_RETRY_TIMEOUT_SEC )); then
      echo "ERROR: apt-get is still blocked on an APT lock after ${waited_sec}s; giving up" >&2
      return "${status}"
    fi

    apt_lock_log "Another process holds the APT lock; retrying in ${APT_LOCK_RETRY_INTERVAL_SEC}s (waited ${waited_sec}s of ${APT_LOCK_RETRY_TIMEOUT_SEC}s)"
    sleep "${APT_LOCK_RETRY_INTERVAL_SEC}"
    waited_sec=$(( waited_sec + APT_LOCK_RETRY_INTERVAL_SEC ))
    attempt=$(( attempt + 1 ))
  done
}
