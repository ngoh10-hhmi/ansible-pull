#!/usr/bin/env bash
set -euo pipefail

APT_LIST_FILE=""
SNAP_LIST_FILE=""

usage() {
  cat <<'EOF'
Usage: update-installed-browsers.sh --apt-list-file <path> --snap-list-file <path>
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apt-list-file)
        APT_LIST_FILE="${2:-}"
        shift 2
        ;;
      --snap-list-file)
        SNAP_LIST_FILE="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if [[ -z "${APT_LIST_FILE}" || -z "${SNAP_LIST_FILE}" ]]; then
    usage >&2
    exit 2
  fi
}

run_apt_browser_updates() {
  if [[ -x /usr/local/sbin/upgrade-installed-apt-packages ]]; then
    /usr/local/sbin/upgrade-installed-apt-packages \
      --label browser-packages \
      --list-file "${APT_LIST_FILE}"
  else
    echo "APT browser update helper is not installed; skipping browser APT package updates"
  fi
}

# Read the snap list, skipping comments/blank lines, and emit one snap name
# per line. Caller is responsible for filtering against installed snaps.
read_requested_snaps() {
  local snap_list_file="$1"

  if [[ ! -r "${snap_list_file}" ]]; then
    return 0
  fi

  grep -Ev '^[[:space:]]*(#|$)' "${snap_list_file}" || true
}

# Filter the requested snap list down to the snaps actually installed on this
# host. The fleet-wide list is intentionally a superset; "snap refresh <name>"
# errors out if the snap is not installed locally.
filter_to_installed_snaps() {
  local snap_name=""

  while IFS= read -r snap_name; do
    [[ -n "${snap_name}" ]] || continue
    if snap list "${snap_name}" >/dev/null 2>&1; then
      printf '%s\n' "${snap_name}"
    fi
  done
}

# Refresh each snap individually so a single failing snap (e.g. transient
# Snap Store error or a held revision) does not block updates for the
# others. Aggregate per-snap exit status and surface a final summary so the
# operator can see exactly which snaps need follow-up. Returns non-zero if
# any snap failed, so the calling systemd unit / playbook treats the run as
# failed even though we kept going.
refresh_snaps_individually() {
  local snap_name=""
  local refresh_output=""
  local refresh_status=0
  local failed=()

  for snap_name in "$@"; do
    echo "Refreshing snap: ${snap_name}"
    if refresh_output="$(snap refresh "${snap_name}" 2>&1)"; then
      printf '%s\n' "${refresh_output}"
    else
      refresh_status=$?
      printf '%s\n' "${refresh_output}"
      echo "Snap ${snap_name} refresh failed with exit code ${refresh_status}"
      failed+=("${snap_name}")
    fi
  done

  if (( ${#failed[@]} > 0 )); then
    echo "Browser snap refresh completed with failures: ${failed[*]}" >&2
    return 1
  fi
}

run_snap_browser_updates() {
  if ! command -v snap >/dev/null 2>&1; then
    echo "snap command not available; skipping browser snap updates"
    return 0
  fi

  if [[ ! -r "${SNAP_LIST_FILE}" ]]; then
    echo "No readable browser snap list found: ${SNAP_LIST_FILE}"
    return 0
  fi

  local installed_snaps=()
  mapfile -t installed_snaps < <(read_requested_snaps "${SNAP_LIST_FILE}" | filter_to_installed_snaps)

  if [[ ${#installed_snaps[@]} -eq 0 ]]; then
    echo "No installed browser snaps matched the update list"
    return 0
  fi

  echo "Refreshing installed browser snaps: ${installed_snaps[*]}"
  refresh_snaps_individually "${installed_snaps[@]}"
}

main() {
  parse_args "$@"
  run_apt_browser_updates
  run_snap_browser_updates
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
