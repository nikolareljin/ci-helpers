SHELL := /bin/bash

.PHONY: help examples example_logging example_env example_json example_dialog_input example_download example_docker lint-docs install-git-hooks

help:
	@echo "Available targets:"
	@echo "  make examples                 # Run safe, non-interactive examples"
	@echo "  make examples RUN_NETWORK=1   # Include download example (network)"
	@echo "  make examples RUN_INTERACTIVE=1  # Include interactive dialog example"
	@echo "  make lint-docs                # Verify docs cover modules and functions"
	@echo "  make install-git-hooks        # Install pre-commit hook to run lint-docs"
	@echo "  make example_<name>           # Run a specific example"

# Defaults: avoid network and interactive prompts
RUN_NETWORK ?= 0
RUN_INTERACTIVE ?= 0

examples: example_logging example_env example_json example_docker
	@# Interactive dialog example (opt-in)
	@if [[ "$(RUN_INTERACTIVE)" == "1" ]]; then \
	  if command -v dialog >/dev/null 2>&1; then \
	    echo "\n--- Running interactive: example_dialog_input ---"; \
	    bash scripts/example_dialog_input.sh; \
	  else \
	    echo "dialog not installed; skipping interactive example"; \
	  fi; \
	else \
	  echo "Skipping interactive examples (set RUN_INTERACTIVE=1 to enable)"; \
	fi
	@# Network download example (opt-in)
	@if [[ "$(RUN_NETWORK)" == "1" ]]; then \
	  echo "\n--- Running: example_download ---"; \
	  bash scripts/example_download.sh; \
	else \
	  echo "Skipping network download (set RUN_NETWORK=1 to enable)"; \
	fi

example_logging:
	@echo "\n--- Running: example_logging ---"
	@bash scripts/example_logging.sh

example_env:
	@echo "\n--- Running: example_env ---"
	@bash scripts/example_env.sh

example_json:
	@echo "\n--- Running: example_json ---"
	@bash scripts/example_json.sh

example_dialog_input:
	@echo "\n--- Running: example_dialog_input ---"
	@bash scripts/example_dialog_input.sh

example_download:
	@echo "\n--- Running: example_download ---"
	@bash scripts/example_download.sh

example_docker:
	@echo "\n--- Running: example_docker_compose_cmd ---"
	@if command -v docker >/dev/null 2>&1; then \
	  bash scripts/example_docker_compose_cmd.sh; \
	  echo "\n--- Running: example_docker_status ---"; \
	  bash scripts/example_docker_status.sh || true; \
	else \
	  echo "Docker not found; skipping docker example"; \
	fi

lint-docs:
	@bash scripts/lint_docs.sh

install-git-hooks:
	@mkdir -p .git/hooks
	@chmod +x scripts/git-hooks/pre-commit
	@ln -sf ../../scripts/git-hooks/pre-commit .git/hooks/pre-commit 2>/dev/null || cp scripts/git-hooks/pre-commit .git/hooks/pre-commit
	@echo "Installed pre-commit hook: docs linter"
