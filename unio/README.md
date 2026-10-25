# Unio User Guide

Unio is a self-custodial EVM wallet available through the UniFi web app, an interactive terminal
application, or a Docker-managed local signing service. Your wallet, recovery phrase, private key,
password, and agent access keys remain on your machine.

## Choose how to use Unio

- **Web app:** Follow the [Unio web app guide](https://docs.payunifi.com/webapp/unio) to use Unio
  through UniFi in your browser.
- **Terminal app:** Install a native TUI package for macOS, Linux, or Windows.
- **Docker:** Run the local signing service from a managed Linux AMD64/ARM64 container.

This release folder contains the terminal and Docker options:

- `tui/` — native terminal applications for macOS, Linux, and Windows.
- `docker/` — a launcher for the Linux AMD64/ARM64 Docker image.

Choose the TUI archive that matches your operating system and processor:

| System | Intel/AMD | ARM |
| --- | --- | --- |
| macOS | `unio-macos-amd64.tar.gz` | `unio-macos-arm64.tar.gz` |
| Linux | `unio-linux-amd64.tar.gz` | `unio-linux-arm64.tar.gz` |
| Windows | `unio-windows-amd64.zip` | `unio-windows-arm64.zip` |

On macOS or Linux, run `uname -m`. `x86_64` means AMD64; `arm64` or `aarch64` means ARM64. On
Windows PowerShell, `$env:PROCESSOR_ARCHITECTURE` reports `AMD64` or `ARM64`.

## Install the terminal application

### macOS or Linux

Open a terminal in the `tui/` directory. Verify the download before extracting it:

```sh
# macOS example
shasum -a 256 -c unio-macos-arm64.tar.gz.sha256

# Linux example
sha256sum -c unio-linux-amd64.tar.gz.sha256
```

Extract the matching archive into a new directory and run its installer:

```sh
mkdir unio-install
tar -xzf unio-macos-arm64.tar.gz -C unio-install
cd unio-install
./install.sh
```

Replace the archive name with your selected package. The installer places `unio` in
`~/.local/bin`; open a new terminal if your shell path was updated.

### Windows

Open PowerShell in the `tui/` directory and verify the archive:

```powershell
$Archive = "unio-windows-amd64.zip"
$Expected = ((Get-Content "$Archive.sha256") -split "\s+")[0]
$Actual = (Get-FileHash -Algorithm SHA256 $Archive).Hash.ToLowerInvariant()
if ($Actual -ne $Expected) { throw "Unio archive checksum mismatch" }
```

Extract and install it:

```powershell
Expand-Archive -Force $Archive -DestinationPath unio-install
powershell -ExecutionPolicy Bypass -File .\unio-install\install.ps1
```

The installer places `unio.exe` under `%LOCALAPPDATA%\Unio\bin` and adds that directory to your
user `PATH`. Open a new terminal before using `unio` if necessary.

## Set up and use the wallet

Start the terminal application from any directory:

```sh
unio
```

The guided interface lets you:

1. Create and unlock the encrypted local vault.
2. Create a new EVM wallet or import an existing recovery phrase.
3. Save the recovery backup in a secure offline location.
4. Use the wallet interactively or configure Agent Mode.

The recovery backup contains the recovery phrase and private key. Never share it, commit it to
source control, or leave it in a cloud-synchronized folder. A newly created agent access key is
shown only once, so store it securely when prompted.

## Run with Docker

The launcher supports AMD64 and ARM64 macOS/Linux hosts. Docker must be installed; on macOS, the
launcher can use Homebrew and Colima when Docker Desktop is unavailable.

From the release folder, run:

```sh
cd docker
./docker-run.sh
```

The first run opens the setup interface, creates a persistent Docker volume, and starts the local
signing service on `127.0.0.1:34567`. When asked where to save the recovery backup, choose the
custom directory `/data/recovery`; the launcher copies it to the host after setup.

Useful management commands:

```sh
./docker-run.sh --status
./docker-run.sh --logs
./docker-run.sh --setup
./docker-run.sh --stop
```

Use `--setup` when you need to manage the wallet or access keys later. It stops the headless
service, opens the terminal interface, and restarts the service after you exit. Wallet data remains
in the persistent `unio-data` Docker volume.

## Connect an agent

Create an access key in Agent Mode, then configure the local agent with:

```sh
export UNIO_SERVER_URL=http://127.0.0.1:34567/unio/server
export UNIO_ACCESS_KEY='your-one-time-access-key'
```

Requests use `Authorization: Bearer $UNIO_ACCESS_KEY`. Unio can sign EIP-191 personal messages,
EIP-712 typed data, and replay-protected legacy EVM transactions. It signs transactions locally
but does not broadcast them.

Keep the service bound to loopback. Do not expose port `34567` directly to a shared network or the
internet.

## Help

For terminal options, run `unio --help`. For Docker launcher options and configurable paths, run
`./docker-run.sh --help` from the `docker/` directory.
