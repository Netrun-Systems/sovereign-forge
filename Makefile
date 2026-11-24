# sovereign-forge: one command per job. `make help` lists them.
# The logic lives in scripts/forgectl.sh so it can be read and tested as plain bash.
#
#   make aws              provision on AWS Lightsail + S3, then verify
#   make azure            provision on an Azure VM + Blob, then verify
#   make local            Forgejo + runner on this machine with Docker Compose
#   make backup           run a backup now (FORGE_SSH=user@host for a cloud host)
#   make restore-drill    pull the latest backup, decrypt, verify, list repositories
#   make destroy CLOUD=aws|azure|local
#
# Terraform asks for confirmation before it applies unless you pass AUTO_APPROVE=1.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

CLOUD        ?=
AGE_IDENTITY ?=
BACKUP_ENV   ?= backup.env
DRILL_TIER   ?= daily

.PHONY: help aws azure local backup restore-drill destroy validate lint

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

aws: ## Provision on AWS (Lightsail + S3) and verify
	./scripts/forgectl.sh deploy aws

azure: ## Provision on Azure (VM + Blob) and verify
	./scripts/forgectl.sh deploy azure

local: ## Run the forge on this machine with Docker Compose (no TLS)
	./scripts/forgectl.sh local

backup: ## Run a backup now. FORGE_SSH=user@host runs it on the cloud host
	./scripts/forgectl.sh backup

restore-drill: ## Pull latest backup, decrypt, verify tar + dump, list repos. Needs AGE_IDENTITY=path
	@test -n "$(AGE_IDENTITY)" || { echo "set AGE_IDENTITY=/path/to/identity.txt (the age PRIVATE key, kept off the host)"; exit 1; }
	./scripts/restore.sh --identity "$(AGE_IDENTITY)" --env-file "$(BACKUP_ENV)" --tier "$(DRILL_TIER)" --list

destroy: ## Tear down. CLOUD=aws|azure|local (asks you to type the host name first)
	@test -n "$(CLOUD)" || { echo "usage: make destroy CLOUD=aws|azure|local"; exit 1; }
	./scripts/forgectl.sh destroy $(CLOUD)

validate: ## terraform fmt + validate for both clouds (no credentials needed)
	terraform fmt -check -recursive terraform
	for d in aws azure; do terraform -chdir=terraform/$$d init -backend=false -input=false >/dev/null && terraform -chdir=terraform/$$d validate || exit 1; done

lint: ## bash -n, shellcheck, and the no-secrets tripwire
	for f in scripts/*.sh cloud-init/bootstrap.sh; do bash -n "$$f" || exit 1; done
	./scripts/check-no-secrets.sh
	if command -v shellcheck >/dev/null; then shellcheck -x scripts/*.sh cloud-init/bootstrap.sh; else echo "shellcheck not installed; only bash -n ran"; fi
