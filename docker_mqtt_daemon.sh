#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/libs/mqtt.sh"
source "$SCRIPT_DIR/libs/tools.sh"
source "$SCRIPT_DIR/libs/config.sh"
source "$SCRIPT_DIR/libs/apt.sh"
source "$SCRIPT_DIR/libs/docker.sh"
source "$SCRIPT_DIR/libs/state.sh"


usage() {
  cat <<'EOF'
Usage: docker_mqtt_daemon.sh

Ce script ne prend plus d'options en ligne de commande.
Configurez les paramètres dans un fichier de configuration (shell-compatible) :
  /etc/apt_mqtt/config.conf
  $HOME/.config/apt_mqtt/config.conf
  <repo>/config.conf

Exécutez simplement :
  sudo ./docker_mqtt_daemon.sh
EOF
}


tools::require_root

config::load "$SCRIPT_DIR"
config::apply_docker_defaults
CLIENT_ID="$(tools::sanitize_hostname "${HOSTNAME}_docker_mqtt")"

state::init_paths "$SCRIPT_DIR" "docker"

tools::check_requirements mosquitto_pub mosquitto_sub jq

tools::log INFO "Démarrage du démon Docker MQTT"
tools::log INFO "Niveau de log: $LOG_LEVEL"
tools::log INFO "Script dir: $SCRIPT_DIR"
tools::log INFO "Fichier de config: ${CONFIG_FILE:-(none)}"
tools::log INFO "MQTT broker: $BROKER:$PORT base_root_topic: $BASE_ROOT_TOPIC base_topic: $BASE_TOPIC docker_command_topic: $CMD_TOPIC client_id: $CLIENT_ID"
tools::log INFO "MQTT global docker topic: $DOCKER_GLOBAL_UPDATE_TOPIC"

CMD_FIFO=""
MOSQ_PID=""
LOOP_PID=""
DOCKER_STACKS_JSON='[]'
ACTIVE_JOB_PIDS=()
CLEANUP_DONE=false


start_background_job() {
  local job_name="$1"
  shift
  "$@" &
  ACTIVE_JOB_PIDS+=("$!")
  tools::log DEBUG "Job lancé: name=$job_name pid=$!"
}


discover_docker_stacks() {
  local compose_file stack_id stack_name stack_json

  DOCKER_STACKS_JSON='[]'
  if ! docker::is_available; then
    tools::log INFO "Docker Compose non disponible, supervision Docker ignorée"
    return
  fi

  while IFS= read -r compose_file; do
    [ -z "$compose_file" ] && continue
    stack_id="$(docker::stack_id_from_file "$compose_file")"
    stack_name="$(docker::stack_name_from_file "$compose_file")"
    stack_json="$(jq -n \
      --arg id "$stack_id" \
      --arg path "$compose_file" \
      --arg name "$stack_name" \
      --arg state_topic "$(docker::stack_state_topic "$stack_id")" \
      --arg attr_topic "$(docker::stack_attr_topic "$stack_id")" \
      --arg payload_install "$(docker::stack_command_payload "$stack_id")" \
      '{id:$id, path:$path, name:$name, state_topic:$state_topic, attr_topic:$attr_topic, payload_install:$payload_install}')"
    DOCKER_STACKS_JSON="$(printf '%s' "$DOCKER_STACKS_JSON" | jq -c --argjson stack "$stack_json" '. + [$stack]')"
    tools::log DEBUG "Stack Docker détectée: id=$stack_id path=$compose_file name=$stack_name"
  done < <(docker::find_compose_files)

  tools::log INFO "Stacks Docker Compose détectées: $(printf '%s' "$DOCKER_STACKS_JSON" | jq 'length')"
}


build_docker_discovery_components() {
  printf '%s' "$DOCKER_STACKS_JSON" | jq -c \
    --arg object_id "$OBJECT_ID" \
    --arg host_safename "$HOST_SAFENAME" \
    --arg avail_topic "$AVAIL_TOPIC" \
    --arg cmd_topic "$CMD_TOPIC" '
      map(
        . as $stack
        | (($object_id + "_" + $host_safename + "_docker_" + $stack.id + "_update")) as $component_key
        | {
            key: $component_key,
            value: {
              platform: "update",
              name: $stack.name,
              value_template: "{{ value_json.installed_version }}",
              latest_version_topic: $stack.state_topic,
              state_topic: $stack.state_topic,
              latest_version_template: "{{ value_json.latest_version }}",
              json_attributes_topic: $stack.attr_topic,
              availability_topic: $avail_topic,
              command_topic: $cmd_topic,
              payload_install: $stack.payload_install,
              unique_id: $component_key,
              default_entity_id: ("update." + $component_key),
              icon: "mdi:docker"
            }
          }
      )
      | from_entries
    '
}


docker_updates_json() {
  local deployed_images="$1"
  local resolved_images="$2"

  jq -n --argjson deployed "$deployed_images" --argjson resolved "$resolved_images" '
    $resolved
    | to_entries
    | map(select(.value != "" and .value != ($deployed[.key] // "")) | {
        service: .key,
        deployed: ($deployed[.key] // ""),
        latest: .value
      })
  '
}


publish_docker_stack_status_quick() {
  local stack_id="$1" compose_file="$2" state_topic="$3" attr_topic="$4"
  local in_progress="${5:-false}" last_result_code="${6:-0}" last_result="${7:-}"
  local last_check installed_version latest_version deployed_images state_payload attrs

  last_check=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  state::ensure_docker_stack "$stack_id"
  installed_version="$(state::read_docker_installed_version "$stack_id")"
  deployed_images="$(state::read_docker_deployed_images "$stack_id")"

  if [ "$in_progress" = "true" ]; then
    latest_version="$installed_version"
  else
    latest_version="$installed_version"
  fi

  state_payload="$(jq -n \
    --arg installed_version "$installed_version" \
    --arg latest_version "$latest_version" \
    --arg last_check "$last_check" \
    --arg in_progress "$in_progress" \
    '{installed_version:$installed_version, latest_version:$latest_version, last_check:$last_check, in_progress: ($in_progress == "true")}')"

  attrs="$(jq -n \
    --arg compose_file "$compose_file" \
    --arg last_check "$last_check" \
    --arg in_progress "$in_progress" \
    --arg last_result "$last_result" \
    --arg last_result_code "$last_result_code" \
    --argjson deployed_images "$deployed_images" \
    '{count: 0, compose_file: $compose_file, updates: [], deployed_images: $deployed_images, latest_images: {}, last_check: $last_check, in_progress: ($in_progress == "true"), last_result_code: ($last_result_code|tonumber), last_result: $last_result}')"

  mqtt::pub "$state_topic" "$state_payload" true
  mqtt::pub "$attr_topic" "$attrs" true
}


publish_docker_stack_status() {
  local stack_id="$1" compose_file="$2" state_topic="$3" attr_topic="$4"
  local last_check in_progress installed_version latest_version deployed_images current_deployed_images resolved_images updates_json update_count attrs state_payload rc check_output

  last_check=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  in_progress="$(state::is_docker_stack_in_progress "$stack_id")"

  if current_deployed_images="$(docker::deployed_service_images_json "$compose_file")"; then
    :
  else
    current_deployed_images='{}'
  fi

  state::ensure_docker_stack "$stack_id" "$current_deployed_images"
  installed_version="$(state::read_docker_installed_version "$stack_id")"
  deployed_images="$(state::read_docker_deployed_images "$stack_id")"

  if [ "$current_deployed_images" != '{}' ] && [ "$current_deployed_images" != "$deployed_images" ]; then
    state::write_docker_deployed_images "$stack_id" "$current_deployed_images"
    deployed_images="$current_deployed_images"
  fi

  if resolved_images="$(docker::service_images_json "$compose_file" true)"; then
    rc=0
    check_output=""
  else
    rc=$?
    resolved_images='{}'
    check_output="$DOCKER_LAST_OUTPUT"
  fi

  updates_json="$(docker_updates_json "$deployed_images" "$resolved_images")"
  update_count="$(printf '%s' "$updates_json" | jq 'length')"
  tools::log DEBUG "Statut stack Docker: id=$stack_id updates=$update_count in_progress=$in_progress compose_file=$compose_file"
  if [ "$update_count" -eq 0 ]; then
    latest_version="$installed_version"
  else
    latest_version="$(apt::bump_version "$installed_version")"
  fi

  state_payload="$(jq -n \
    --arg installed_version "$installed_version" \
    --arg latest_version "$latest_version" \
    --arg last_check "$last_check" \
    --arg in_progress "$in_progress" \
    '{installed_version:$installed_version, latest_version:$latest_version, last_check:$last_check, in_progress: ($in_progress == "true")}')"

  attrs="$(jq -n \
    --arg compose_file "$compose_file" \
    --arg last_check "$last_check" \
    --arg in_progress "$in_progress" \
    --arg check_output "$check_output" \
    --arg last_result_code "$rc" \
    --argjson deployed_images "$deployed_images" \
    --argjson latest_images "$resolved_images" \
    --argjson updates "$updates_json" \
    '{count: ($updates|length), compose_file: $compose_file, updates: $updates, deployed_images: $deployed_images, latest_images: $latest_images, last_check: $last_check, in_progress: ($in_progress == "true"), last_result_code: ($last_result_code|tonumber), last_result: $check_output}')"

  mqtt::pub "$state_topic" "$state_payload" true
  mqtt::pub "$attr_topic" "$attrs" true
}


publish_docker_status() {
  local stack_json

  while IFS= read -r stack_json; do
    [ -z "$stack_json" ] && continue
    publish_docker_stack_status \
      "$(printf '%s' "$stack_json" | jq -r '.id')" \
      "$(printf '%s' "$stack_json" | jq -r '.path')" \
      "$(printf '%s' "$stack_json" | jq -r '.state_topic')" \
      "$(printf '%s' "$stack_json" | jq -r '.attr_topic')"
  done < <(printf '%s' "$DOCKER_STACKS_JSON" | jq -c '.[]')
}


handle_docker_install() {
  local stack_id="$1" compose_file current_deployed_images installed_version new_installed resolved_images updates_json update_count result rc last_run last_result
  local state_topic attr_topic

  compose_file="$(printf '%s' "$DOCKER_STACKS_JSON" | jq -r --arg id "$stack_id" '.[] | select(.id == $id) | .path' | head -n1)"
  state_topic="$(printf '%s' "$DOCKER_STACKS_JSON" | jq -r --arg id "$stack_id" '.[] | select(.id == $id) | .state_topic' | head -n1)"
  attr_topic="$(printf '%s' "$DOCKER_STACKS_JSON" | jq -r --arg id "$stack_id" '.[] | select(.id == $id) | .attr_topic' | head -n1)"
  if [ -z "$compose_file" ]; then
    echo "Stack Docker inconnue: $stack_id"
    return 1
  fi

  if [ "$(state::is_in_progress)" = "true" ]; then
    echo "Une opération est déjà en cours"
    return
  fi

  state::ensure_docker_stack "$stack_id"
  state::mark_in_progress
  state::mark_docker_stack_in_progress "$stack_id"
  trap "state::clear_docker_stack_in_progress \"$stack_id\" || true; state::clear_in_progress || true" EXIT
  publish_docker_stack_status_quick "$stack_id" "$compose_file" "$state_topic" "$attr_topic" true
  tools::log DEBUG "Début mise à jour Docker: stack_id=$stack_id compose_file=$compose_file"
  echo "Mise à jour Docker Compose: $compose_file"

  current_deployed_images="$(docker::deployed_service_images_json "$compose_file" 2>/dev/null || printf '{}')"
  state::ensure_docker_stack "$stack_id" "$current_deployed_images"

  if resolved_images="$(docker::service_images_json "$compose_file" true)"; then
    :
  else
    resolved_images='{}'
  fi
  updates_json="$(docker_updates_json "$(state::read_docker_deployed_images "$stack_id")" "$resolved_images")"
  update_count="$(printf '%s' "$updates_json" | jq 'length')"
  tools::log DEBUG "Mises à jour Docker détectées: stack_id=$stack_id count=$update_count"

  result=""
  if docker::pull_stack "$compose_file"; then
    result="$DOCKER_LAST_OUTPUT"
    if docker::up_stack "$compose_file"; then
      rc=0
      result="$result
$DOCKER_LAST_OUTPUT"
    else
      rc=$?
      result="$result
$DOCKER_LAST_OUTPUT"
    fi
  else
    rc=$?
    result="$DOCKER_LAST_OUTPUT"
  fi

  if [ "$rc" -eq 0 ]; then
    installed_version="$(state::read_docker_installed_version "$stack_id")"
    if [ "$update_count" -gt 0 ]; then
      new_installed="$(apt::bump_version "$installed_version")"
      state::write_docker_installed_version "$stack_id" "$new_installed"
    fi
    if resolved_images="$(docker::service_images_json "$compose_file" true)"; then
      state::write_docker_deployed_images "$stack_id" "$resolved_images"
    fi
  fi

  last_run=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  last_result=$(printf '%s' "$result" | sed '/^$/d' | head -c20000)
  tools::log DEBUG "Fin mise à jour Docker: stack_id=$stack_id rc=$rc last_run=$last_run"
  if [ -n "$last_result" ]; then
    while IFS= read -r _line; do
      tools::log INFO "docker compose: ${_line:- }"
    done <<< "$last_result"
  fi

  state::clear_docker_stack_in_progress "$stack_id"
  state::clear_in_progress
  trap - EXIT
  publish_docker_status

  if [ "$rc" -ne 0 ]; then
    tools::log ERROR "docker compose update échoué pour $compose_file à $last_run"
    return "$rc"
  fi
}


handle_docker_install_all() {
  local stack_json stack_id overall_rc rc

  if [ "$(printf '%s' "$DOCKER_STACKS_JSON" | jq 'length')" -eq 0 ]; then
    echo "Aucune stack Docker détectée"
    return
  fi

  overall_rc=0
  while IFS= read -r stack_json; do
    [ -z "$stack_json" ] && continue
    stack_id="$(printf '%s' "$stack_json" | jq -r '.id')"
    if handle_docker_install "$stack_id"; then
      rc=0
    else
      rc=$?
      overall_rc=$rc
    fi
  done < <(printf '%s' "$DOCKER_STACKS_JSON" | jq -c '.[]')

  return "$overall_rc"
}


start_mqtt_subscription() {
  local rc

  while true; do
    tools::log DEBUG "Souscription MQTT démarrée: topics=$CMD_TOPIC $DOCKER_GLOBAL_UPDATE_TOPIC"
    if mqtt::sub_many "$CMD_TOPIC" "$DOCKER_GLOBAL_UPDATE_TOPIC" > "$CMD_FIFO"; then
      rc=0
    else
      rc=$?
    fi

    tools::log WARN "Souscription MQTT Docker interrompue: rc=$rc reconnexion dans 1s"
    sleep 1
  done
}


cleanup() {
  local exit_status="${1:-0}"
  local pid

  if [ "$CLEANUP_DONE" = true ]; then
    return
  fi
  CLEANUP_DONE=true

  echo "Arrêt du démon Docker..."
  for pid in "${ACTIVE_JOB_PIDS[@]}"; do
    [ -n "$pid" ] || continue
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done
  if [ -n "$LOOP_PID" ]; then pkill -TERM -P "$LOOP_PID" 2>/dev/null || true; fi
  if [ -n "$MOSQ_PID" ]; then pkill -TERM -P "$MOSQ_PID" 2>/dev/null || true; fi
  if [ -n "$MOSQ_PID" ]; then kill "$MOSQ_PID" 2>/dev/null || true; fi
  if [ -n "$LOOP_PID" ]; then kill "$LOOP_PID" 2>/dev/null || true; fi
  exec 3>&- 2>/dev/null || true
  exec 3<&- 2>/dev/null || true
  if [ -n "$CMD_FIFO" ] && [ -p "$CMD_FIFO" ]; then rm -f "$CMD_FIFO"; fi
  state::clear_all_docker_stack_in_progress
  state::clear_in_progress
  mqtt::pub "$AVAIL_TOPIC" "offline" true || true

  return "$exit_status"
}

trap 'trap - SIGINT EXIT; cleanup 130; exit 130' SIGINT
trap 'trap - SIGTERM EXIT; cleanup 143; exit 143' SIGTERM
trap 'status=$?; trap - EXIT; cleanup "$status"; exit "$status"' EXIT


main() {
  local docker_components

  mqtt::clear_retained "homeassistant/device/docker_mqtt_daemon/main/config"
  state::clear_all_docker_stack_in_progress
  discover_docker_stacks
  docker_components="$(build_docker_discovery_components)"

  tools::log DEBUG "Composants discovery Docker générés: $(printf '%s' "$docker_components" | jq 'keys | length')"

  mqtt::publish_docker_device_discovery "$docker_components"
  mqtt::pub "$AVAIL_TOPIC" "online" true

  CMD_FIFO="$(mktemp -u /tmp/docker_mqtt_fifo.XXXXXX)"
  mkfifo "$CMD_FIFO"
  exec 3<> "$CMD_FIFO"
  start_mqtt_subscription &
  MOSQ_PID=$!

  (
    while true; do
      if read -r payload <&3; then
        payload_lc=$(printf '%s' "$payload" | tr '[:upper:]' '[:lower:]' | tr -d '\r')
        tools::log DEBUG "Commande MQTT Docker reçue: raw=$payload normalized=$payload_lc"
        case "$payload_lc" in
          docker-install:*)
            start_background_job "docker-install" handle_docker_install "${payload_lc#docker-install:}"
            ;;
          pull-all|docker-install-all|update-all)
            start_background_job "docker-install-all" handle_docker_install_all
            ;;
          check|status)
            publish_docker_status
            ;;
          *)
            echo "Commande MQTT Docker inconnue: $payload"
            ;;
        esac
      fi
    done
  ) &
  LOOP_PID=$!

  while true; do
    discover_docker_stacks
    docker_components="$(build_docker_discovery_components)"
    mqtt::publish_docker_device_discovery "$docker_components"
    publish_docker_status
    sleep "$CHECK_INTERVAL"
    tools::log DEBUG "Cycle Docker suivant après tempo ($CHECK_INTERVAL s)"
  done
}


main