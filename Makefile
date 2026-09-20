SHELL := /bin/bash
ENV_FILE ?= .env
COMPOSE := docker compose --env-file $(ENV_FILE)

.DEFAULT_GOAL := help

.PHONY: help env secrets config up down restart ps logs dev-up backup db-backup

help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

env: ## Create $(ENV_FILE) from .env.example if it does not exist
	@if [ ! -f "$(ENV_FILE)" ]; then cp .env.example "$(ENV_FILE)" && echo "created $(ENV_FILE) — now run: make secrets"; else echo "$(ENV_FILE) already exists"; fi

secrets: ## Generate secrets, keys, htpasswd and runtime directories
	./scripts/gen-secrets.sh $(ENV_FILE)

config: ## Validate the rendered Compose configuration
	@$(COMPOSE) config --quiet && echo "compose config OK"

up: ## Start the stack
	$(COMPOSE) up -d

down: ## Stop the stack
	$(COMPOSE) down

restart: ## Restart the stack
	$(COMPOSE) restart

ps: ## Show container status
	$(COMPOSE) ps

logs: ## Follow logs (tail 100)
	$(COMPOSE) logs -f --tail=100

dev-up: ## Enable loopback ingress (127.0.0.1:8080) and start the stack
	@test -f docker-compose.override.yml || cp docker-compose.override.yml.example docker-compose.override.yml
	$(COMPOSE) up -d

backup: ## Archive the runtime data directory into ./backups
	@mkdir -p backups
	@data_dir="$$(grep '^HARBOR_DATA_DIR=' $(ENV_FILE) | cut -d= -f2-)"; \
	case "$$data_dir" in /*) ;; *) data_dir="$$PWD/$${data_dir#./}" ;; esac; \
	docker run --rm -v "$$data_dir:/data:ro" -v "$$PWD/backups:/backup" alpine:3 \
		tar -czf "/backup/harbor-$$(date +%Y%m%d-%H%M%S).tar.gz" -C /data .
	@echo "backup written to ./backups"

db-backup: ## Dump the Harbor database into ./backups (consistent SQL dump)
	@mkdir -p backups
	$(COMPOSE) exec -T harbor-db sh -c 'pg_dump -U "$$POSTGRES_USER" "$$POSTGRES_DB"' \
		> "backups/harbor-db-$$(date +%Y%m%d-%H%M%S).sql"
	@echo "database dump written to ./backups"
