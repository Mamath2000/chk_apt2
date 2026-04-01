#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/libs/mqtt.sh"
source "$SCRIPT_DIR/libs/tools.sh"
source "$SCRIPT_DIR/libs/config.sh"
source "$SCRIPT_DIR/libs/apt.sh"
source "$SCRIPT_DIR/libs/state.sh"


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

tools::check_requirements

CMD_FIFO=""
MOSQ_PID=""
LOOP_PID=""



publish_status() {
  local pkgs last_check attrs state_payload installed_version latest_version count in_progress
  pkgs=$(apt::check_upgrades)
  count=$(printf '%s' "$pkgs" | jq 'length')
  last_check=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  in_progress="$(state::is_in_progress)"

  # Load persistent installed_version (default 1.0.0)
  installed_version="$(state::read_installed_version)"

  if [ "$count" -eq 0 ]; then
    latest_version="$installed_version"
  else
    latest_version=$(apt::bump_version "$installed_version")
  fi

  state_payload=$(jq -n --arg installed_version "$installed_version" --arg latest_version "$latest_version" --arg last_check "$last_check" --arg in_progress "$in_progress" '{installed_version:$installed_version, latest_version:$latest_version, last_check:$last_check, in_progress: ($in_progress == "true")}')
  attrs=$(jq -n --argjson packages "$pkgs" --arg last_check "$last_check" --arg in_progress "$in_progress" '{count: ($packages|length), packages: $packages, last_check: $last_check, in_progress: ($in_progress == "true")}')
  mqtt::pub "$STATE_TOPIC" "$state_payload" true
  mqtt::pub "$ATTR_TOPIC" "$attrs" true
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
  mqtt::publish_discovery
  mqtt::pub "$AVAIL_TOPIC" "online" true

  # start subscription to command topic using a FIFO so we can manage PIDs
  CMD_FIFO="$(mktemp -u /tmp/apt_mqtt_fifo.XXXXXX)"
  mkfifo "$CMD_FIFO"
  mqtt::sub "$CMD_TOPIC" > "$CMD_FIFO" 2>/dev/null &
  MOSQ_PID=$!

  # read commands
  (
    while true; do
      if read -r payload <"$CMD_FIFO"; then
        payload_lc=$(printf '%s' "$payload" | tr '[:upper:]' '[:lower:]' | tr -d '\r')
        case "$payload_lc" in
          install|update|upgrade)
            handle_install false &
            ;;
          dry-run|simulate)
            handle_install true &
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
  done
}

main
