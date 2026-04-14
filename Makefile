PYTHON ?= python3.11
VENV ?= .venv
ACTIVATE = . $(VENV)/bin/activate

.PHONY: setup doctor guard-venv lint test integration clean-venv

guard-venv:
	@test -f $(VENV)/bin/activate || (echo "Missing $(VENV). Run ./scripts/setup-dev.sh first." >&2; exit 1)

setup:
	./scripts/setup-dev.sh

doctor:
	./scripts/doctor.sh

lint: guard-venv
	PRE_COMMIT_HOME=.pre-commit-cache $(ACTIVATE) && pre-commit run --all-files

test:
	$(MAKE) lint

integration: guard-venv
	$(ACTIVATE) && sudo -E env "PATH=$$PATH" python -m pytest -q tests/integration

clean-venv:
	rm -rf $(VENV)
