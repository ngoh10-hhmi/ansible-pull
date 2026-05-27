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
	PRE_COMMIT_HOME=.pre-commit-cache $(ACTIVATE) && pre-commit run --all-files

unit-test: guard-venv
	$(ACTIVATE) && python -m pytest -q tests/test_*.py

test:
	$(MAKE) lint
	$(MAKE) unit-test

integration: guard-venv
	$(ACTIVATE) && sudo -E env "PATH=$$PATH" python -m pytest -q tests/integration

# Run the CI integration job locally in disposable Ubuntu 22.04 + 24.04
# libvirt VMs. Requires `vagrant` and `vagrant-libvirt` on the host.
# Pass VAGRANT_TARGET=ubuntu-22.04 (or 24.04) to run a single platform.
local-integration:
	vagrant up --provision $(VAGRANT_TARGET)

clean-venv:
	rm -rf $(VENV)
