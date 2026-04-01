#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="apt-mqtt.service"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_PATH="$SYSTEMD_DIR/$SERVICE_NAME"
DAEMON_PATH="$SCRIPT_DIR/apt_mqtt_daemon.sh"
CONFIG_PATH=""
FOLLOW_STATUS="false"

usage() {
  cat <<EOF
Usage:
  sudo ./install_service.sh install [-f] [--config /absolute/path/config.conf]
  sudo ./install_service.sh status [-f]
  sudo ./install_service.sh remove

Options:
  --config PATH   Chemin du fichier de configuration à injecter dans le service.
  -f, --follow    Lance systemctl status -f après install ou pour l'action status.

Le service généré est installé dans:
  $SERVICE_PATH
EOF
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit être exécuté en root (sudo)." >&2
    exit 1
  fi
}

pick_default_config() {
  local candidates=()

  candidates+=("$SCRIPT_DIR/config.conf")
  candidates+=("/etc/apt_mqtt/config.conf")
  candidates+=("$HOME/.config/apt_mqtt/config.conf")

  for candidate in "${candidates[@]}"; do
    if [ -r "$candidate" ]; then
      CONFIG_PATH="$candidate"
      return 0
    fi
  done

  echo "Aucun fichier de configuration lisible trouvé." >&2
  echo "Utilisez --config /chemin/vers/config.conf ou créez config.conf dans le projet." >&2
  exit 1
}

parse_args() {
  ACTION="${1:-}"

  if [ "$ACTION" = "-h" ] || [ "$ACTION" = "--help" ] || [ -z "$ACTION" ]; then
    usage
    exit 0
  fi

  shift || true

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config)
        if [ "$#" -lt 2 ]; then
          echo "Option --config sans valeur." >&2
          exit 1
        fi
        CONFIG_PATH="$2"
        shift 2
        ;;
      -f|--follow)
        FOLLOW_STATUS="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Argument inconnu: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

}

validate_paths() {
  if [ ! -x "$DAEMON_PATH" ]; then
    echo "Script démon introuvable ou non exécutable: $DAEMON_PATH" >&2
    exit 1
  fi

  if [ -z "$CONFIG_PATH" ]; then
    pick_default_config
  fi

  if [ ! -f "$CONFIG_PATH" ]; then
    echo "Fichier de configuration introuvable: $CONFIG_PATH" >&2
    exit 1
  fi

  CONFIG_PATH="$(realpath "$CONFIG_PATH")"
}

write_service_file() {
  mkdir -p "$SYSTEMD_DIR"
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=APT MQTT Updater (Bash)
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$SCRIPT_DIR
Environment=APT_MQTT_CONFIG=$CONFIG_PATH
ExecStart=$DAEMON_PATH
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
}

show_status() {
  if [ "$FOLLOW_STATUS" = "true" ]; then
    exec systemctl status -f "$SERVICE_NAME"
  fi

  systemctl --no-pager --full status "$SERVICE_NAME"
}

install_service() {
  validate_paths
  write_service_file
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  echo "Service installé: $SERVICE_PATH"
  echo "Configuration utilisée: $CONFIG_PATH"
  show_status
}

remove_service() {
  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
    systemctl disable --now "$SERVICE_NAME" || true
  fi
  rm -f "$SERVICE_PATH"
  systemctl daemon-reload
  echo "Service supprimé: $SERVICE_PATH"
}

status_service() {
  show_status
}

main() {
  require_root
  parse_args "$@"

  case "$ACTION" in
    install)
      install_service
      ;;
    status)
      status_service
      ;;
    remove)
      remove_service
      ;;
    *)
      echo "Action inconnue: $ACTION" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"