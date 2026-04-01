#!/usr/bin/env bash



mqtt::pub() {
  local topic="$1" payload="$2" retain="${3:-false}"
  local args=( -h "$BROKER" -p "$PORT" -i "$CLIENT_ID" )
  if [ -n "$USERNAME" ]; then args+=( -u "$USERNAME" -P "$PASSWORD" ); fi
  if [ "$retain" = true ]; then args+=( -r ); fi
  mosquitto_pub "${args[@]}" -t "$topic" -m "$payload"
}

mqtt::sub() {
  local topic="$1"
  local args=( -h "$BROKER" -p "$PORT" -i "${CLIENT_ID}_sub" -t "$topic" )
  if [ -n "$USERNAME" ]; then args+=( -u "$USERNAME" -P "$PASSWORD" ); fi
  mosquitto_sub "${args[@]}"
}

mqtt::device_ip_connections() {
  local ip_list ip_prefix

  ip_prefix="${MQTT_DEVICE_IP_PREFIX:-192.169.}"

  ip_list=$(hostname -I 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | grep "^${ip_prefix//./\\.}" || true)
  if [ -z "$ip_list" ]; then
    printf '[]'
    return
  fi

  printf '%s\n' "$ip_list" | jq -R . | jq -s 'map(["ip", .])'
}

mqtt::display_hostname() {
  local hostname_value="$1"
  local first_char rest

  if [ -z "$hostname_value" ]; then
    printf '%s' "$hostname_value"
    return
  fi

  first_char=$(printf '%s' "$hostname_value" | cut -c1 | tr '[:lower:]' '[:upper:]')
  rest=$(printf '%s' "$hostname_value" | cut -c2-)
  printf '%s%s' "$first_char" "$rest"
}

mqtt::publish_main_device_discovery() {
  local update_json
  # Entity name = hostname; device is global and represents the update script
  update_json=$(jq -n \
    --arg name "APT Updater Daemon" \
    '{device:{
          identifiers:["apt_mqtt_daemon"], 
        name:$name, 
        model:"apt-mqtt-updater", 
        manufacturer:"Mamath"
      },
      origin: {name: "APT MQTT Updater"},
      components:{
        "apt_mqtt_daemon_status": {
              "platform": "binary_sensor",
              "unique_id": "apt_mqtt_daemon_status",
              "default_entity_id": "binary_sensor.apt_mqtt_daemon_status",
              "name": "Status",
              "state_topic": "homeassistant/device/apt_mqtt_daemon/main/config",
              "value_template": "online",
              "payload_on": "online",
              "payload_off": "offline",
              "device_class": "connectivity",
              "icon": "mdi:server-network"
            }
        }
    }')

  # Publish only the update entity via MQTT discovery (no separate button)
  # Use a discovery topic unique per host so multiple servers don't overwrite each other
  mqtt::pub "homeassistant/device/apt_mqtt_daemon/main/config" "$update_json" true
}

mqtt::publish_discovery() {
  local update_json ip_connections device_name
  ip_connections="$(mqtt::device_ip_connections)"
  device_name="$(mqtt::display_hostname "$HOSTNAME")"

  # Entity name = hostname; device is global and represents the update script
  update_json=$(jq -n \
    --arg name "Apt update" \
    --arg platform "update" \
    --arg state_topic "$STATE_TOPIC" \
    --arg json_attributes_topic "$ATTR_TOPIC" \
    --arg availability_topic "$AVAIL_TOPIC" \
    --arg command_topic "$CMD_TOPIC" \
    --arg payload_install "install" \
    --arg unique_id "${OBJECT_ID}_${HOST_SAFENAME}_update" \
    --arg default_entity_id "update.${OBJECT_ID}_${HOST_SAFENAME}_update" \
    --arg device_id "${OBJECT_ID}_${HOST_SAFENAME}" \
    --arg device_name "$device_name" \
    --arg model "apt-mqtt-updater" \
    --arg manufacturer "custom" \
    --argjson ip_connections "$ip_connections" \
    '{name:$name, 
      platform:$platform, 
      state_topic:$state_topic, 
      value_template:"{{ value_json.installed_version }}",
      latest_version_topic:$state_topic, 
      latest_version_template:"{{ value_json.latest_version }}",
      json_attributes_topic:$json_attributes_topic, 
      availability_topic:$availability_topic, 
      command_topic:$command_topic, 
      payload_install:$payload_install, 
      unique_id:$unique_id, 
      default_entity_id:$default_entity_id, 
      device:{
        identifiers:[$device_id], 
        name:$device_name, 
        model:$model, 
        manufacturer:$manufacturer,
        via_device:"apt_mqtt_daemon",
        connections: $ip_connections
      }
    }')

  # Publish only the update entity via MQTT discovery (no separate button)
  # Use a discovery topic unique per host so multiple servers don't overwrite each other
  mqtt::pub "homeassistant/update/${OBJECT_ID}/${HOST_SAFENAME}/config" "$update_json" true
}