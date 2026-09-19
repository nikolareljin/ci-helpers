# `command -v bash` comes back empty when bash is not on PATH, and Make then
# silently falls back to /bin/sh, where every [[ ... ]] in these recipes breaks.
# Fall back to /bin/bash explicitly: on macOS that is bash 3.2, which this
# library supports, so the recipes still run.
BASH_BIN := $(shell command -v bash 2>/dev/null)
SHELL := $(if $(BASH_BIN),$(BASH_BIN),/bin/bash)

.PHONY: help examples example_logging example_env example_json example_dialog_input example_download example_docker example_package_publish lint-docs install-git-hooks test test-bash32 docs-deps docs-serve docs-build docs-preview docs-check docs-clean

help:
	@echo "Available targets:"
	@echo "  make examples                 # Run safe, non-interactive examples"
	@echo "  make examples RUN_NETWORK=1   # Include download example (network)"
	@echo "  make examples RUN_INTERACTIVE=1  # Include interactive dialog example"
	@echo "  make lint-docs                # Verify docs cover modules and functions"
	@echo "  make test                     # Run tests under tests/"
	@echo "  make test-bash32              # Run tests under bash 3.2 (macOS's shell)"
	@echo "  make install-git-hooks        # Install pre-commit hook to run lint-docs"
	@echo "  make example_<name>           # Run a specific example"
	@echo ""
	@echo "  make docs-serve               # Docs site with live reload (while writing)"
	@echo "  make docs-preview             # Build, then serve ./site over HTTP (what ships)"
	@echo "  make docs-build               # mkdocs build --strict into ./site"
	@echo "  make docs-check               # Build --strict to a temp dir; no server (CI/hooks)"
	@echo "  make docs-deps                # Create the docs virtualenv only"
	@echo "  make docs-clean               # Remove ./site and the docs virtualenv"
	@echo ""
	@echo "  lint-docs checks that every module is documented."
	@echo "  docs-check builds the site those docs render into. Both, before a PR."

# Defaults: avoid network and interactive prompts
RUN_NETWORK ?= 0
RUN_INTERACTIVE ?= 0

examples: example_logging example_env example_json example_docker example_package_publish
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

example_package_publish:
	@echo "\n--- Running: example_package_publish ---"
	@bash scripts/example_package_publish.sh

lint-docs:
	@bash scripts/lint_docs.sh
	@# The changelog header is load-bearing: ci-helpers extracts release notes
	@# by finding it, and silently falls back to an auto-generated commit list
	@# when the shape is wrong. This repository shipped the checker and never
	@# ran it, so its own headers had drifted for twenty releases.
	@bash -c 'source helpers.sh && shlib_import logging changelog && changelog_check_header CHANGELOG.md'
	@# And that the version being released actually has a section. The header
	@# check only looks at the newest one; a release branch whose version was
	@# never written up still passed it, and the release body then fell back to
	@# a commit list. Off a release branch this is a no-op.
	@bash scripts/check_changelog_section.sh

test-bash32:
	@bash scripts/local_test_bash32.sh

test:
	@for f in tests/*_test.sh; do \
	  [[ -f "$$f" ]] || continue; \
	  printf '\n--- Running: %s ---\n' "$$f"; \
	  bash "$$f" || exit 1; \
	done

install-git-hooks:
	@mkdir -p .git/hooks
	@chmod +x scripts/git-hooks/pre-commit
	@ln -sf ../../scripts/git-hooks/pre-commit .git/hooks/pre-commit 2>/dev/null || cp scripts/git-hooks/pre-commit .git/hooks/pre-commit
	@echo "Installed pre-commit hook: docs linter"

# Documentation site. Built from docs/ in place -- there is no second copy of
# the content anywhere. See scripts/docs_site.sh for why preview and serve are
# different things.
docs-deps:
	@bash scripts/docs_site.sh deps

docs-serve:
	@bash scripts/docs_site.sh serve

docs-build:
	@bash scripts/docs_site.sh build

docs-preview:
	@bash scripts/docs_site.sh preview

docs-check:
	@bash scripts/docs_site.sh check

docs-clean:
	@bash scripts/docs_site.sh clean
