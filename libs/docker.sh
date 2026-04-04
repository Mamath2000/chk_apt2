#!/usr/bin/env bash

DOCKER_LAST_OUTPUT=""
DOCKER_COMPOSE_COMMAND=""

docker::is_available() {
  if [ -n "$DOCKER_COMPOSE_COMMAND" ]; then
    return 0
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_COMMAND="docker compose"
    tools::log DEBUG "Commande Docker Compose détectée: $DOCKER_COMPOSE_COMMAND"
    return 0
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE_COMMAND="docker-compose"
    tools::log DEBUG "Commande Docker Compose détectée: $DOCKER_COMPOSE_COMMAND"
    return 0
  fi

  return 1
}

docker::compose() {
  local compose_file="$1"
  shift

  if ! docker::is_available; then
    return 1
  fi

  if [ "$DOCKER_COMPOSE_COMMAND" = "docker compose" ]; then
    docker compose -f "$compose_file" "$@"
  else
    docker-compose -f "$compose_file" "$@"
  fi
}

docker::find_compose_files() {
  local patterns=(
    /root/docker-compose.yml
    /root/*/docker-compose.yml
    /home/mamath/docker-compose.yml
    /home/mamath/*/docker-compose.yml
  )
  local pattern file

  shopt -s nullglob
  for pattern in "${patterns[@]}"; do
    for file in $pattern; do
      [ -f "$file" ] && printf '%s\n' "$file"
    done
  done
  shopt -u nullglob
}

docker::stack_id_from_file() {
  local compose_file="$1"
  local stack_id

  stack_id="${compose_file%/docker-compose.yml}"
  stack_id="${stack_id#/}"
  stack_id=$(printf '%s' "$stack_id" | tr '[:upper:]' '[:lower:]' | sed 's#/#_#g; s#[^a-z0-9._-]#_#g')
  printf '%s' "$stack_id"
}

docker::stack_name_from_file() {
  local compose_file="$1"
  local stack_dir stack_name

  stack_dir="${compose_file%/docker-compose.yml}"
  stack_name="${stack_dir##*/}"
  printf 'Docker %s' "$stack_name"
}

docker::stack_topic_prefix() {
  local stack_id="$1"
  printf '%s/docker/%s' "$BASE_TOPIC" "$stack_id"
}

docker::stack_state_topic() {
  local stack_id="$1"
  printf '%s/state' "$(docker::stack_topic_prefix "$stack_id")"
}

docker::stack_attr_topic() {
  local stack_id="$1"
  printf '%s/attributes' "$(docker::stack_topic_prefix "$stack_id")"
}

docker::stack_command_payload() {
  local stack_id="$1"
  printf 'docker-install:%s' "$stack_id"
}

docker::capture_compose_output() {
  local compose_file="$1"
  shift
  local output_file rc

  output_file="$(mktemp)"
  rc=0
  tools::log DEBUG "docker compose exec: file=$compose_file args=$*"

  if docker::compose "$compose_file" "$@" >"$output_file" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  DOCKER_LAST_OUTPUT="$(head -c20000 "$output_file")"
  rm -f "$output_file"
  return "$rc"
}

docker::image_digest_from_identifier() {
  local image_identifier="$1"
  local repo_digests digest image_id

  repo_digests="$(docker image inspect --format '{{json .RepoDigests}}' "$image_identifier" 2>/dev/null || printf '[]')"
  digest="$(printf '%s' "$repo_digests" | jq -r 'map(select(contains("@sha256:"))) | .[0] // empty | split("@")[1]')"
  if [ -n "$digest" ]; then
    printf '%s' "$digest"
    return 0
  fi

  image_id="$(docker image inspect --format '{{.Id}}' "$image_identifier" 2>/dev/null || true)"
  if [ -n "$image_id" ]; then
    printf '%s' "$image_id"
    return 0
  fi

  return 1
}

docker::service_image_refs_json() {
  local compose_file="$1"
  local output_file error_file rc

  output_file="$(mktemp)"
  error_file="$(mktemp)"
  rc=0
  tools::log DEBUG "docker compose image refs: file=$compose_file"

  if docker::compose "$compose_file" config --format json >"$output_file" 2>"$error_file"; then
    DOCKER_LAST_OUTPUT="$(cat "$error_file" "$output_file" | head -c20000)"
    jq -c '
      .services
      | to_entries
      | map(select(.value.image != null) | {
          key: .key,
          value: .value.image
        })
      | from_entries
    ' "$output_file"
  else
    rc=$?
    DOCKER_LAST_OUTPUT="$(cat "$error_file" "$output_file" | head -c20000)"
  fi

  rm -f "$output_file"
  rm -f "$error_file"
  return "$rc"
}

docker::service_images_json() {
  local compose_file="$1"
  local resolve_digests="${2:-false}"
  local output_file error_file rc
  local extra_args=()

  if [ "$resolve_digests" = "true" ]; then
    extra_args+=( --resolve-image-digests )
  fi

  output_file="$(mktemp)"
  error_file="$(mktemp)"
  rc=0
  tools::log DEBUG "docker compose config: file=$compose_file resolve_digests=$resolve_digests"

  if docker::compose "$compose_file" config "${extra_args[@]}" --format json >"$output_file" 2>"$error_file"; then
    DOCKER_LAST_OUTPUT="$(cat "$error_file" "$output_file" | head -c20000)"
    jq -c '
      .services
      | to_entries
      | map(select(.value.image != null) | {
          key: .key,
          value: (
            .value.image
            | if contains("@") then split("@")[1] else . end
          )
        })
      | from_entries
    ' "$output_file"
  else
    rc=$?
    DOCKER_LAST_OUTPUT="$(cat "$error_file" "$output_file" | head -c20000)"
  fi

  rm -f "$output_file"
  rm -f "$error_file"
  return "$rc"
}

docker::deployed_service_images_json() {
  local compose_file="$1"
  local services_json result service container_id image_id image_ref digest

  if ! services_json="$(docker::service_image_refs_json "$compose_file")"; then
    return 1
  fi

  result='{}'
  while IFS= read -r service; do
    [ -z "$service" ] && continue
    image_ref="$(printf '%s' "$services_json" | jq -r --arg service "$service" '.[$service] // empty')"

    container_id="$(docker::compose "$compose_file" ps -a -q "$service" 2>/dev/null | head -n1 || true)"
    if [ -z "$container_id" ]; then
      if digest="$(docker::image_digest_from_identifier "$image_ref")"; then
        tools::log DEBUG "Aucun conteneur pour $compose_file service=$service, repli sur image locale $image_ref"
        result="$(printf '%s' "$result" | jq -c --arg service "$service" --arg digest "$digest" '. + {($service): $digest}')"
      else
        tools::log DEBUG "Aucun conteneur ni image locale trouvés pour la stack $compose_file service=$service"
      fi
      continue
    fi

    image_id="$(docker inspect --format '{{.Image}}' "$container_id" 2>/dev/null || true)"
    if [ -z "$image_id" ]; then
      continue
    fi

    if ! digest="$(docker::image_digest_from_identifier "$image_id")"; then
      digest="$image_id"
    fi

    result="$(printf '%s' "$result" | jq -c --arg service "$service" --arg digest "$digest" '. + {($service): $digest}')"
  done < <(printf '%s' "$services_json" | jq -r 'keys[]')

  printf '%s' "$result"
}

docker::pull_stack() {
  local compose_file="$1"
  docker::capture_compose_output "$compose_file" pull --include-deps
}

docker::up_stack() {
  local compose_file="$1"
  docker::capture_compose_output "$compose_file" up -d
}