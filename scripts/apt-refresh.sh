#!/usr/bin/env bash
set -euo pipefail

# Ensure apt operations run non-interactively under timers/services.
export DEBIAN_FRONTEND=noninteractive

# Refresh package metadata. DPkg::Lock::Timeout waits up to 10 minutes for a
# competing apt consumer to release the lock; Acquire::Retries retries a
# transient fetch blip so a single momentary DNS/mirror hiccup self-heals within
# the run. APT::Update::Error-Mode=any makes apt-get exit non-zero when ANY
# source fails to refresh -- by default it exits 0 even when every index fetch
# fails, which would let metadata silently age while the unit's OnFailure Slack
# alert never fires.
main() {
  apt-get update \
    -o DPkg::Lock::Timeout=600 \
    -o Acquire::Retries=3 \
    -o APT::Update::Error-Mode=any
}

main "$@"
