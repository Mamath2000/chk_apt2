#!/usr/bin/env bash

config::load() {
  local script_dir="$1"
  local cfg requested_log_level

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
  CHECK_INTERVAL="${CHECK_INTERVAL:-3600}"
  INSTALL_DIR="${APT_MQTT_INSTALL_DIR:-$script_dir}"
  SERVICE_NAME="apt-mqtt.service"
  DOCKER_SERVICE_NAME="docker-mqtt.service"

  requested_log_level="${APT_MQTT_LOG_LEVEL:-${LOG_LEVEL:-INFO}}"
  LOG_LEVEL="$(tools::normalize_log_level "$requested_log_level")"

  HOSTNAME="$(hostname -s)"
  HOST_SAFENAME="$(tools::sanitize_hostname "$HOSTNAME")"

  GLOBAL_UPDATE_TOPIC="apt-update/global/update"
  DOCKER_GLOBAL_UPDATE_TOPIC="docker-update/global/update"

  config::apply_apt_defaults
}

config::apply_apt_defaults() {
  BASE_ROOT_TOPIC="apt-update"
  OBJECT_ID="apt_update"
  BASE_TOPIC="${BASE_ROOT_TOPIC%/}/${HOST_SAFENAME}"
  STATE_TOPIC="$BASE_TOPIC/state"
  ATTR_TOPIC="$BASE_TOPIC/attributes"
  CMD_TOPIC="$BASE_TOPIC/command"
  AVAIL_TOPIC="$BASE_TOPIC/availability"
  VERSION_TOPIC="$BASE_TOPIC/script_version"
}

config::apply_docker_defaults() {
  BASE_ROOT_TOPIC="docker-update"
  OBJECT_ID="docker_update"
  BASE_TOPIC="${BASE_ROOT_TOPIC%/}/${HOST_SAFENAME}"
  STATE_TOPIC="$BASE_TOPIC/state"
  ATTR_TOPIC="$BASE_TOPIC/attributes"
  CMD_TOPIC="$BASE_TOPIC/command"
  AVAIL_TOPIC="$BASE_TOPIC/availability"
  VERSION_TOPIC="$BASE_TOPIC/script_version"
}