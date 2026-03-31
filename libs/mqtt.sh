#!/usr/bin/env bash



mqtt::pub() {
  local topic="$1" payload="$2" retain="${3:-false}"
  local args=( -h "$BROKER" -p "$PORT" )
  if [ -n "$USERNAME" ]; then args+=( -u "$USERNAME" -P "$PASSWORD" ); fi
  if [ "$retain" = true ]; then args+=( -r ); fi
  mosquitto_pub "${args[@]}" -t "$topic" -m "$payload"
}

mqtt::publish_discovery() {
  # Entity name = hostname; device is global and represents the update script
  update_json=$(jq -n \
    --arg name "$HOSTNAME" \
    --arg platform "update" \
    --arg state_topic "$STATE_TOPIC" \
    --arg json_attributes_topic "$ATTR_TOPIC" \
    --arg availability_topic "$AVAIL_TOPIC" \
    --arg command_topic "$CMD_TOPIC" \
    --arg payload_install "install" \
    --arg unique_id "${OBJECT_ID}_$HOSTNAME" \
    --arg device_id "${OBJECT_ID}" \
    --arg device_name "APT Updater" \
    --arg model "apt-mqtt-updater" \
    --arg manufacturer "custom" \
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
      device:{
        identifiers:[$device_id], 
        name:$device_name, 
        model:$model, 
        manufacturer:$manufacturer}}')

  # Publish only the update entity via MQTT discovery (no separate button)
  # Use a discovery topic unique per host so multiple servers don't overwrite each other
  mqtt::pub "homeassistant/update/${OBJECT_ID}/$HOSTNAME/config" "$update_json" true
}