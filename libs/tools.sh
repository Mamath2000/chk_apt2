#!/usr/bin/env bash


tools::check_requirements() {
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
}

  # Vérifie que le script est exécuté en root
  tools::require_root() {
    if [ "$EUID" -ne 0 ]; then
      echo "Ce script doit être exécuté en root (sudo)." >&2
      exit 1
    fi
  }

  # Nettoie un hostname pour usage MQTT (remplace espaces et caractères non sûrs)
  tools::sanitize_hostname() {
    printf '%s' "$1" | sed -E 's/[[:space:]]+/_/g; s/[^A-Za-z0-9._-]/_/g'
  }

  # Persistance de l'état (version installée)
  tools::ensure_state_dir() {
    [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || true
  }

  tools::read_state() {
    INSTALLED_VERSION="1.0.0"
    if [ -r "$STATE_FILE" ]; then
      v=$(jq -r '.installed_version // empty' "$STATE_FILE" 2>/dev/null || true)
      if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        INSTALLED_VERSION="$v"
      fi
    else
      tools::ensure_state_dir
      echo "{\"installed_version\": \"$INSTALLED_VERSION\"}" > "$STATE_FILE" 2>/dev/null || true
    fi
  }

  tools::write_state() {
    local ver="$1"
    tools::ensure_state_dir
    jq -n --arg v "$ver" '{installed_version: $v}' > "$STATE_FILE" 2>/dev/null || echo "{\"installed_version\": \"$ver\"}" > "$STATE_FILE"
  }

  tools::bump_version() {
    local v="$1"
    if [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
      local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
      patch=$((patch + 1))
      printf "%s.%s.%s" "$major" "$minor" "$patch"
    else
      echo "1.0.1"
    fi
  }


tools::check_upgrades() {
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