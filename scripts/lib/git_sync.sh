#!/usr/bin/env bash

git_sync_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$*"
  else
    printf '%s\n' "$*"
  fi
}

is_valid_git_worktree() {
  local repo_dir="$1"

  [[ -d "${repo_dir}/.git" ]] || return 1
  git -C "${repo_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

remove_stale_git_locks() {
  local repo_dir="$1"

  rm -f \
    "${repo_dir}/.git/index.lock" \
    "${repo_dir}/.git/shallow.lock" \
    "${repo_dir}/.git/HEAD.lock"
}

sync_checkout_or_clone() {
  local dest="$1"
  local repo_url="$2"
  local branch="$3"
  local clone_depth="${4:-}"
  local clone_args=()

  if is_valid_git_worktree "${dest}"; then
    git_sync_log "Existing repository found at ${dest}. Attempting to sync..."

    if (
      remove_stale_git_locks "${dest}"

      if git -C "${dest}" remote get-url origin >/dev/null 2>&1; then
        git -C "${dest}" remote set-url origin "${repo_url}"
      else
        git -C "${dest}" remote add origin "${repo_url}"
      fi

      git -C "${dest}" fetch --prune origin "${branch}"
      git -C "${dest}" checkout -B "${branch}" "origin/${branch}"
      git -C "${dest}" reset --hard "origin/${branch}"
      git -C "${dest}" clean -fdx
    ); then
      git_sync_log "Successfully synced existing repository."
      return 0
    fi

    git_sync_log "Error during sync of existing repository. Wiping ${dest} to allow for fresh clone next time."
    rm -rf "${dest}"
    return 1
  fi

  git_sync_log "No valid repository found at ${dest}. Attempting fresh clone..."
  rm -rf "${dest}"

  if [[ -n "${clone_depth}" ]]; then
    clone_args+=(--depth "${clone_depth}")
  fi
  clone_args+=(--branch "${branch}")

  if git clone "${clone_args[@]}" "${repo_url}" "${dest}"; then
    git_sync_log "Successfully cloned repository."
    return 0
  fi

  git_sync_log "Error: Failed to clone repository into ${dest}."
  return 1
}
