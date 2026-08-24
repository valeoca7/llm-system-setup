SHELL := /bin/bash

LAB_SCRIPTS := \
	00-check-host.sh \
	01-install-prerequisites.sh \
	02-install-ollama.sh \
	03-pull-models.sh \
	04-create-python-environment.sh \
	05-smoke-test.sh \
	06-run-assistant.sh

STOP_SCRIPT := 99-stop-lab.sh

.PHONY: run stop

run:
	@set -euo pipefail; \
	for script in $(LAB_SCRIPTS); do \
		printf '\n==> Starting: %s\n' "$$script"; \
		bash "$$script"; \
	done

stop:
	@printf '==> Stopping Local RAG Assistant and Ollama\n'
	@bash "$(STOP_SCRIPT)"
