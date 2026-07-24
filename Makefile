VENV ?= .venv
ACTIVATE = . $(VENV)/bin/activate

.PHONY: setup doctor guard-venv lint unit-test test integration local-integration clean-venv

guard-venv:
	@test -f $(VENV)/bin/activate || (echo "Missing $(VENV). Run ./scripts/setup-dev.sh first." >&2; exit 1)

setup:
	./scripts/setup-dev.sh

doctor:
	./scripts/doctor.sh

lint: guard-venv
	$(ACTIVATE) && PRE_COMMIT_HOME=.pre-commit-cache pre-commit run --all-files

unit-test: guard-venv
	$(ACTIVATE) && python -m pytest -q tests/test_*.py

test:
	$(MAKE) lint
	$(MAKE) unit-test

integration: guard-venv
	$(ACTIVATE) && sudo -E env "PATH=$$PATH" python -m pytest -q tests/integration

# Run the CI integration job locally in disposable Ubuntu 22.04 + 24.04
# Multipass KVM VMs. Requires `multipass` on the host (sudo snap install
# multipass). Pass MP_TARGET=22.04 (or 24.04) to run a single release.
local-integration:
	MP_TARGET="$(MP_TARGET)" ./scripts/local-ci.sh

clean-venv:
	rm -rf $(VENV)
