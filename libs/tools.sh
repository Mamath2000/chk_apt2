#!/usr/bin/env bash

tools::check_requirements() {
  local missing=0
  local cmd

  for cmd in mosquitto_pub mosquitto_sub jq apt-get apt git systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Erreur: la commande '$cmd' est requise. Installez les dépendances système nécessaires." >&2
      missing=1
    fi
  done

  if [ "$missing" -ne 0 ]; then
    exit 1
  fi
}

tools::require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit être exécuté en root (sudo)." >&2
    exit 1
  fi
}

tools::log() {
  local level="${1:-INFO}"; shift || true
  local msg="$*"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '%s [%s] %s\n' "$ts" "$level" "$msg"
}

tools::sanitize_hostname() {
  printf '%s' "$1" | sed -E 's/[[:space:]]+/_/g; s/[^A-Za-z0-9._-]/_/g'
}