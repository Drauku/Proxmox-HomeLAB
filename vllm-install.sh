#!/usr/bin/env bash
set -euo pipefail

VENV_DIR="${VENV_DIR:-$HOME/vllm-env}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-$HOME/.config/systemd/user}"
SERVICE_NAME="${SERVICE_NAME:-vllm-server.service}"
SERVICE_PORT="${SERVICE_PORT:-8000}"
DEFAULT_MODEL="${DEFAULT_MODEL:-meta-llama/Llama-3.1-8B-Instruct}"
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

ensure_debian_nvidia_stack() {
  log "Installing Debian-packaged NVIDIA driver, CUDA toolkit, and build prerequisites..."
  sudo apt update
  sudo apt install -y \
    linux-headers-$(uname -r) \
    build-essential \
    dkms \
    mokutil \
    git \
    curl \
    ca-certificates \
    python3 \
    python3-venv \
    python3-pip \
    nvidia-driver \
    nvidia-cuda-toolkit
}

require_nvidia() {
  log "Checking for NVIDIA driver..."
  require_cmd nvidia-smi
  log "nvidia-smi output:"
  nvidia-smi || true
}

get_cuda_driver_version() {
  nvidia-smi | awk '/CUDA Version:/ {print $NF; exit}'
}

choose_pytorch_cuda() {
  local cuda_driver_ver="${1:-}"
  local drv_major drv_minor

  if [[ -n "$cuda_driver_ver" ]]; then
    drv_major=${cuda_driver_ver%%.*}
    drv_minor=${cuda_driver_ver#*.}
    drv_minor=${drv_minor%%.*}

    if (( drv_major > 12 )) || (( drv_major == 12 && drv_minor >= 1 )); then
      PYTORCH_CUDA_TAG="cu121"
    else
      PYTORCH_CUDA_TAG="cu118"
    fi
  else
    PYTORCH_CUDA_TAG="cu118"
  fi

  PYTORCH_INDEX_URL="https://download.pytorch.org/whl/${PYTORCH_CUDA_TAG}"
  log "Using PyTorch wheel channel ${PYTORCH_CUDA_TAG} (${PYTORCH_INDEX_URL})"
}

ensure_venv() {
  if [[ ! -d "$VENV_DIR" ]]; then
    log "Creating Python virtual environment at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  log "Upgrading pip..."
  pip install --upgrade pip setuptools wheel
  log "Installing Hugging Face CLI support in the venv..."
  pip install --upgrade huggingface_hub[cli]
  if command -v hf >/dev/null 2>&1; then
    HF_CMD="hf"
  elif command -v huggingface-cli >/dev/null 2>&1; then
    HF_CMD="huggingface-cli"
  else
    HF_CMD=""
  fi
}

install_pytorch_and_vllm() {
  log "Installing PyTorch from $PYTORCH_INDEX_URL ..."
  pip install torch torchvision torchaudio --index-url "$PYTORCH_INDEX_URL"

  log "Verifying PyTorch CUDA availability..."
  python - <<'PYEOF'
import torch
print('torch.version:', torch.__version__)
print('CUDA available:', torch.cuda.is_available())
if torch.cuda.is_available():
    print('GPU:', torch.cuda.get_device_name(0))
else:
    raise SystemExit('CUDA is not available in PyTorch; check driver/toolkit/wheel.')
PYEOF

  log "Installing vLLM..."
  pip install vllm
}

write_wrapper() {
  local wrapper="$VENV_DIR/run-vllm-server.sh"
  cat > "$wrapper" <<EOF2
#!/usr/bin/env bash
set -euo pipefail
source "$VENV_DIR/bin/activate"
exec python -m vllm.entrypoints.openai_api_server \
  --host "$HOST" \
  --port "$SERVICE_PORT" \
  --model "\${VLLM_MODEL:-$DEFAULT_MODEL}" \
  \${VLLM_EXTRA_ARGS:-}
EOF2
  chmod +x "$wrapper"
  WRAPPER_PATH="$wrapper"
}

write_service() {
  mkdir -p "$SYSTEMD_UNIT_DIR"
  cat > "$SYSTEMD_UNIT_DIR/$SERVICE_NAME" <<EOF2
[Unit]
Description=vLLM OpenAI-compatible server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$WRAPPER_PATH
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
  source "$VENV_DIR/bin/activate"
  python -m vllm.entrypoints.openai_api_server \
    --host "$HOST" \
    --port "$SERVICE_PORT" \
    --model "$DEFAULT_MODEL"

Suggested model download command:
  source "$VENV_DIR/bin/activate"
  $HF_CMD download "$DEFAULT_MODEL"

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
  ensure_debian_nvidia_stack
  require_nvidia
  require_cmd nvcc
  CUDA_DRIVER_VER="$(get_cuda_driver_version || true)"
  if [[ -n "${CUDA_DRIVER_VER:-}" ]]; then
    log "Detected CUDA driver version: $CUDA_DRIVER_VER"
  else
    warn "Could not parse CUDA driver version from nvidia-smi. Continuing with safe defaults."
  fi
  choose_pytorch_cuda "${CUDA_DRIVER_VER:-}"
  ensure_venv
  install_pytorch_and_vllm
  write_wrapper
  write_service
  enable_service
  log "vLLM installation complete."
  print_hints
}

main "$@"
