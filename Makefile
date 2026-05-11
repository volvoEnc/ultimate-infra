SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

APP ?=
ENV ?=

.PHONY: help up-gateway up-postgres up-registry up-observability up-admin up-uptime up-centrifugo up-n8n import-n8n-workflows deploy logs status init-server

help:
	@printf '%s\n' \
	  'Available targets:' \
	  '  make up-gateway' \
	  '  make up-postgres' \
	  '  make up-registry' \
	  '  make up-observability' \
	  '  make up-admin' \
	  '  make up-uptime' \
	  '  make up-centrifugo' \
	  '  make up-n8n' \
	  '  make import-n8n-workflows' \
	  '  make deploy APP=app1 ENV=prod' \
	  '  make logs APP=app1 ENV=prod' \
	  '  make status' \
	  '  make init-server'

up-gateway:
	./scripts/create-network.sh proxy
	./scripts/create-network.sh data
	cd gateway && docker compose --env-file .env up -d

up-postgres:
	./scripts/create-network.sh data
	./scripts/create-network.sh proxy
	cd postgres && docker compose --env-file .env up -d --remove-orphans

up-registry:
	./scripts/create-network.sh proxy
	cd registry && docker compose --env-file .env up -d

up-observability:
	./scripts/create-network.sh proxy
	./scripts/create-network.sh data
	cd observability && docker compose --env-file .env up -d

up-admin:
	./scripts/create-network.sh proxy
	./scripts/create-network.sh data
	cd admin && docker compose --env-file .env up -d

up-uptime:
	./scripts/create-network.sh proxy
	./scripts/create-network.sh data
	cd uptime && docker compose --env-file .env up -d

up-centrifugo:
	./scripts/create-network.sh proxy
	./scripts/create-network.sh data
	cd centrifugo && docker compose --env-file .env up -d --remove-orphans

up-n8n:
	./scripts/create-network.sh proxy
	./scripts/create-network.sh data
	cd n8n && docker compose --env-file .env up -d --remove-orphans

import-n8n-workflows:
	./scripts/import-n8n-workflows.sh

deploy:
	@test -n "$(APP)" && test -n "$(ENV)" || (echo 'Usage: make deploy APP=<name> ENV=<prod|stage>' >&2; exit 1)
	./scripts/deploy.sh "$(APP)" "$(ENV)"

logs:
	@test -n "$(APP)" && test -n "$(ENV)" || (echo 'Usage: make logs APP=<name> ENV=<prod|stage>' >&2; exit 1)
	./scripts/logs.sh "$(APP)" "$(ENV)"

status:
	docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

init-server:
	./scripts/init-server.sh
