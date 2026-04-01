#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/libs/version.sh"

version::init_paths "$SCRIPT_DIR"
current_version="$(version::read)"
next_version="$(version::bump_release "$current_version")"
version::write "$next_version"

git -C "$SCRIPT_DIR" add version
git -C "$SCRIPT_DIR" commit -m "chore: bump version to $next_version"
git -C "$SCRIPT_DIR" push "$@"

echo "Version poussée: $next_version"