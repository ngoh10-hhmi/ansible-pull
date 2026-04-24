#!/usr/bin/env bash

git_sync_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$*"
  else
    printf '%s\n' "$*"
  fi
}

git_is_valid_sha() {
  local ref="$1"

  # A commit SHA is 40 hex chars; shorter refs are treated as branch names so
  # callers get a clear error rather than a silent mis-clone.
  [[ "${ref}" =~ ^[0-9A-Fa-f]{40}$ ]]
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

git_fetch_branch_ref() {
  local repo_dir="$1"
  local ref="$2"
  local clone_depth="${3:-}"
  local fetch_args=(--prune origin)

  if [[ -n "${clone_depth}" ]]; then
    fetch_args+=(--depth "${clone_depth}")
  fi

  fetch_args+=("+refs/heads/${ref}:refs/remotes/origin/${ref}")
  git -C "${repo_dir}" fetch "${fetch_args[@]}"
}

git_fetch_commit_ref() {
  local repo_dir="$1"
  local ref="$2"
  local clone_depth="${3:-}"
  local fetch_args=(--prune origin)

  if [[ -n "${clone_depth}" ]]; then
    fetch_args+=(--depth "${clone_depth}")
  fi

  fetch_args+=("${ref}")
  if git -C "${repo_dir}" fetch "${fetch_args[@]}"; then
    return 0
  fi

  # Some Git servers do not allow direct SHA fetches. Fall back to fetching
  # advertised refs so rollback SHAs reachable from a branch or tag still work.
  git -C "${repo_dir}" fetch --prune origin \
    "+refs/heads/*:refs/remotes/origin/*" \
    "+refs/tags/*:refs/tags/*"
}

sync_checkout_or_clone() {
  local dest="$1"
  local repo_url="$2"
  local ref="$3"
  local clone_depth="${4:-}"
  local clone_args=()

  # Detect whether the ref is a 40-character hex SHA (commit pin) or a branch name.
  local is_commit="false"
  if git_is_valid_sha "${ref}"; then
    is_commit="true"
  fi

  if is_valid_git_worktree "${dest}"; then
    git_sync_log "Existing repository found at ${dest}. Attempting to sync..."

    if (
      remove_stale_git_locks "${dest}"

      if git -C "${dest}" remote get-url origin >/dev/null 2>&1; then
        git -C "${dest}" remote set-url origin "${repo_url}"
      else
        git -C "${dest}" remote add origin "${repo_url}"
      fi

      if [[ "${is_commit}" == "true" ]]; then
        git_fetch_commit_ref "${dest}" "${ref}"
        git -C "${dest}" checkout --detach "${ref}"
        git -C "${dest}" reset --hard "${ref}"
      else
        git_fetch_branch_ref "${dest}" "${ref}"
        git -C "${dest}" checkout -B "${ref}" "origin/${ref}"
        git -C "${dest}" reset --hard "origin/${ref}"
      fi
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

  if [[ "${is_commit}" == "true" ]]; then
    if git init --quiet "${dest}" \
      && git -C "${dest}" remote add origin "${repo_url}" \
      && git_fetch_commit_ref "${dest}" "${ref}" "${clone_depth}" \
      && git -C "${dest}" checkout --detach "${ref}" \
      && git -C "${dest}" reset --hard "${ref}"; then
      git_sync_log "Successfully cloned repository."
      return 0
    fi
  else
    if [[ -n "${clone_depth}" ]]; then
      clone_args+=(--depth "${clone_depth}")
    fi
    clone_args+=(--branch "${ref}")

    if git clone "${clone_args[@]}" "${repo_url}" "${dest}"; then
      git_sync_log "Successfully cloned repository."
      return 0
    fi
  fi

  if [[ -d "${dest}" ]]; then
    rm -rf "${dest}"
  fi

  git_sync_log "Error: Failed to clone repository into ${dest}."
  return 1
}
