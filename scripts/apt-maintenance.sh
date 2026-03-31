#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y dist-upgrade
apt-get -y autoremove
apt-get -y autoclean
