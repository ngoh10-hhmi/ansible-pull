PYTHON ?= python3.12
VENV ?= .venv
ACTIVATE = . $(VENV)/bin/activate

.PHONY: setup doctor guard-venv lint unit-test test integration clean-venv

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

clean-venv:
	rm -rf $(VENV)
