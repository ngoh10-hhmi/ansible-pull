#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

LABEL=""
LIST_FILE=""

usage() {
  cat <<'EOF'
Usage: upgrade-installed-apt-packages.sh --label <label> --list-file <path>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      LABEL="${2:-}"
      shift 2
      ;;
    --list-file)
      LIST_FILE="${2:-}"
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

if [[ -z "${LABEL}" || -z "${LIST_FILE}" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -r "${LIST_FILE}" ]]; then
  echo "No readable package list found for ${LABEL}: ${LIST_FILE}"
  exit 0
fi

mapfile -t requested_packages < <(
  grep -Ev '^[[:space:]]*(#|$)' "${LIST_FILE}" || true
)

if [[ ${#requested_packages[@]} -eq 0 ]]; then
  echo "No requested packages defined for ${LABEL}"
  exit 0
fi

installed_packages=()
for package_name in "${requested_packages[@]}"; do
  # dpkg-query -f='${Status}\n' returns a three-word status string.
  # "install ok installed" means the package is fully installed and not
  # pending removal. Other states (e.g. "deinstall ok config-files") mean
  # the package has been removed and should not be included in the upgrade.
  if dpkg-query -W -f='${Status}\n' "${package_name}" 2>/dev/null | grep -qx 'install ok installed'; then
    installed_packages+=("${package_name}")
  fi
done

if [[ ${#installed_packages[@]} -eq 0 ]]; then
  echo "No installed packages matched the ${LABEL} update list"
  exit 0
fi

echo "Refreshing APT metadata for ${LABEL} updates"
apt-get update -o DPkg::Lock::Timeout=600

upgradable_packages=()
skipped_packages=()

for package_name in "${installed_packages[@]}"; do
  # apt-cache policy prints "Candidate: <version>" for the best available
  # version in the current package index. A value of "(none)" means no
  # candidate exists in the configured APT sources (e.g. repo not yet
  # refreshed, or package removed from upstream), so skip those to avoid
  # a failed apt-get install call.
  candidate_version="$(
    apt-cache policy "${package_name}" \
      | awk '/Candidate:/ { print $2; exit }'
  )"

  if [[ -n "${candidate_version}" && "${candidate_version}" != "(none)" ]]; then
    upgradable_packages+=("${package_name}")
  else
    skipped_packages+=("${package_name}")
  fi
done

if [[ ${#skipped_packages[@]} -gt 0 ]]; then
  echo "Skipping ${LABEL} packages without an APT candidate: ${skipped_packages[*]}"
fi

if [[ ${#upgradable_packages[@]} -eq 0 ]]; then
  echo "No installed ${LABEL} packages have an upgrade candidate"
  exit 0
fi

echo "Upgrading installed ${LABEL} packages: ${upgradable_packages[*]}"
# --only-upgrade tells apt-get to upgrade existing packages but never install
# new ones. This ensures the timer only refreshes what is already on the
# machine and cannot silently pull in unintended packages.
# DPkg::Lock::Timeout=600 waits up to 10 minutes for the dpkg lock rather
# than failing immediately if unattended-upgrades or another apt process is
# running concurrently.
apt-get install -y --only-upgrade -o DPkg::Lock::Timeout=600 "${upgradable_packages[@]}"
