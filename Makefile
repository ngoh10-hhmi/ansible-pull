PYTHON ?= python3.11
VENV ?= .venv
ACTIVATE = . $(VENV)/bin/activate

.PHONY: setup lint test integration clean-venv

setup:
	./scripts/setup-dev.sh

lint:
	PRE_COMMIT_HOME=.pre-commit-cache $(ACTIVATE) && pre-commit run --all-files

test:
	$(MAKE) lint

integration:
	$(ACTIVATE) && sudo -E env "PATH=$$PATH" python -m pytest -q tests/integration

clean-venv:
	rm -rf $(VENV)
