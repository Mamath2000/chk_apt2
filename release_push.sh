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

# If a GITHUB_TOKEN is present, use it for a non-interactive authenticated push
# by temporarily setting the origin URL to include the token (only for https:// remotes).
origin_url=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)
if [ -n "${GITHUB_TOKEN:-}" ] && printf '%s' "$origin_url" | grep -q '^https://'; then
	auth_url="${origin_url/https:\/\//https://x-access-token:${GITHUB_TOKEN}@}"
	# Temporarily replace origin with authenticated URL and push, then restore original URL.
	git -C "$SCRIPT_DIR" remote set-url origin "$auth_url"
	push_rc=0
	GIT_ASKPASS= VSCODE_GIT_IPC_HANDLE= VSCODE_GIT_ASKPASS_NODE= git -C "$SCRIPT_DIR" push "$@" || push_rc=$?
	# restore origin URL
	git -C "$SCRIPT_DIR" remote set-url origin "$origin_url"
	if [ "$push_rc" -ne 0 ]; then
		echo "git push a échoué (code $push_rc)" >&2
		exit "$push_rc"
	fi
else
	# Avoid using VSCode's askpass/socket helpers when running non-interactively
	GIT_ASKPASS= VSCODE_GIT_IPC_HANDLE= VSCODE_GIT_ASKPASS_NODE= git -C "$SCRIPT_DIR" push "$@"
fi

echo "Version poussée: $next_version"