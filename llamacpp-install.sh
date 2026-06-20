#!/usr/bin/env bash
set -euo pipefail

LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
MODEL_DIR="${MODEL_DIR:-$HOME/models}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-$HOME/.config/systemd/user}"
SERVICE_NAME="${SERVICE_NAME:-llama-server.service}"
SERVICE_PORT="${SERVICE_PORT:-8080}"
BUILD_DIR="${BUILD_DIR:-$LLAMA_DIR/build-ninja}"
DEFAULT_MODEL_FILE="${DEFAULT_MODEL_FILE:-$MODEL_DIR/model.gguf}"
HOST="${HOST:-0.0.0.0}"
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

install_debian_nvidia_cuda() {
  log "Installing Debian-packaged NVIDIA driver, CUDA toolkit, and build prerequisites..."
  sudo apt update
  sudo apt install -y \
    linux-headers-$(uname -r) \
    build-essential \
    dkms \
    mokutil \
    git \
    cmake \
    ninja-build \
    pkg-config \
    ca-certificates \
    curl \
    python3 \
    python3-pip \
    python3-venv \
    pipx \
    nvidia-driver \
    nvidia-cuda-toolkit \
    nvidia-cuda-dev
}

install_hf_cli() {
  log "Installing Hugging Face CLI with pipx..."
  pipx install --force huggingface_hub
  pipx ensurepath
  if command -v hf >/dev/null 2>&1; then
    HF_CMD="hf"
  elif command -v huggingface-cli >/dev/null 2>&1; then
    HF_CMD="huggingface-cli"
  else
    HF_CMD=""
  fi
}

check_cuda_stack() {
  require_cmd nvidia-smi
  require_cmd nvcc
  log "nvidia-smi output:"
  nvidia-smi || true
  log "nvcc version:"
  nvcc --version || true
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
  log "Building llama.cpp with CUDA support in $BUILD_DIR ..."
  cmake -S "$LLAMA_DIR" -B "$BUILD_DIR" -G Ninja \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_COMPILER=/usr/bin/nvcc \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "$BUILD_DIR" --parallel "$(nproc)" --target llama-cli llama-server
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
ExecStart=$BUILD_DIR/bin/llama-server --host $HOST --port $SERVICE_PORT --model \${LLAMA_MODEL:-$DEFAULT_MODEL_FILE} \${LLAMA_EXTRA_ARGS:-}
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
  systemctl --user enable --now "$SERVICE_NAME"
}

print_hints() {
  cat <<EOF2

Manual server start example:
  "$BUILD_DIR/bin/llama-server" --host "$HOST" --port "$SERVICE_PORT" --model "$DEFAULT_MODEL_FILE"

Suggested model download command:
  $HF_CMD download REPO_ID FILENAME --local-dir "$MODEL_DIR"

PATH note:
  pipx ensurepath may require opening a new shell before plain '$HF_CMD' works.
  Until then, use ~/.local/bin/$HF_CMD

User service management:
  systemctl --user status $SERVICE_NAME
  systemctl --user restart $SERVICE_NAME
  journalctl --user -u $SERVICE_NAME -f

Secure Boot note: only relevant if Secure Boot is enabled inside the VM's guest firmware. If Secure Boot is off, you can ignore this. If it is on, Debian's NVIDIA DKMS modules may require MOK enrollment/signing before nvidia-smi works.
If you want the user service to survive logout:
  sudo loginctl enable-linger "$USER"
EOF2
}

main() {
  ensure_nonfree_components
  install_debian_nvidia_cuda
  install_hf_cli
  check_cuda_stack
  clone_or_update_llama
  build_llama
  write_service
  enable_service
  log "llama.cpp installation complete."
  print_hints
}

main "$@"
