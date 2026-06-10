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

# Compare HEAD against the expected ref after a checkout/reset so a partial
# git operation (e.g. an interrupted reset --hard) cannot leave the repository
# at the wrong commit while sync_checkout_or_clone reports success.
git_verify_head_matches_ref() {
  local repo_dir="$1"
  local ref="$2"
  local is_commit="$3"
  local actual_head=""
  local expected_head=""

  actual_head="$(git -C "${repo_dir}" rev-parse --verify HEAD 2>/dev/null || true)"
  if [[ -z "${actual_head}" ]]; then
    git_sync_log "Error: could not resolve HEAD in ${repo_dir} after sync."
    return 1
  fi

  if [[ "${is_commit}" == "true" ]]; then
    # Normalise to lowercase so a mixed-case pin still compares equal.
    expected_head="${ref,,}"
  else
    # --verify with the ^{commit} peel forces git to return only on a real
    # commit-pointing ref. Without --verify, git prints the literal arg back
    # on stdout when the ref is unknown, which would silently make the next
    # equality check report "mismatch" instead of "ref missing".
    expected_head="$(git -C "${repo_dir}" rev-parse --verify "origin/${ref}^{commit}" 2>/dev/null || true)"
  fi

  if [[ -z "${expected_head}" ]]; then
    git_sync_log "Error: could not resolve expected ref '${ref}' in ${repo_dir}."
    return 1
  fi

  if [[ "${actual_head,,}" != "${expected_head,,}" ]]; then
    git_sync_log "Error: HEAD ${actual_head} does not match expected ${expected_head}."
    return 1
  fi
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

# Point origin at the configured URL and fetch the requested ref into the
# existing worktree. Every step is checked explicitly with `|| return 1`
# rather than relying on `set -e`: sync_checkout_or_clone calls this from an
# `if` condition, where bash disables errexit for the entire call tree, so a
# bare `git fetch` failure (expired PAT, network blip) would otherwise be
# ignored and the caller would "succeed" against a stale origin ref.
sync_fetch_existing_worktree() {
  local dest="$1"
  local repo_url="$2"
  local ref="$3"
  local is_commit="$4"

  remove_stale_git_locks "${dest}"

  if git -C "${dest}" remote get-url origin >/dev/null 2>&1; then
    git -C "${dest}" remote set-url origin "${repo_url}" || return 1
  else
    git -C "${dest}" remote add origin "${repo_url}" || return 1
  fi

  if [[ "${is_commit}" == "true" ]]; then
    git_fetch_commit_ref "${dest}" "${ref}" || return 1
  else
    git_fetch_branch_ref "${dest}" "${ref}" || return 1
  fi
}

# Move the existing worktree onto the freshly fetched ref. A failure here can
# leave the worktree half-updated, so the caller wipes it for a clean reclone.
sync_apply_ref_to_worktree() {
  local dest="$1"
  local ref="$2"
  local is_commit="$3"

  if [[ "${is_commit}" == "true" ]]; then
    git -C "${dest}" checkout --detach "${ref}" || return 1
    git -C "${dest}" reset --hard "${ref}" || return 1
  else
    git -C "${dest}" checkout -B "${ref}" "origin/${ref}" || return 1
    git -C "${dest}" reset --hard "origin/${ref}" || return 1
  fi
  git -C "${dest}" clean -fdx || return 1
  git_verify_head_matches_ref "${dest}" "${ref}" "${is_commit}" || return 1
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

    # Fetch first. If the fetch fails, keep the existing checkout in place: the
    # cause is almost always transient (network outage) or a credential problem
    # that wiping cannot fix, and a fresh clone would just fail the same way --
    # leaving the host with no code at all. We still return non-zero so the run
    # fails loudly and the OnFailure/drift alerting fires, instead of silently
    # "succeeding" against stale code.
    if ! sync_fetch_existing_worktree "${dest}" "${repo_url}" "${ref}" "${is_commit}"; then
      git_sync_log "Error: failed to fetch updates for existing repository at ${dest}; leaving the current checkout untouched."
      return 1
    fi

    if sync_apply_ref_to_worktree "${dest}" "${ref}" "${is_commit}"; then
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
      && git -C "${dest}" reset --hard "${ref}" \
      && git_verify_head_matches_ref "${dest}" "${ref}" "true"; then
      git_sync_log "Successfully cloned repository."
      return 0
    fi
  else
    if [[ -n "${clone_depth}" ]]; then
      clone_args+=(--depth "${clone_depth}")
    fi
    clone_args+=(--branch "${ref}")

    if git clone "${clone_args[@]}" "${repo_url}" "${dest}" \
      && git_verify_head_matches_ref "${dest}" "${ref}" "false"; then
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
