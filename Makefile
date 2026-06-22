# Convenience targets. Run `make help` for the list.

.PHONY: help build setup up down logs ps stats snapshots check restore unlock shell

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

stats: ## restic repository statistics
	./scripts/admin.sh stats

snapshots: ## List restic snapshots
	./scripts/admin.sh snapshots

check: ## restic integrity check
	./scripts/admin.sh check

unlock: ## Remove stale restic locks
	./scripts/admin.sh unlock

restore: ## Restore: make restore SNAP=<id> SUB=<subpath>
	./scripts/admin.sh restore $(SNAP) $(SUB)

shell: ## Open a shell in a throwaway container of the image
	docker run --rm -it --entrypoint /bin/bash onedrive-nas:latest
