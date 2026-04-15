#!/usr/bin/env bash
set -euo pipefail

APT_LIST_FILE=""
SNAP_LIST_FILE=""

usage() {
  cat <<'EOF'
Usage: update-installed-browsers.sh --apt-list-file <path> --snap-list-file <path>
EOF
}

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

if [[ -x /usr/local/sbin/upgrade-installed-apt-packages ]]; then
  /usr/local/sbin/upgrade-installed-apt-packages \
    --label browser-packages \
    --list-file "${APT_LIST_FILE}"
else
  echo "APT browser update helper is not installed; skipping browser APT package updates"
fi

if ! command -v snap >/dev/null 2>&1; then
  echo "snap command not available; skipping browser snap updates"
  exit 0
fi

if [[ ! -r "${SNAP_LIST_FILE}" ]]; then
  echo "No readable browser snap list found: ${SNAP_LIST_FILE}"
  exit 0
fi

mapfile -t requested_snaps < <(
  grep -Ev '^[[:space:]]*(#|$)' "${SNAP_LIST_FILE}" || true
)

if [[ ${#requested_snaps[@]} -eq 0 ]]; then
  echo "No requested browser snaps defined"
  exit 0
fi

installed_snaps=()
for snap_name in "${requested_snaps[@]}"; do
  if snap list "${snap_name}" >/dev/null 2>&1; then
    installed_snaps+=("${snap_name}")
  fi
done

if [[ ${#installed_snaps[@]} -eq 0 ]]; then
  echo "No installed browser snaps matched the update list"
  exit 0
fi

echo "Refreshing installed browser snaps: ${installed_snaps[*]}"
snap refresh "${installed_snaps[@]}"
