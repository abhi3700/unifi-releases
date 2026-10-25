#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SOURCE_BINARY="${SCRIPT_DIR}/unio"
readonly INSTALL_DIR="${HOME:?HOME is not set}/.local/bin"
readonly TARGET_BINARY="${INSTALL_DIR}/unio"
readonly PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

die() {
	echo "Error: $*" >&2
	exit 1
}

path_contains() {
	case ":${1}:" in
		*":${2}:"*) return 0 ;;
		*) return 1 ;;
	esac
}

append_once() {
	local file="$1"
	local line="$2"

	mkdir -p "$(dirname "$file")"
	touch "$file"
	if ! grep -Fqx "$line" "$file"; then
		printf '\n# Added by the Unio installer.\n%s\n' "$line" >>"$file"
	fi
}

[[ -f "$SOURCE_BINARY" ]] || die "Run install.sh from the extracted Unio archive."
[[ -x "$SOURCE_BINARY" ]] || die "The bundled unio binary is not executable."
command -v install >/dev/null 2>&1 || die "The 'install' command is required."

mkdir -p "$INSTALL_DIR"
install -m 0755 "$SOURCE_BINARY" "$TARGET_BINARY"
echo "Installed Unio to ${TARGET_BINARY}."

if path_contains "${PATH:-}" "$INSTALL_DIR"; then
	echo "${INSTALL_DIR} is already on PATH."
else
	shell_name="$(basename "${SHELL:-sh}")"
	case "$shell_name" in
		zsh)
			if [[ "$(uname -s)" == Darwin ]]; then
				profile="${HOME}/.zprofile"
			else
				profile="${HOME}/.zshrc"
			fi
			append_once "$profile" "$PATH_LINE"
			;;
		bash)
			if [[ "$(uname -s)" == Darwin ]]; then
				profile="${HOME}/.bash_profile"
			else
				profile="${HOME}/.bashrc"
			fi
			append_once "$profile" "$PATH_LINE"
			;;
		fish)
			profile="${HOME}/.config/fish/config.fish"
			append_once "$profile" 'fish_add_path --global "$HOME/.local/bin"'
			;;
		*)
			profile="${HOME}/.profile"
			append_once "$profile" "$PATH_LINE"
			;;
	esac
	echo "Added ${INSTALL_DIR} to PATH in ${profile}."
	echo "Open a new terminal, then run: unio"
fi
