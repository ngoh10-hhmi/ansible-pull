#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_LIB_DIR="/usr/local/lib/ansible-pull"

source_script_lib() {
  local filename="$1"
  local candidate=""

  for candidate in "${SCRIPT_DIR}/lib/${filename}" "${SHARED_LIB_DIR}/${filename}"; do
    if [[ -f "${candidate}" ]]; then
      # shellcheck disable=SC1090
      source "${candidate}"
      return 0
    fi
  done

  echo "Missing helper library ${filename}" >&2
  exit 1
}

source_script_lib "apt_lock.sh"

LABEL=""
LIST_FILE=""
# Each entry is "<service>:<pkg>[,<pkg>...]"; see --restart-verify below.
RESTART_VERIFY_SPECS=()

usage() {
  cat <<'EOF'
Usage: upgrade-installed-apt-packages.sh --label <label> --list-file <path> \
         [--restart-verify <service>:<pkg>[,<pkg>...]]...

--restart-verify pairs a systemd service with the packages whose upgrade
should trigger a clean restart-and-verify of that service after the apt
transaction has fully settled. May be given more than once. If the service is
not active afterward the script exits non-zero, so the calling systemd unit
records a failure (and the next ansible-pull converge's SSSD health check, or
any OnFailure hook, surfaces it).
EOF
}

parse_args() {
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
      --restart-verify)
        RESTART_VERIFY_SPECS+=("${2:-}")
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
}

# Emit the package names from a list file, skipping comments and blank lines.
read_requested_packages() {
  local list_file="$1"

  if [[ ! -r "${list_file}" ]]; then
    return 0
  fi

  grep -Ev '^[[:space:]]*(#|$)' "${list_file}" || true
}

# Filter stdin (one package per line) down to packages that are fully
# installed. dpkg-query -f='${Status}\n' returns a three-word status string;
# "install ok installed" means installed and not pending removal. Other states
# (e.g. "deinstall ok config-files") mean the package was removed and should
# not be upgraded.
filter_to_installed_packages() {
  local package_name=""

  while IFS= read -r package_name; do
    [[ -n "${package_name}" ]] || continue
    if dpkg-query -W -f='${Status}\n' "${package_name}" 2>/dev/null \
        | grep -qx 'install ok installed'; then
      printf '%s\n' "${package_name}"
    fi
  done
}

# Print the currently-installed version of a package, or empty if absent.
installed_version() {
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

# Emit every package named in --restart-verify trigger lists, de-duplicated.
collect_restart_trigger_packages() {
  local spec="" triggers_csv="" trigger=""
  local trigger_packages=()
  local seen_packages=""

  for spec in "${RESTART_VERIFY_SPECS[@]}"; do
    # Skip malformed specs (no colon); restart_verify_services does the same
    # before attempting to act on a service.
    [[ "${spec}" == *:* ]] || continue
    triggers_csv="${spec#*:}"

    IFS=',' read -r -a trigger_packages <<< "${triggers_csv}"
    for trigger in "${trigger_packages[@]}"; do
      # Trim accidental whitespace around CSV entries.
      trigger="${trigger#"${trigger%%[![:space:]]*}"}"
      trigger="${trigger%"${trigger##*[![:space:]]}"}"
      [[ -n "${trigger}" ]] || continue
      if [[ " ${seen_packages} " != *" ${trigger} "* ]]; then
        printf '%s\n' "${trigger}"
        seen_packages+=" ${trigger}"
      fi
    done
  done
}

# Restart and verify each critical service whose trigger packages changed
# during this run.
#
# Why this exists: a package upgrade can restart a long-running daemon
# mid-transaction, while its plugins/helpers are only half-swapped on disk.
# That was observed with sssd on Ubuntu 26.04 -- the dpkg-triggered restart
# loaded a mismatched AD provider shared object, sssd_be exited ("Could not
# restart critical service"), and nothing brought it back until a manual
# restart hours later, locking AD users out. Doing one clean restart here,
# after the whole transaction settles, runs the service against consistent
# binaries; failing loudly turns a silent lockout into a recorded failure.
#
# Arg: a space-delimited list of changed trigger package names. Reads
# RESTART_VERIFY_SPECS for the service-to-trigger-package mappings.
restart_verify_services() {
  local changed_trigger_packages="$1"
  local spec="" service_name="" triggers_csv="" trigger=""
  local triggered=false
  local trigger_packages=()
  local failures=()

  for spec in "${RESTART_VERIFY_SPECS[@]}"; do
    # Skip malformed specs (no colon) rather than restart the wrong unit.
    [[ "${spec}" == *:* ]] || continue
    service_name="${spec%%:*}"
    triggers_csv="${spec#*:}"

    triggered=false
    IFS=',' read -r -a trigger_packages <<< "${triggers_csv}"
    for trigger in "${trigger_packages[@]}"; do
      trigger="${trigger#"${trigger%%[![:space:]]*}"}"
      trigger="${trigger%"${trigger##*[![:space:]]}"}"
      [[ -n "${trigger}" ]] || continue
      # Whole-word match against the space-delimited changed trigger list.
      if [[ " ${changed_trigger_packages} " == *" ${trigger} "* ]]; then
        triggered=true
        break
      fi
    done

    if [[ "${triggered}" != true ]]; then
      continue
    fi

    echo "Critical service ${service_name} had upgraded packages; restarting it to load the new binaries"
    if ! systemctl restart "${service_name}"; then
      echo "ERROR: failed to restart ${service_name} after ${LABEL} upgrade" >&2
      failures+=("${service_name}")
      continue
    fi

    if systemctl is-active --quiet "${service_name}"; then
      echo "${service_name} is active after the post-upgrade restart"
    else
      echo "ERROR: ${service_name} is not active after restart following ${LABEL} upgrade" >&2
      failures+=("${service_name}")
    fi
  done

  if (( ${#failures[@]} > 0 )); then
    echo "Critical services not healthy after ${LABEL} upgrade: ${failures[*]}" >&2
    return 1
  fi
}

run_upgrade() {
  local package_name=""

  if [[ ! -r "${LIST_FILE}" ]]; then
    echo "No readable package list found for ${LABEL}: ${LIST_FILE}"
    return 0
  fi

  local requested_packages=()
  mapfile -t requested_packages < <(read_requested_packages "${LIST_FILE}")

  if [[ ${#requested_packages[@]} -eq 0 ]]; then
    echo "No requested packages defined for ${LABEL}"
    return 0
  fi

  local installed_packages=()
  mapfile -t installed_packages < <(
    printf '%s\n' "${requested_packages[@]}" | filter_to_installed_packages
  )

  if [[ ${#installed_packages[@]} -eq 0 ]]; then
    echo "No installed packages matched the ${LABEL} update list"
    return 0
  fi

  echo "Refreshing APT metadata for ${LABEL} updates"
  # DPkg::Lock::Timeout does not cover /var/lib/apt/lists/lock, which is the
  # lock "apt-get update" actually takes, so the retry wrapper supplies the
  # waiting behavior when a concurrent maintenance timer holds it.
  apt_get_with_lock_retry update -o DPkg::Lock::Timeout=600

  local upgradable_packages=()
  local skipped_packages=()
  local candidate_version=""

  for package_name in "${installed_packages[@]}"; do
    # apt-cache policy prints "Candidate: <version>" for the best available
    # version in the current package index. A value of "(none)" means no
    # candidate exists in the configured APT sources (e.g. repo not yet
    # refreshed, or package removed from upstream), so skip those to avoid a
    # failed apt-get install call.
    #
    # LC_ALL=C forces the English "Candidate:" label. systemd propagates
    # /etc/default/locale into the unit, so on a non-English host the label is
    # translated, the awk match never fires, every package looks candidate-less,
    # and the timer silently stops upgrading anything (including SSSD).
    candidate_version="$(
      LC_ALL=C apt-cache policy "${package_name}" \
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
    return 0
  fi

  # Snapshot restart trigger package versions before the transaction so we can
  # tell which ones actually changed. They are tracked separately from the
  # requested list so a dependency upgraded by the apt transaction can still
  # drive post-upgrade service restart/verification even if it was not
  # explicitly listed in LIST_FILE.
  local watched_trigger_packages=()
  local trigger_version_before=()
  if (( ${#RESTART_VERIFY_SPECS[@]} > 0 )); then
    mapfile -t watched_trigger_packages < <(collect_restart_trigger_packages)
    for package_name in "${watched_trigger_packages[@]}"; do
      trigger_version_before+=("$(installed_version "${package_name}")")
    done
  fi

  echo "Upgrading installed ${LABEL} packages: ${upgradable_packages[*]}"
  # --only-upgrade tells apt-get to upgrade existing packages but never install
  # new ones. This ensures the timer only refreshes what is already on the
  # machine and cannot silently pull in unintended packages.
  # DPkg::Lock::Timeout=600 waits up to 10 minutes for the dpkg lock rather
  # than failing immediately if unattended-upgrades or another apt process is
  # running concurrently. That option does not cover the archives/download
  # lock, so this call goes through the retry wrapper as well.
  apt_get_with_lock_retry install -y --only-upgrade -o DPkg::Lock::Timeout=600 "${upgradable_packages[@]}"

  if (( ${#RESTART_VERIFY_SPECS[@]} > 0 )); then
    local version_after=""
    local index=0
    local changed_trigger_packages=()
    for index in "${!watched_trigger_packages[@]}"; do
      package_name="${watched_trigger_packages[${index}]}"
      version_after="$(installed_version "${package_name}")"
      if [[ "${version_after}" != "${trigger_version_before[${index}]}" ]]; then
        changed_trigger_packages+=("${package_name}")
      fi
    done

    restart_verify_services "${changed_trigger_packages[*]}"
  fi
}

main() {
  parse_args "$@"
  run_upgrade
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
