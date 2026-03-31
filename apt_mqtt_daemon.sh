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
BASE_TOPIC="${MQTT_BASE_TOPIC:-home/apt}"
OBJECT_ID="${OBJECT_ID:-apt_update}"
CHECK_INTERVAL="${CHECK_INTERVAL:-3600}"
CLIENT_ID="${MQTT_CLIENT_ID:-apt_mqtt_$(hostname -s)}"

HOSTNAME="$(hostname -s)"

# Ensure BASE_TOPIC has no trailing slash
BASE_TOPIC="${BASE_TOPIC%/}"

# Build per-host topic prefix. If BASE_TOPIC already contains the hostname, use it as-is,
# otherwise append the hostname so each server publishes on its own subtree.
if [[ "$BASE_TOPIC" == *"$HOSTNAME"* ]]; then
  TOPIC_PREFIX="$BASE_TOPIC"
else
  TOPIC_PREFIX="${BASE_TOPIC}/${HOSTNAME}"
fi

STATE_TOPIC="$TOPIC_PREFIX/state"
ATTR_TOPIC="$TOPIC_PREFIX/attributes"
CMD_TOPIC="$TOPIC_PREFIX/command"
AVAIL_TOPIC="$TOPIC_PREFIX/availability"

# check required commands
MISSING=0
for cmd in mosquitto_pub mosquitto_sub jq apt-get apt; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Erreur: la commande '$cmd' est requise. Installez 'mosquitto-clients' et 'jq'." >&2
    MISSING=1
  fi
done
if [ "$MISSING" -ne 0 ]; then
  exit 1
fi

in_progress="false"
CMD_FIFO=""
MOSQ_PID=""
LOOP_PID=""

mqtt_pub() {
  local topic="$1" payload="$2" retain="${3:-false}"
  local args=( -h "$BROKER" -p "$PORT" )
  if [ -n "$USERNAME" ]; then args+=( -u "$USERNAME" -P "$PASSWORD" ); fi
  if [ "$retain" = true ]; then args+=( -r ); fi
  mosquitto_pub "${args[@]}" -t "$topic" -m "$payload"
}

publish_discovery() {
  update_json=$(jq -n \
    --arg name "APT Packages ($HOSTNAME)" \
    --arg state_topic "$STATE_TOPIC" \
    --arg json_attributes_topic "$ATTR_TOPIC" \
    --arg availability_topic "$AVAIL_TOPIC" \
    --arg unique_id "${OBJECT_ID}_$HOSTNAME" \
    --arg device_id "apt_$HOSTNAME" \
    --arg device_name "APT $HOSTNAME" \
    --arg model "apt-mqtt-updater" \
    --arg manufacturer "custom" \
    '{name:$name, state_topic:$state_topic, json_attributes_topic:$json_attributes_topic, availability_topic:$availability_topic, unique_id:$unique_id, device:{identifiers:[$device_id], name:$device_name, model:$model, manufacturer:$manufacturer}}')

  button_json=$(jq -n \
    --arg name "APT Installer les mises à jour ($HOSTNAME)" \
    --arg command_topic "$CMD_TOPIC" \
    --arg payload_press "install" \
    --arg unique_id "${OBJECT_ID}_install_$HOSTNAME" \
    --arg device_id "apt_$HOSTNAME" \
    --arg device_name "APT $HOSTNAME" \
    '{name:$name, command_topic:$command_topic, payload_press:$payload_press, unique_id:$unique_id, device:{identifiers:[$device_id], name:$device_name}}')

  mqtt_pub "homeassistant/update/$OBJECT_ID/config" "$update_json" true
  mqtt_pub "homeassistant/button/${OBJECT_ID}_install/config" "$button_json" true
}

check_upgrades() {
  local out
  out=$(apt list --upgradable 2>/dev/null || true)
  out="$(echo "$out" | sed '1d')"
  if [ -z "$(echo "$out" | tr -d '[:space:]')" ]; then
    printf '[]'
    return
  fi
  printf '['
  first=true
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    pkg=$(printf '%s' "$line" | cut -d'/' -f1)
    candidate=$(printf '%s' "$line" | awk '{print $2}')
    installed=""
    if printf '%s' "$line" | grep -q 'upgradable from:'; then
      installed=$(printf '%s' "$line" | sed -n 's/.*upgradable from: \([^]]*\).*/\1/p')
    fi
    # escape
    pkg_esc=$(printf '%s' "$pkg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    inst_esc=$(printf '%s' "$installed" | sed 's/\\/\\\\/g; s/"/\\"/g')
    cand_esc=$(printf '%s' "$candidate" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if [ "$first" = true ]; then first=false; else printf ','; fi
    printf '{"name":"%s","installed":"%s","candidate":"%s"}' "$pkg_esc" "$inst_esc" "$cand_esc"
  done <<< "$out"
  printf ']'
}

publish_status() {
  local pkgs last_check attrs
  pkgs=$(check_upgrades)
  if [ "$pkgs" = '[]' ]; then state="off"; else state="on"; fi
  last_check=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # in_progress is the string "true" or "false"; convert to boolean in jq
  attrs=$(jq -n --argjson packages "$pkgs" --arg last_check "$last_check" --arg in_progress "$in_progress" '{count: ($packages|length), packages: $packages, last_check: $last_check, in_progress: ($in_progress == "true")}')
  mqtt_pub "$STATE_TOPIC" "$state" true
  mqtt_pub "$ATTR_TOPIC" "$attrs" true
  echo "Published status: $state (count=$(echo "$attrs" | jq .count))"
}

handle_install() {
  local dry="$1" result rc last_run last_result
  if [ "$in_progress" = "true" ]; then
    echo "Une mise à jour est déjà en cours"
    return
  fi
  in_progress="true"
  publish_status
  echo "Lancement apt-get update..."
  apt-get update >/dev/null 2>&1 || true
  if [ "$dry" = "true" ]; then
    result=$(apt-get -s upgrade 2>&1 || true)
    rc=0
  else
    result=$(apt-get -y upgrade 2>&1 || true)
    rc=$?
  fi
  last_run=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  last_result=$(printf '%s' "$result" | head -c20000)
  attrs=$(jq -n --argjson packages "$(check_upgrades)" --arg last_run "$last_run" --arg last_result "$last_result" --arg last_result_code "$rc" '{count: ($packages|length), packages: $packages, last_run: $last_run, last_result_code: ($last_result_code|tonumber), last_result: $last_result, in_progress: false}')
  mqtt_pub "$ATTR_TOPIC" "$attrs" true
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
  publish_discovery
  mqtt_pub "$AVAIL_TOPIC" "online" true

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
    sleep "$CHECK_INTERVAL"
  done
}

main
