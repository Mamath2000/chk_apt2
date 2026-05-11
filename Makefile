SHELL        := /usr/bin/env bash
INSTALL      := ./install_service.sh
CONFIG       ?=

# Argument --config optionnel
_CONFIG_ARG  := $(if $(CONFIG),--config $(CONFIG),)

.PHONY: help install install-apt install-docker \
        remove remove-apt remove-docker \
        status status-apt status-docker \
        status-follow status-apt-follow status-docker-follow

help: ## Affiche cette aide
	@awk 'BEGIN{FS=":.*##"; printf "\nUsage:\n  make \033[36m<cible>\033[0m\n\nCibles:\n"} \
	     /^[a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ── Installation ────────────────────────────────────────────────────────────

install: install-apt install-docker ## Installe les deux services (APT + Docker)

install-apt: ## Installe apt-mqtt.service
	sudo $(INSTALL) install $(_CONFIG_ARG)

install-docker: ## Installe docker-mqtt.service
	sudo $(INSTALL) install --docker $(_CONFIG_ARG)

# ── Suppression ─────────────────────────────────────────────────────────────

remove: remove-apt remove-docker ## Supprime les deux services

remove-apt: ## Supprime apt-mqtt.service
	sudo $(INSTALL) remove

remove-docker: ## Supprime docker-mqtt.service
	sudo $(INSTALL) remove --docker

# ── Statut ──────────────────────────────────────────────────────────────────

status: status-apt status-docker ## Affiche le statut des deux services

status-apt: ## Statut de apt-mqtt.service
	sudo $(INSTALL) status

status-docker: ## Statut de docker-mqtt.service
	sudo $(INSTALL) status --docker

status-follow: ## Suit les logs en temps réel (les deux services)
	sudo $(INSTALL) status -f & sudo $(INSTALL) status --docker -f

status-apt-follow: ## Suit les logs de apt-mqtt.service en temps réel
	sudo $(INSTALL) status -f

status-docker-follow: ## Suit les logs de docker-mqtt.service en temps réel
	sudo $(INSTALL) status --docker -f
