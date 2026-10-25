#!/usr/bin/env bash

set -euo pipefail

readonly UNIO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEFAULT_IMAGE_REPOSITORY="abhi3700/unio"

image="${UNIO_IMAGE:-${DEFAULT_IMAGE_REPOSITORY}:latest}"
using_default_image=true
if [[ -n "${UNIO_IMAGE:-}" ]]; then
	using_default_image=false
fi
container_name="${UNIO_CONTAINER_NAME:-unio}"
volume_name="${UNIO_VOLUME_NAME:-unio-data}"
host_port="${UNIO_PORT:-34567}"
action="start"
force_setup=false
pull_image=true
docker_bin=""
docker_context=""
brew_bin=""
password_tmp=""

usage() {
	cat <<'EOF'
Pull and run the Unio wallet container for this machine's architecture.

Usage:
  ./scripts/docker-run.sh [options]
  ./scripts/docker-run.sh --setup
  ./scripts/docker-run.sh --status | --logs | --stop

Options:
  --image <image>       Multi-architecture image (default: abhi3700/unio:latest)
  --port <port>         Host loopback port (default: 34567)
  --setup               Open the TUI before starting the signing server
  --no-pull             Use an image already present in the Docker engine
  --status              Show the managed container and health status
  --logs                Follow the managed container logs
  --stop                Stop the managed container without deleting wallet data
  -h, --help            Show this help

Environment equivalents:
  UNIO_IMAGE, UNIO_PORT, UNIO_CONTAINER_NAME, UNIO_VOLUME_NAME,
  UNIO_PASSWORD_FILE, UNIO_DOCKER_CONFIG_DIR, UNIO_RECOVERY_DIR,
  UNIO_IMAGE_VERSION

Docker selects linux/amd64 or linux/arm64 automatically from the shared image
manifest. If the shared latest manifest has not been published yet, the default
image falls back to this checkout's native commit tag, then latest-amd64 or
latest-arm64. On macOS, the launcher discovers or installs the Homebrew Docker
CLI and Colima, then starts Colima when no Docker daemon is available. Linux
hosts must already have an accessible Docker engine.

The first run opens the interactive TUI for secure wallet initialization. When
asked where to save the recovery backup, choose the custom directory
`/data/recovery`; the launcher copies it to the host after setup.
EOF
}

die() {
	echo "Error: $*" >&2
	exit 1
}

cleanup() {
	if [[ -n "$password_tmp" && -f "$password_tmp" ]]; then
		rm -f -- "$password_tmp"
	fi
}

trap cleanup EXIT

require_value() {
	local option="$1"
	local value="${2:-}"
	[[ -n "$value" && "$value" != --* ]] || die "${option} requires a value."
}

select_action() {
	local requested="$1"
	if [[ "$action" != "start" ]]; then
		die "Choose only one of --status, --logs, or --stop."
	fi
	action="$requested"
}

find_brew() {
	local candidate=""

	if command -v brew >/dev/null 2>&1; then
		brew_bin="$(command -v brew)"
		return 0
	fi

	for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
		if [[ -x "$candidate" ]]; then
			brew_bin="$candidate"
			return 0
		fi
	done

	return 1
}

install_homebrew_formula() {
	local formula="$1"

	[[ "$(uname -s)" == "Darwin" ]] ||
		die "Automatic installation of '${formula}' is supported only on macOS."
	find_brew ||
		die "Homebrew is required to install '${formula}'. Install Homebrew, then rerun this launcher."

	if "$brew_bin" list --formula "$formula" >/dev/null 2>&1; then
		return
	fi

	echo "Installing ${formula} with Homebrew..."
	"$brew_bin" install "$formula"
}

locate_docker_cli() {
	local docker_prefix=""
	local candidate=""

	if command -v docker >/dev/null 2>&1; then
		docker_bin="$(command -v docker)"
		return 0
	fi

	for candidate in /opt/homebrew/opt/docker/bin/docker /usr/local/opt/docker/bin/docker; do
		if [[ -x "$candidate" ]]; then
			docker_bin="$candidate"
			return 0
		fi
	done

	if find_brew; then
		docker_prefix="$("$brew_bin" --prefix docker 2>/dev/null || true)"
		candidate="${docker_prefix}/bin/docker"
		if [[ -n "$docker_prefix" && -x "$candidate" ]]; then
			docker_bin="$candidate"
			return 0
		fi
	fi

	return 1
}

ensure_docker_cli() {
	if locate_docker_cli; then
		if [[ "$docker_bin" != "$(command -v docker 2>/dev/null || true)" ]]; then
			echo "Using Homebrew Docker CLI: ${docker_bin}"
		fi
		return
	fi

	if [[ "$(uname -s)" != "Darwin" ]]; then
		die "Docker is required. Install and start Docker, then rerun this launcher."
	fi

	install_homebrew_formula docker
	locate_docker_cli || die "Homebrew installed Docker, but its CLI could not be located."
	echo "Using Homebrew Docker CLI: ${docker_bin}"
}

docker_cli() {
	if [[ -n "$docker_context" ]]; then
		"$docker_bin" --context "$docker_context" "$@"
	else
		"$docker_bin" "$@"
	fi
}

locate_colima() {
	local candidate=""

	if command -v colima >/dev/null 2>&1; then
		command -v colima
		return 0
	fi

	for candidate in /opt/homebrew/bin/colima /usr/local/bin/colima; do
		if [[ -x "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	done

	return 1
}

ensure_docker_daemon() {
	local attempt
	local colima_bin=""
	local docker_bin_dir=""

	if docker_cli info >/dev/null 2>&1; then
		return
	fi

	if "$docker_bin" --context colima info >/dev/null 2>&1; then
		docker_context="colima"
		echo "Using the running Colima Docker context."
		return
	fi

	if [[ "$(uname -s)" != "Darwin" ]]; then
		die "The Docker daemon is unavailable. Start Docker and ensure this user can access it."
	fi

	if ! colima_bin="$(locate_colima)"; then
		install_homebrew_formula colima
		colima_bin="$(locate_colima)" ||
			die "Homebrew installed Colima, but its CLI could not be located."
	fi

	echo "Docker daemon is unavailable; starting Colima..."
	docker_bin_dir="$(dirname "$docker_bin")"
	env PATH="${docker_bin_dir}:$(dirname "$colima_bin"):${PATH}" "$colima_bin" start ||
		die "Colima failed to start."
	docker_context="colima"

	for attempt in {1..30}; do
		if docker_cli info >/dev/null 2>&1; then
			return
		fi
		sleep 1
	done

	die "Colima started, but its Docker daemon did not become ready."
}

try_native_image_fallback() {
	local operation="$1"
	local version="${UNIO_IMAGE_VERSION:-}"
	local candidate=""
	local native_latest="${DEFAULT_IMAGE_REPOSITORY}:latest-${engine_architecture}"
	local -a candidates=()

	if [[ -z "$version" ]]; then
		version="$(git -C "$UNIO_ROOT" rev-parse --short=12 HEAD 2>/dev/null || true)"
	fi
	if [[ "$version" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
		candidates+=("${DEFAULT_IMAGE_REPOSITORY}:${version}-${engine_architecture}")
	fi
	if [[ "${candidates[0]:-}" != "$native_latest" ]]; then
		candidates+=("$native_latest")
	fi

	for candidate in "${candidates[@]}"; do
		if [[ "$operation" == "pull" ]]; then
			echo "Shared image '${image}' is unavailable; trying native image '${candidate}'."
			if ! docker_cli pull "$candidate"; then
				continue
			fi
		elif ! docker_cli image inspect "$candidate" >/dev/null 2>&1; then
			continue
		fi

		image="$candidate"
		echo "Using native image ${image} for linux/${engine_architecture}."
		return 0
	done

	return 1
}

managed_container_exists() {
	docker_cli container inspect "$container_name" >/dev/null 2>&1
}

require_managed_container() {
	local managed=""

	managed="$(
		docker_cli container inspect \
			--format '{{ index .Config.Labels "io.unifi.unio.launcher" }}' \
			"$container_name" 2>/dev/null || true
	)"
	[[ "$managed" == "true" ]] ||
		die "Container '${container_name}' exists but was not created by this launcher. Choose another name with UNIO_CONTAINER_NAME."
}

remove_managed_container() {
	if ! managed_container_exists; then
		return
	fi

	require_managed_container
	echo "Replacing the existing managed container; wallet data remains in '${volume_name}'."
	docker_cli rm --force "$container_name" >/dev/null
}

wallet_ready() {
	docker_cli run --rm \
		--network none \
		--entrypoint /bin/sh \
		--volume "${volume_name}:/data" \
		"$image" \
		-c 'test -s /data/wallet-v1.json && test -s /data/unio-access-keys-v1.json' \
		>/dev/null 2>&1
}

recovery_backup_exists() {
	docker_cli run --rm \
		--network none \
		--entrypoint /bin/sh \
		--volume "${volume_name}:/data:ro" \
		"$image" \
		-c 'set -- /data/recovery/unio-recovery-*.txt; test -e "$1"' \
		>/dev/null 2>&1
}

copy_recovery_backups() {
	local copy_container="${container_name}-recovery-copy-$$"

	if ! recovery_backup_exists; then
		return
	fi

	mkdir -p "$recovery_dir"
	chmod 700 "$recovery_dir"
	docker_cli create \
		--name "$copy_container" \
		--entrypoint /bin/true \
		--volume "${volume_name}:/data:ro" \
		"$image" >/dev/null

	if ! docker_cli cp "${copy_container}:/data/recovery/." "$recovery_dir"; then
		docker_cli rm --force "$copy_container" >/dev/null 2>&1 || true
		die "Unable to copy the recovery backup to '${recovery_dir}'. It remains under /data/recovery in the Docker volume."
	fi

	docker_cli rm "$copy_container" >/dev/null
	chmod -R go-rwx "$recovery_dir"
	echo "Recovery backup copied to: ${recovery_dir}"
}

run_tui_setup() {
	local setup_container="${container_name}-setup-$$"

	[[ -t 0 && -t 1 ]] ||
		die "First-time wallet setup needs an interactive terminal. Run this launcher directly from a terminal."

	echo
	echo "Opening Unio wallet setup."
	echo "When asked for the recovery-backup location, choose Custom directory and enter:"
	echo "  /data/recovery"
	echo

	docker_cli run --rm --interactive --tty \
		--init \
		--name "$setup_container" \
		--label "io.unifi.unio.launcher=true" \
		--network none \
		--env UNIO_DATA_DIR=/data \
		--volume "${volume_name}:/data" \
		"$image" tui
}

write_password_file() {
	local wallet_password=""
	local password_parent=""

	case "$password_file" in
		/*) ;;
		*) die "UNIO_PASSWORD_FILE must be an absolute path." ;;
	esac

	password_parent="$(dirname "$password_file")"
	mkdir -p "$password_parent"
	chmod 700 "$password_parent"

	echo
	IFS= read -r -s -p "Enter the same wallet password for unattended container restarts: " wallet_password
	echo
	[[ -n "$wallet_password" ]] || die "The wallet password cannot be empty."

	password_tmp="${password_file}.tmp.$$"
	(umask 077 && printf '%s\n' "$wallet_password" >"$password_tmp")
	wallet_password=""
	mv -f -- "$password_tmp" "$password_file"
	password_tmp=""
	chmod 600 "$password_file"
}

start_server() {
	local container_id=""
	local attempt

	remove_managed_container

	if ! container_id="$(
		docker_cli run --detach \
			--name "$container_name" \
			--label "io.unifi.unio.launcher=true" \
			--init \
			--restart unless-stopped \
			--publish "127.0.0.1:${host_port}:34567" \
			--env UNIO_DATA_DIR=/data \
			--volume "${volume_name}:/data" \
			--mount "type=bind,src=${password_file},dst=/run/secrets/unio_password,readonly" \
			"$image"
	)"; then
		docker_cli rm --force "$container_name" >/dev/null 2>&1 || true
		die "Unable to start Unio. Check whether host port ${host_port} is already in use."
	fi

	for attempt in {1..30}; do
		if docker_cli exec "$container_id" \
			unio health --address 127.0.0.1:34567 >/dev/null 2>&1; then
			echo
			echo "Unio is ready: http://127.0.0.1:${host_port}/unio/server"
			echo "Container: ${container_name}"
			echo "Wallet volume: ${volume_name}"
			echo "Run this launcher with --logs, --status, --setup, or --stop to manage it."
			return
		fi

		if [[ "$(docker_cli container inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || true)" != "true" ]]; then
			break
		fi
		sleep 1
	done

	echo "Unio did not become healthy. Recent container logs:" >&2
	docker_cli logs --tail 40 "$container_name" >&2 || true
	die "Verify that the saved password matches the wallet password, then rerun the launcher."
}

while (($# > 0)); do
	case "$1" in
		--image)
			require_value "$1" "${2:-}"
			image="$2"
			using_default_image=false
			shift 2
			;;
		--port)
			require_value "$1" "${2:-}"
			host_port="$2"
			shift 2
			;;
		--setup)
			force_setup=true
			shift
			;;
		--no-pull)
			pull_image=false
			shift
			;;
		--status)
			select_action status
			shift
			;;
		--logs)
			select_action logs
			shift
			;;
		--stop)
			select_action stop
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*) die "Unknown option: $1" ;;
	esac
done

[[ -n "$image" && "$image" != *[[:space:]]* ]] || die "Invalid image reference."
[[ "$container_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]+$ ]] || die "Invalid container name."
[[ "$volume_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]+$ ]] || die "Invalid volume name."
[[ "$host_port" =~ ^[0-9]+$ ]] || die "Port must be a number."
((host_port >= 1 && host_port <= 65535)) || die "Port must be between 1 and 65535."

if [[ -n "${UNIO_DOCKER_CONFIG_DIR:-}" ]]; then
	config_dir="$UNIO_DOCKER_CONFIG_DIR"
elif [[ "$(uname -s)" == "Darwin" ]]; then
	config_dir="${HOME}/Library/Application Support/com.UniFi.Unio/docker"
else
	config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/unio/docker"
fi

password_file="${UNIO_PASSWORD_FILE:-${config_dir}/unio-password.txt}"
recovery_dir="${UNIO_RECOVERY_DIR:-${HOME}/Downloads/Unio Recovery}"

ensure_docker_cli
ensure_docker_daemon

case "$action" in
	status)
		if ! managed_container_exists; then
			echo "Unio is not running."
			exit 0
		fi
		require_managed_container
		docker_cli ps --all --filter "name=^/${container_name}$"
		docker_cli exec "$container_name" \
			unio health --address 127.0.0.1:34567 2>/dev/null || true
		exit 0
		;;
	logs)
		managed_container_exists || die "Unio container '${container_name}' does not exist."
		require_managed_container
		docker_cli logs --follow "$container_name"
		exit 0
		;;
	stop)
		if ! managed_container_exists; then
			echo "Unio is already stopped."
			exit 0
		fi
		require_managed_container
		docker_cli stop "$container_name" >/dev/null
		echo "Unio stopped. Wallet data remains in Docker volume '${volume_name}'."
		exit 0
		;;
esac

engine_architecture="$(docker_cli info --format '{{.Architecture}}')" ||
	die "Could not determine the Docker engine architecture."
case "$engine_architecture" in
	amd64 | x86_64) engine_architecture="amd64" ;;
	arm64 | aarch64) engine_architecture="arm64" ;;
	*) die "Unsupported Docker architecture '${engine_architecture}'. Unio images support AMD64 and ARM64." ;;
esac

echo "Using ${image} for linux/${engine_architecture}."
if [[ "$pull_image" == true ]]; then
	if [[ "$using_default_image" == true ]]; then
		if ! docker_cli pull "$image" 2>/dev/null && ! try_native_image_fallback pull; then
			die "Unable to pull '${image}'. Publish this architecture or choose an existing image with --image."
		fi
	elif ! docker_cli pull "$image"; then
		die "Unable to pull '${image}'. Publish this architecture or choose an existing image with --image."
	fi
elif ! docker_cli image inspect "$image" >/dev/null 2>&1; then
	if [[ "$using_default_image" != true ]] || ! try_native_image_fallback local; then
		die "Image '${image}' is not present locally. Remove --no-pull or choose an existing image."
	fi
fi

docker_cli volume create "$volume_name" >/dev/null
wallet_was_ready=false
if wallet_ready; then
	wallet_was_ready=true
fi

if [[ "$force_setup" == true || "$wallet_was_ready" == false ]]; then
	remove_managed_container
	run_tui_setup
	wallet_ready ||
		die "Wallet setup is incomplete. Initialize or import a wallet and create at least one access key, then quit the TUI."
	copy_recovery_backups
fi

if [[ "$wallet_was_ready" == false || ! -s "$password_file" ]]; then
	write_password_file
else
	chmod 600 "$password_file"
fi

start_server
