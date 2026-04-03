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

mqtt::sub_many() {
  local args=( -h "$BROKER" -p "$PORT" -i "${CLIENT_ID}_sub" )
  local topic

  if [ -n "$USERNAME" ]; then args+=( -u "$USERNAME" -P "$PASSWORD" ); fi
  for topic in "$@"; do
    args+=( -t "$topic" )
  done
  mosquitto_sub "${args[@]}"
}

mqtt::device_ip_connections() {
  local ip_list ip_prefix

  ip_prefix="${MQTT_DEVICE_IP_PREFIX:-192.168.}"

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
    --arg global_update_topic "$GLOBAL_UPDATE_TOPIC" \
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
              },
            "apt_mqtt_daemon_update_all": {
                "platform": "button",
                "unique_id": "apt_mqtt_daemon_update_all",
                "default_entity_id": "button.apt_mqtt_daemon_update_all",
                "name": "Mettre a jour les scripts",
                "command_topic": $global_update_topic,
                "payload_press": "self-update",
                "icon": "mdi:update"
            },
            "apt_mqtt_daemon_upgrade_all": {
                "platform": "button",
                "unique_id": "apt_mqtt_daemon_upgrade_all",
                "default_entity_id": "button.apt_mqtt_daemon_upgrade_all",
                "name": "Exécuter les mises à jour (apt)",
                "command_topic": $global_update_topic,
                "payload_press": "upgrade-all",
                "icon": "mdi:update"
            }

        }
    }')

  # Publish only the update entity via MQTT discovery (no separate button)
  # Use a discovery topic unique per host so multiple servers don't overwrite each other
  mqtt::pub "homeassistant/device/apt_mqtt_daemon/main/config" "$update_json" true
}

mqtt::publish_host_device_discovery() {
  local base_components base_components_file components_file docker_components docker_components_file ip_connections ip_connections_file normalized_docker_components update_json device_name
  docker_components="${1:-"{}"}"
  ip_connections="$(mqtt::device_ip_connections)"
  device_name="$(mqtt::display_hostname "$HOSTNAME")"
  if normalized_docker_components="$(printf '%s' "$docker_components" | jq -c '.' 2>/dev/null)"; then
    docker_components="$normalized_docker_components"
  else
    docker_components='{}'
  fi
  base_components_file="$(mktemp)"
  docker_components_file="$(mktemp)"
  components_file="$(mktemp)"
  ip_connections_file="$(mktemp)"

  base_components=$(jq -n \
    --arg update_key "${OBJECT_ID}_${HOST_SAFENAME}_update" \
    --arg version_key "${OBJECT_ID}_${HOST_SAFENAME}_script_version" \
    --arg name "Apt update" \
    --arg platform "update" \
    --arg state_topic "$STATE_TOPIC" \
    --arg json_attributes_topic "$ATTR_TOPIC" \
    --arg availability_topic "$AVAIL_TOPIC" \
    --arg command_topic "$CMD_TOPIC" \
    --arg payload_install "install" \
    --arg update_unique_id "${OBJECT_ID}_${HOST_SAFENAME}_update" \
    --arg update_object_id "update.${OBJECT_ID}_${HOST_SAFENAME}_update" \
    --arg version_topic "$VERSION_TOPIC" \
    --arg version_unique_id "${OBJECT_ID}_${HOST_SAFENAME}_script_version" \
    --arg version_object_id "sensor.${OBJECT_ID}_${HOST_SAFENAME}_script_version" \
    '{
      ($update_key): {
        platform:$platform,
        name:$name,
        value_template:"{{ value_json.installed_version }}",
        latest_version_topic:$state_topic,
        state_topic:$state_topic,
        latest_version_template:"{{ value_json.latest_version }}",
        json_attributes_topic:$json_attributes_topic,
        availability_topic:$availability_topic,
        command_topic:$command_topic,
        payload_install:$payload_install,
        unique_id:$update_unique_id,
        default_entity_id:$update_object_id
      },
      ($version_key): {
        platform:"sensor",
        name:"Update script (ver)",
        state_topic:$version_topic,
        availability_topic:$availability_topic,
        entity_category:"diagnostic",
        icon:"mdi:source-branch",
        unique_id:$version_unique_id,
        default_entity_id:$version_object_id
      }
    }')

  printf '%s' "$base_components" > "$base_components_file"
  printf '%s' "$docker_components" > "$docker_components_file"
  printf '%s' "$ip_connections" > "$ip_connections_file"
  jq -s '.[0] + .[1]' "$base_components_file" "$docker_components_file" > "$components_file"

  # Entity name = hostname; device is global and represents the update script
  update_json=$(jq -n \
    --slurpfile components "$components_file" \
    --slurpfile ip_connections "$ip_connections_file" \
    --arg device_id "${OBJECT_ID}_${HOST_SAFENAME}" \
    --arg device_name "$device_name" \
    --arg model "apt-mqtt-updater" \
    --arg manufacturer "custom" \
    '{ 
      device:{
        identifiers:[$device_id], 
        name:$device_name, 
        model:$model, 
        manufacturer:$manufacturer,
        via_device:"apt_mqtt_daemon",
        connections: ($ip_connections[0] // [])
      },
      origin: {name: "APT MQTT Updater"},
      components: ($components[0] // {})
    }')
  rm -f "$base_components_file" "$docker_components_file" "$components_file" "$ip_connections_file"

  # Publish only the update entity via MQTT discovery (no separate button)
  # Use a discovery topic unique per host so multiple servers don't overwrite each other
  mqtt::pub "homeassistant/device/${OBJECT_ID}/${HOST_SAFENAME}/config" "$update_json" true
}


# mqtt::publish_version_sensor_discovery() {
#   local sensor_json device_name

#   device_name="$(mqtt::display_hostname "$HOSTNAME")"
#   sensor_json=$(jq -n \
#     --arg name "Version du script" \
#     --arg unique_id "${OBJECT_ID}_${HOST_SAFENAME}_script_version" \
#     --arg default_entity_id "sensor.${OBJECT_ID}_${HOST_SAFENAME}_script_version" \
#     --arg state_topic "$VERSION_TOPIC" \
#     --arg availability_topic "$AVAIL_TOPIC" \
#     --arg device_id "${OBJECT_ID}_${HOST_SAFENAME}" \
#     --arg device_name "$device_name" \
#     --arg model "apt-mqtt-updater" \
#     --arg manufacturer "custom" \
#     '{name:$name,
#       unique_id:$unique_id,
#       default_entity_id:$default_entity_id,
#       state_topic:$state_topic,
#       availability_topic:$availability_topic,
#       entity_category:"diagnostic",
#       icon:"mdi:source-branch",
#       device:{
#         identifiers:[$device_id],
#         name:$device_name,
#         model:$model,
#         manufacturer:$manufacturer,
#         via_device:"apt_mqtt_daemon"
#       }
#     }')

#   mqtt::pub "homeassistant/sensor/${OBJECT_ID}/${HOST_SAFENAME}_script_version/config" "$sensor_json" true
# }