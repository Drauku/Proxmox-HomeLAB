#!/usr/bin/env bash
set -euo pipefail

LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
MODEL_DIR="${MODEL_DIR:-$HOME/models}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-$HOME/.config/systemd/user}"
SERVICE_NAME="${SERVICE_NAME:-llama-server.service}"
SERVICE_PORT="${SERVICE_PORT:-8080}"
DEFAULT_MODEL_FILE="${DEFAULT_MODEL_FILE:-$MODEL_DIR/model.gguf}"
HOST="${HOST:-0.0.0.0}"
CUDA_KEYRING_URL="${CUDA_KEYRING_URL:-https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb}"
SOURCES_FILE="${SOURCES_FILE:-/etc/apt/sources.list.d/debian.sources}"

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die() { printf '[-] %s\n' "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

ensure_nonfree_components() {
  [[ -f "$SOURCES_FILE" ]] || die "$SOURCES_FILE not found. This script expects Debian deb822 sources."
  log "Ensuring Debian sources include contrib, non-free, and non-free-firmware..."
  sudo python3 - "$SOURCES_FILE" <<'PYEOF'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
lines = []
for line in text.splitlines():
    if line.startswith('Components:'):
        lines.append('Components: main contrib non-free non-free-firmware')
    else:
        lines.append(line)
path.write_text('\n'.join(lines) + '\n')
PYEOF
}

apt_install_base() {
  log "Installing base packages..."
  sudo apt update
  sudo apt install -y linux-headers-$(uname -r) build-essential dkms git cmake ninja-build curl ca-certificates pkg-config
}

ensure_nvidia_driver() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    log "Installing NVIDIA driver..."
    sudo apt install -y nvidia-driver
  fi
  require_cmd nvidia-smi
  log "nvidia-smi output:"
  nvidia-smi || true
}

ensure_cuda_repo() {
  if ! dpkg -l | grep -q '^ii[[:space:]]\+cuda-keyring[[:space:]]'; then
    log "Adding NVIDIA CUDA repository..."
    curl -fsSL "$CUDA_KEYRING_URL" -o /tmp/cuda-keyring.deb
    sudo dpkg -i /tmp/cuda-keyring.deb
    rm -f /tmp/cuda-keyring.deb
    sudo apt update
  fi
}

install_cuda_toolkit() {
  log "Installing CUDA toolkit..."
  sudo apt install -y cuda-toolkit
}

clone_or_update_llama() {
  if [[ ! -d "$LLAMA_DIR/.git" ]]; then
    log "Cloning llama.cpp into $LLAMA_DIR..."
    git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
  else
    log "Updating existing llama.cpp checkout..."
    git -C "$LLAMA_DIR" pull --ff-only
  fi
}

build_llama() {
  log "Building llama.cpp with CUDA support..."
  cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" -G Ninja -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
  cmake --build "$LLAMA_DIR/build" --parallel "$(nproc)" --target llama-cli llama-server
}

write_service() {
  mkdir -p "$SYSTEMD_UNIT_DIR" "$MODEL_DIR"
  cat > "$SYSTEMD_UNIT_DIR/$SERVICE_NAME" <<EOF2
[Unit]
Description=llama.cpp server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$LLAMA_DIR/build/bin/llama-server --host $HOST --port $SERVICE_PORT --model \${LLAMA_MODEL:-$DEFAULT_MODEL_FILE} \${LLAMA_EXTRA_ARGS:-}
Restart=on-failure
RestartSec=5
Environment=HOME=%h
WorkingDirectory=%h

[Install]
WantedBy=default.target
EOF2
}

enable_service() {
  log "Reloading user systemd daemon..."
  systemctl --user daemon-reload
  log "Enabling and starting $SERVICE_NAME ..."
  systemctl --user enable --now "$SERVICE_NAME"
}

print_hints() {
  cat <<EOF2

Manual server start example:
  "$LLAMA_DIR/build/bin/llama-server" --host "$HOST" --port "$SERVICE_PORT" --model "$DEFAULT_MODEL_FILE"

Suggested model download command:
  huggingface-cli download REPO_ID FILENAME --local-dir "$MODEL_DIR"

User service management:
  systemctl --user status $SERVICE_NAME
  systemctl --user restart $SERVICE_NAME
  journalctl --user -u $SERVICE_NAME -f

If you want the user service to survive logout:
  sudo loginctl enable-linger "$USER"
EOF2
}

main() {
  ensure_nonfree_components
  apt_install_base
  ensure_nvidia_driver
  ensure_cuda_repo
  install_cuda_toolkit
  clone_or_update_llama
  build_llama
  write_service
  enable_service
  log "llama.cpp installation complete."
  print_hints
}

main "$@"
