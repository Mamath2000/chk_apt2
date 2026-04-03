#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/libs/mqtt.sh"
source "$SCRIPT_DIR/libs/tools.sh"
source "$SCRIPT_DIR/libs/config.sh"
source "$SCRIPT_DIR/libs/apt.sh"
source "$SCRIPT_DIR/libs/git.sh"
source "$SCRIPT_DIR/libs/state.sh"
source "$SCRIPT_DIR/libs/version.sh"


usage() {
  cat <<'EOF'
Usage: apt_mqtt_daemon.sh

Ce script ne prend plus d'options en ligne de commande.
Configurez les paramètres dans un fichier de configuration (shell-compatible) :
  /etc/apt_mqtt/config.conf
  $HOME/.config/apt_mqtt/config.conf
  <repo>/config.conf

Exécutez simplement :
  sudo ./apt_mqtt_daemon.sh
EOF
}


# Vérification root en tout début de script
tools::require_root

config::load "$SCRIPT_DIR"

# Autoremove remains configurable only in this script.
AUTOREMOVE=false

state::init_paths "$SCRIPT_DIR"
version::init_paths "$SCRIPT_DIR"

tools::check_requirements

# Logs de démarrage
tools::log INFO "Démarrage du démon APT MQTT"
tools::log INFO "Script dir: $SCRIPT_DIR"
tools::log INFO "Fichier de config: ${CONFIG_FILE:-(none)}"
tools::log INFO "MQTT broker: $BROKER:$PORT base_root_topic: $BASE_ROOT_TOPIC base_topic: $BASE_TOPIC client_id: $CLIENT_ID"
tools::log INFO "Install dir: $INSTALL_DIR service: $SERVICE_NAME"

# Log des IP détectées (via mqtt::device_ip_connections)
ip_json="$(mqtt::device_ip_connections)"
if [ "$ip_json" = '[]' ]; then
  tools::log WARN "Aucune IP détectée pour le préfixe ${MQTT_DEVICE_IP_PREFIX:-192.168.}"
else
  ip_list=$(printf '%s' "$ip_json" | jq -r '.[] | .[1]' | paste -sd', ' -)
  tools::log INFO "IP détectées: $ip_list"
fi

CMD_FIFO=""
MOSQ_PID=""
LOOP_PID=""



publish_status() {
  local pkgs last_check attrs state_payload installed_version latest_version count in_progress script_version
  pkgs=$(apt::check_upgrades)
  count=$(printf '%s' "$pkgs" | jq 'length')
  last_check=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  in_progress="$(state::is_in_progress)"
  script_version="$(version::read)"

  # Load persistent installed_version (default 1.0.0)
  installed_version="$(state::read_installed_version)"

  if [ "$count" -eq 0 ]; then
    latest_version="$installed_version"
  else
    latest_version=$(apt::bump_version "$installed_version")
  fi

  state_payload=$(jq -n --arg installed_version "$installed_version" --arg latest_version "$latest_version" --arg last_check "$last_check" --arg in_progress "$in_progress" '{installed_version:$installed_version, latest_version:$latest_version, last_check:$last_check, in_progress: ($in_progress == "true")}')
  attrs=$(jq -n --argjson packages "$pkgs" --arg last_check "$last_check" --arg in_progress "$in_progress" --arg script_version "$script_version" '{count: ($packages|length), packages: $packages, last_check: $last_check, in_progress: ($in_progress == "true"), script_version: $script_version}')
  mqtt::pub "$STATE_TOPIC" "$state_payload" true
  mqtt::pub "$ATTR_TOPIC" "$attrs" true
  mqtt::pub "$VERSION_TOPIC" "$script_version" true
  echo "Published status: installed_version=$(printf '%s' "$state_payload" | jq -r .installed_version) (count=$(printf '%s' "$attrs" | jq .count))"
}


handle_install() {
  local dry="$1" result rc last_run last_result attrs new_installed packages
  if [ "$(state::is_in_progress)" = "true" ]; then
    echo "Une mise à jour est déjà en cours"
    return
  fi
  state::mark_in_progress
  publish_status
  echo "Lancement apt-get update..."
  apt::run_update >/dev/null 2>&1 || true

  if apt::run_upgrade "$dry" "$AUTOREMOVE"; then
    rc=0
  else
    rc=$?
  fi
  result="$APT_LAST_OUTPUT"

  if [ "$dry" != "true" ] && [ "$rc" -eq 0 ]; then
    new_installed=$(apt::bump_version "$(state::read_installed_version)")
    state::write_installed_version "$new_installed"
  fi

  last_run=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  last_result=$(printf '%s' "$result" | head -c20000)
  packages=$(apt::check_upgrades)
  attrs=$(jq -n --argjson packages "$packages" --arg last_run "$last_run" --arg last_result "$last_result" --arg last_result_code "$rc" '{count: ($packages|length), packages: $packages, last_run: $last_run, last_result_code: ($last_result_code|tonumber), last_result: $last_result, in_progress: false}')
  mqtt::pub "$ATTR_TOPIC" "$attrs" true
  state::clear_in_progress
  publish_status
}


handle_self_update() {
  local result rc last_run last_result attrs script_version

  if [ "$(state::is_in_progress)" = "true" ]; then
    echo "Une opération est déjà en cours"
    return
  fi

  state::mark_in_progress
  publish_status
  echo "Lancement git pull dans $INSTALL_DIR..."

  if result="$(git::pull_repo "$INSTALL_DIR" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi

  last_run=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  last_result=$(printf '%s' "$result" | head -c20000)
  # Journaliser la sortie de git pull pour faciliter le debug (ligne par ligne)
  if [ -n "$last_result" ]; then
    while IFS= read -r _line; do
      tools::log ERROR "git pull: ${_line:- }"
    done <<< "$last_result"
  fi
  script_version="$(version::read)"
  attrs=$(jq -n --argjson packages "$(apt::check_upgrades)" --arg last_run "$last_run" --arg last_result "$last_result" --arg last_result_code "$rc" --arg script_version "$script_version" '{count: ($packages|length), packages: $packages, last_run: $last_run, last_result_code: ($last_result_code|tonumber), last_result: $last_result, in_progress: false, script_version: $script_version, last_action: "self-update"}')
  mqtt::pub "$ATTR_TOPIC" "$attrs" true
  mqtt::pub "$VERSION_TOPIC" "$script_version" true
  state::clear_in_progress
  publish_status

  if [ "$rc" -ne 0 ]; then
    echo "git pull a échoué"
    return "$rc"
  fi

  if git::service_exists "$SERVICE_NAME"; then
    echo "Redémarrage du service $SERVICE_NAME..."
    git::restart_service "$SERVICE_NAME"
  else
    echo "Service $SERVICE_NAME introuvable, redémarrage ignoré"
  fi
}


cleanup() {
  echo "Arrêt du démon..."
  if [ -n "$MOSQ_PID" ]; then kill "$MOSQ_PID" 2>/dev/null || true; fi
  if [ -n "$LOOP_PID" ]; then kill "$LOOP_PID" 2>/dev/null || true; fi
  if [ -n "$CMD_FIFO" ] && [ -p "$CMD_FIFO" ]; then rm -f "$CMD_FIFO"; fi
  state::clear_in_progress
  mqtt::pub "$AVAIL_TOPIC" "offline" true || true
}

trap 'cleanup; exit 0' SIGINT SIGTERM EXIT

main() {
  # publish discovery and set online
  mqtt::publish_main_device_discovery
  mqtt::publish_host_device_discovery
  mqtt::pub "$AVAIL_TOPIC" "online" true

  # start subscription to command topic using a FIFO so we can manage PIDs
  CMD_FIFO="$(mktemp -u /tmp/apt_mqtt_fifo.XXXXXX)"
  mkfifo "$CMD_FIFO"
  mqtt::sub_many "$CMD_TOPIC" "$GLOBAL_UPDATE_TOPIC" > "$CMD_FIFO" 2>/dev/null &
  MOSQ_PID=$!

  # read commands
  (
    while true; do
      if read -r payload <"$CMD_FIFO"; then
        payload_lc=$(printf '%s' "$payload" | tr '[:upper:]' '[:lower:]' | tr -d '\r')
        case "$payload_lc" in
          install|update|upgrade|upgrade-all)
            handle_install false &
            ;;
          dry-run|simulate)
            handle_install true &
            ;;
          self-update|update-script|update-scripts|git-pull)
            handle_self_update &
            ;;
          check|status)
            publish_status
            ;;
          *)
            echo "Commande MQTT inconnue: $payload" ;;
        esac
      fi
    done
  ) &
  LOOP_PID=$!

  # main loop: publish periodic status
  while true; do
    publish_status
    # No automatic upgrades: manual trigger via MQTT `command_topic` only.
    sleep "$CHECK_INTERVAL"
    # Après la tempo, relance le script lui-même
    tools::log INFO "Relance automatique du script après tempo ($CHECK_INTERVAL s)"
    exec "$0" "$@"
  done
}

main
