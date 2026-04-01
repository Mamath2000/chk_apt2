#!/usr/bin/env bash

config::load() {
  local script_dir="$1"
  local cfg

  CONFIG_CANDIDATES=()
  if [ -n "${APT_MQTT_CONFIG:-}" ]; then
    CONFIG_CANDIDATES+=("$APT_MQTT_CONFIG")
  fi
  CONFIG_CANDIDATES+=(/etc/apt_mqtt/config.conf "$HOME/.config/apt_mqtt/config.conf" "$script_dir/config.conf")
  for cfg in "${CONFIG_CANDIDATES[@]}"; do
    if [ -r "$cfg" ]; then
      # shellcheck disable=SC1090
      source "$cfg"
      CONFIG_FILE="$cfg"
      break
    fi
  done

  BROKER="${MQTT_BROKER:-localhost}"
  PORT="${MQTT_PORT:-1883}"
  USERNAME="${MQTT_USERNAME:-}"
  PASSWORD="${MQTT_PASSWORD:-}"
  BASE_TOPIC="${MQTT_BASE_TOPIC:-apt-update}"
  BASE_ROOT_TOPIC="$BASE_TOPIC"
  OBJECT_ID="${OBJECT_ID:-apt_update}"
  CHECK_INTERVAL="${CHECK_INTERVAL:-3600}"
  INSTALL_DIR="${APT_MQTT_INSTALL_DIR:-$script_dir}"
  SERVICE_NAME="${APT_MQTT_SERVICE_NAME:-apt-mqtt.service}"

  HOSTNAME="$(hostname -s)"
  HOST_SAFENAME="$(tools::sanitize_hostname "$HOSTNAME")"
  CLIENT_ID="${MQTT_CLIENT_ID:-apt_mqtt_${HOST_SAFENAME}}"

  BASE_TOPIC="${BASE_TOPIC%/}/${HOST_SAFENAME}"
  STATE_TOPIC="$BASE_TOPIC/state"
  ATTR_TOPIC="$BASE_TOPIC/attributes"
  CMD_TOPIC="$BASE_TOPIC/command"
  AVAIL_TOPIC="$BASE_TOPIC/availability"
  VERSION_TOPIC="$BASE_TOPIC/script_version"
  GLOBAL_UPDATE_TOPIC="${MQTT_GLOBAL_UPDATE_TOPIC:-${BASE_ROOT_TOPIC%/}/global/update}"
}