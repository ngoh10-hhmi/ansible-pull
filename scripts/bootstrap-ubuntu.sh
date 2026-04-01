#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bootstrap-ubuntu.sh --repo <repo-url> [--branch <branch>] [--playbook <path>]
                      [--github-user <username>]
                      [--github-token <token> | --github-token-file <path>]

Example:
  sudo ./bootstrap-ubuntu.sh \
    --repo https://github.com/example/ansible-pull.git \
    --branch main

Private repo later:
  sudo ./bootstrap-ubuntu.sh \
    --repo https://github.com/example/ansible-pull.git \
    --branch main \
    --github-user machine-reader \
    --github-token-file /root/github-read-token.txt
EOF
}

REPO_URL=""
BRANCH="main"
PLAYBOOK="playbooks/workstation.yml"
DEST="/var/lib/ansible-pull"
LOG_DIR="/var/log/ansible-pull"
GITHUB_USER=""
GITHUB_TOKEN=""
GITHUB_TOKEN_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_URL="${2:-}"
      shift 2
      ;;
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    --playbook)
      PLAYBOOK="${2:-}"
      shift 2
      ;;
    --github-user)
      GITHUB_USER="${2:-}"
      shift 2
      ;;
    --github-token)
      GITHUB_TOKEN="${2:-}"
      shift 2
      ;;
    --github-token-file)
      GITHUB_TOKEN_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script with sudo or as root." >&2
  exit 1
fi

if [[ -z "${REPO_URL}" ]]; then
  echo "--repo is required." >&2
  usage
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  echo "Cannot detect operating system." >&2
  exit 1
fi

source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "This bootstrap script currently supports Ubuntu only." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
  ansible \
  ca-certificates \
  curl \
  git \
  python3 \
  python3-apt

install -d -m 0755 /etc/ansible "${DEST}" "${LOG_DIR}"

if [[ -n "${GITHUB_TOKEN}" && -n "${GITHUB_TOKEN_FILE}" ]]; then
  echo "Use either --github-token or --github-token-file, not both." >&2
  exit 1
fi

if [[ -n "${GITHUB_TOKEN_FILE}" ]]; then
  if [[ ! -f "${GITHUB_TOKEN_FILE}" ]]; then
    echo "Token file does not exist: ${GITHUB_TOKEN_FILE}" >&2
    exit 1
  fi
  GITHUB_TOKEN="$(tr -d '\r\n' < "${GITHUB_TOKEN_FILE}")"
fi

if [[ -n "${GITHUB_USER}" || -n "${GITHUB_TOKEN}" ]]; then
  if [[ -z "${GITHUB_USER}" || -z "${GITHUB_TOKEN}" ]]; then
    echo "--github-user and a token source must be provided together." >&2
    exit 1
  fi

  cat > /root/.git-credentials-ansible-pull <<EOF
https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com
EOF
  chmod 0600 /root/.git-credentials-ansible-pull
  git config --global credential.helper "store --file /root/.git-credentials-ansible-pull"
fi

cat > /etc/ansible/pull.env <<EOF
REPO_URL=${REPO_URL}
BRANCH=${BRANCH}
PLAYBOOK=${PLAYBOOK}
DEST=${DEST}
LOG_DIR=${LOG_DIR}
EOF

if [[ -d "${DEST}/.git" ]]; then
  git -C "${DEST}" fetch origin "${BRANCH}"
  git -C "${DEST}" checkout "${BRANCH}"
  git -C "${DEST}" reset --hard "origin/${BRANCH}"
else
  rm -rf "${DEST}"
  git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${DEST}"
fi

if [[ ! -f "${DEST}/scripts/run-ansible-pull.sh" ]]; then
  echo "Missing ${DEST}/scripts/run-ansible-pull.sh after initial clone." >&2
  exit 1
fi

install -m 0755 "${DEST}/scripts/run-ansible-pull.sh" /usr/local/sbin/run-ansible-pull

echo "--- Initial Workstation Config ---"
while true; do
  read -p "Enter short hostname (max 15 chars, without .hhmi.org): " SHORT_HOSTNAME
  if [[ ${#SHORT_HOSTNAME} -gt 15 ]]; then
    echo "Error: Hostname exceeds 15 characters. Please try again."
  elif [[ -z "${SHORT_HOSTNAME}" ]]; then
    echo "Error: Hostname cannot be empty."
  else
    break
  fi
done

while true; do
  read -p "Machine type (laptop/desktop): " MACHINE_TYPE
  if [[ "${MACHINE_TYPE}" == "laptop" || "${MACHINE_TYPE}" == "desktop" ]]; then
    break
  else
    echo "Error: Please enter either 'laptop' or 'desktop'."
  fi
done

read -p "Join AD domain hhmi.org now? (y/n): " DO_JOIN
AD_USER=""
AD_PASSWORD=""
if [[ "${DO_JOIN}" =~ ^[Yy]$ ]]; then
  read -p "AD Admin Username (e.g. duckd-a): " AD_USER
  read -s -p "AD Admin Password: " AD_PASSWORD
  echo ""
fi

# Ensure extra-vars is quoted securely since it contains passwords
EXTRA_VARS="{ \"target_hostname\": \"${SHORT_HOSTNAME}\", \"machine_type\": \"${MACHINE_TYPE}\""
if [[ -n "${AD_USER}" ]]; then
  EXTRA_VARS="${EXTRA_VARS}, \"ad_join_user\": \"${AD_USER}\", \"ad_join_password\": \"${AD_PASSWORD}\""
fi
EXTRA_VARS="${EXTRA_VARS} }"

/usr/local/sbin/run-ansible-pull --extra-vars "${EXTRA_VARS}"

systemctl enable --now ansible-pull.timer || true

if [[ "${DO_JOIN}" =~ ^[Yy]$ ]]; then
  echo ""
  echo "******************************************************************"
  echo "WARNING: The machine has been joined to AD (hhmi.org)."
  echo "A system reboot is REQUIRED before graphical logins will work."
  echo "Please reboot your machine when ready: sudo reboot"
  echo "******************************************************************"
fi
