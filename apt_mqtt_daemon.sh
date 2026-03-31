#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: apt_mqtt_daemon.sh

Ce script ne prend plus d'options en ligne de commande.
Configurez les paramètres dans un fichier de configuration (shell-compatible) :
  /etc/apt_mqtt/config.conf
  $HOME/.config/apt_mqtt/config.conf
  <repo>/apt_mqtt/config.conf

Exécutez simplement :
  sudo ./apt_mqtt/apt_mqtt_daemon.sh
EOF
}

# Load configuration file (if present) before defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_CANDIDATES=(/etc/apt_mqtt/config.conf "$HOME/.config/apt_mqtt/config.conf" "$SCRIPT_DIR/config.conf")
for cfg in "${CONFIG_CANDIDATES[@]}"; do
  if [ -r "$cfg" ]; then
    # shellcheck disable=SC1090
    source "$cfg"
    break
  fi
done

# Defaults (can be overridden with env vars or the config file)
BROKER="${MQTT_BROKER:-localhost}"
PORT="${MQTT_PORT:-1883}"
USERNAME="${MQTT_USERNAME:-}"
PASSWORD="${MQTT_PASSWORD:-}"
BASE_TOPIC="${MQTT_BASE_TOPIC:-apt-update}"
OBJECT_ID="${OBJECT_ID:-apt_update}"
CHECK_INTERVAL="${CHECK_INTERVAL:-3600}"
# Build a safe hostname for use in MQTT client-id and topics
# Replace whitespace and unsafe characters with underscores
RAW_HOSTNAME="$(hostname -s)"
HOST_SAFENAME="$(printf '%s' "$RAW_HOSTNAME" | sed -E 's/[[:space:]]+/_/g; s/[^A-Za-z0-9._-]/_/g')"
CLIENT_ID="${MQTT_CLIENT_ID:-apt_mqtt_${HOST_SAFENAME}}"

HOSTNAME="$(hostname -s)"

# Ensure BASE_TOPIC has no trailing slash
BASE_TOPIC="${BASE_TOPIC%/}/${HOST_SAFENAME}"

STATE_TOPIC="$BASE_TOPIC/state"
ATTR_TOPIC="$BASE_TOPIC/attributes"
CMD_TOPIC="$BASE_TOPIC/command"
AVAIL_TOPIC="$BASE_TOPIC/availability"

# Hardcoded behavior (migrated from config.conf)
# Always perform a full upgrade (dist-upgrade) and assume yes (-y).
# Autoremove remains configurable only in this script.
APT_YES='-y'
AUTOREMOVE=false
# Path to this daemon (computed from script dir)
DAEMON_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
# Logfile (kept in script; systemd can be used instead)
LOGFILE="/var/log/apt_mqtt.log"

# State persistence: store installed_version so Home Assistant sees stable versions
STATE_FILE="$DAEMON_PATH/state.json"

read_state() {
  # Load installed_version from state file; default to 1.0.0
  INSTALLED_VERSION="1.0.0"
  if [ -r "$STATE_FILE" ]; then
    v=$(jq -r '.installed_version // empty' "$STATE_FILE" 2>/dev/null || true)
    if [ -n "$v" ] && [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      INSTALLED_VERSION="$v"
    fi
  else
    # try to create default state file
    echo "{\"installed_version\": \"$INSTALLED_VERSION\"}" > "$STATE_FILE" 2>/dev/null || true
  fi
}

write_state() {
  local ver="$1"
  jq -n --arg v "$ver" '{installed_version: $v}' > "$STATE_FILE" 2>/dev/null || echo "{\"installed_version\": \"$ver\"}" > "$STATE_FILE"
}

bump_version() {
  local v="$1"
  if [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
    patch=$((patch + 1))
    printf "%s.%s.%s" "$major" "$minor" "$patch"
  else
    echo "1.0.1"
  fi
}

tools::check_requirements

in_progress="false"
CMD_FIFO=""
MOSQ_PID=""
LOOP_PID=""


publish_status() {
  local pkgs last_check attrs state_payload installed_version latest_version count
  pkgs=$(tools::check_upgrades)
  count=$(printf '%s' "$pkgs" | jq 'length')
  last_check=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Load persistent installed_version (default 1.0.0)
  read_state
  installed_version="$INSTALLED_VERSION"

  if [ "$count" -eq 0 ]; then
    latest_version="$installed_version"
  else
    latest_version=$(bump_version "$installed_version")
  fi

  state_payload=$(jq -n --arg installed_version "$installed_version" --arg latest_version "$latest_version" --arg last_check "$last_check" --arg in_progress "$in_progress" '{installed_version:$installed_version, latest_version:$latest_version, last_check:$last_check, in_progress: ($in_progress == "true")}')
  attrs=$(jq -n --argjson packages "$pkgs" --arg last_check "$last_check" --arg in_progress "$in_progress" '{count: ($packages|length), packages: $packages, last_check: $last_check, in_progress: ($in_progress == "true")}')
  mqtt::pub "$STATE_TOPIC" "$state_payload" true
  mqtt::pub "$ATTR_TOPIC" "$attrs" true
  echo "Published status: installed_version=$(printf '%s' "$state_payload" | jq -r .installed_version) (count=$(printf '%s' "$attrs" | jq .count))"
}

handle_install() {
  local dry="$1" result rc last_run last_result APT_YES
  if [ "$in_progress" = "true" ]; then
    echo "Une mise à jour est déjà en cours"
    return
  fi
  in_progress="true"
  publish_status
  echo "Lancement apt-get update..."
  apt-get update >/dev/null 2>&1 || true

  if [ "$dry" = "true" ]; then
    result=$(apt-get -s dist-upgrade 2>&1 || true)
    rc=0
  else
    result=$(apt-get $APT_YES dist-upgrade 2>&1 || true)
    rc=$?
    if [ "$AUTOREMOVE" = "true" ] && [ "$rc" -eq 0 ]; then
      apt-get $APT_YES autoremove 2>&1 || true
    fi
    # On successful upgrade, increment installed_version and persist
    if [ "$rc" -eq 0 ]; then
      # reload current installed_version then bump and store
      read_state
      new_installed=$(bump_version "$INSTALLED_VERSION")
      write_state "$new_installed"
      INSTALLED_VERSION="$new_installed"
    fi
  fi

  last_run=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  last_result=$(printf '%s' "$result" | head -c20000)
  attrs=$(jq -n --argjson packages "$(tools::check_upgrades)" --arg last_run "$last_run" --arg last_result "$last_result" --arg last_result_code "$rc" '{count: ($packages|length), packages: $packages, last_run: $last_run, last_result_code: ($last_result_code|tonumber), last_result: $last_result, in_progress: false}')
  mqtt::pub "$ATTR_TOPIC" "$attrs" true
  in_progress="false"
  publish_status
}

cleanup() {
  echo "Arrêt du démon..."
  if [ -n "$MOSQ_PID" ]; then kill "$MOSQ_PID" 2>/dev/null || true; fi
  if [ -n "$LOOP_PID" ]; then kill "$LOOP_PID" 2>/dev/null || true; fi
  if [ -n "$CMD_FIFO" ] && [ -p "$CMD_FIFO" ]; then rm -f "$CMD_FIFO"; fi
  mqtt_pub "$AVAIL_TOPIC" "offline" true || true
}

trap 'cleanup; exit 0' SIGINT SIGTERM EXIT

main() {
  # publish discovery and set online
  mqtt::publish_discovery
  mqtt::pub "$AVAIL_TOPIC" "online" true

  # start subscription to command topic using a FIFO so we can manage PIDs
  CMD_FIFO="$(mktemp -u /tmp/apt_mqtt_fifo.XXXXXX)"
  mkfifo "$CMD_FIFO"
  mosquitto_sub -h "$BROKER" -p "$PORT" -t "$CMD_TOPIC" $( [ -n "$USERNAME" ] && printf '%s' "-u $USERNAME -P $PASSWORD" ) > "$CMD_FIFO" 2>/dev/null &
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
