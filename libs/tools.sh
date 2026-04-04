#!/usr/bin/env bash

LOG_LEVEL="${LOG_LEVEL:-INFO}"

tools::normalize_log_level() {
  case "$(printf '%s' "${1:-INFO}" | tr '[:lower:]' '[:upper:]')" in
    DEBUG)
      printf 'DEBUG'
      ;;
    INFO)
      printf 'INFO'
      ;;
    WARN|WARNING)
      printf 'WARN'
      ;;
    ERROR)
      printf 'ERROR'
      ;;
    *)
      printf 'INFO'
      ;;
  esac
}

tools::log_level_value() {
  case "$(tools::normalize_log_level "$1")" in
    DEBUG)
      printf '10'
      ;;
    INFO)
      printf '20'
      ;;
    WARN)
      printf '30'
      ;;
    ERROR)
      printf '40'
      ;;
  esac
}

tools::check_requirements() {
  local missing=0
  local cmd
  local required_commands=("$@")

  if [ "${#required_commands[@]}" -eq 0 ]; then
    required_commands=(mosquitto_pub mosquitto_sub jq)
  fi

  for cmd in "${required_commands[@]}"; do
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
  local level current_level_value message_level_value msg ts

  level="$(tools::normalize_log_level "${1:-INFO}")"
  shift || true
  msg="$*"

  current_level_value="$(tools::log_level_value "${LOG_LEVEL:-INFO}")"
  message_level_value="$(tools::log_level_value "$level")"
  if [ "$message_level_value" -lt "$current_level_value" ]; then
    return
  fi

  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" >&2
}

tools::sanitize_hostname() {
  printf '%s' "$1" | sed -E 's/[[:space:]]+/_/g; s/[^A-Za-z0-9._-]/_/g'
}