# Convenience targets. Run `make help` for the list.

.PHONY: help build setup up down logs ps shell ui

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build the container image
	docker compose build

setup: ## One-time interactive OneDrive authorization
	./scripts/setup-rclone.sh

up: ## Start the backup service (detached)
	docker compose up -d

down: ## Stop the backup service
	docker compose down

logs: ## Follow logs
	docker compose logs -f

ps: ## Show service status
	docker compose ps

shell: ## Open a shell in a throwaway container of the mirror image
	docker run --rm -it --entrypoint /bin/bash onedrive-nas:latest

ui: ## Print the Backrest URL (snapshots/restore/stats/check/prune all live there)
	@echo "Backrest UI: http://localhost:9898 (or http://<pi-ip>:9898)"
