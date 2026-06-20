#!/usr/bin/env bash
set -euo pipefail

### CONFIG
VENV_DIR="$HOME/vllm-env"
SYSTEMD_UNIT_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="vllm-server.service"
SERVICE_PORT="8000"
# Default model (edit this later to whatever HF repo you like)
DEFAULT_MODEL="meta-llama/Llama-3.1-8B-Instruct"

echo "[*] Checking for NVIDIA driver..."
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "[-] nvidia-smi not found. Please run llamacpp-install.sh (or otherwise install driver/CUDA) first."
  exit 1
fi

echo "[*] nvidia-smi output:"
nvidia-smi || true

CUDA_DRIVER_VER=$(nvidia-smi | awk '/CUDA Version:/ {print $NF; exit}')
if [[ -z "${CUDA_DRIVER_VER:-}" ]]; then
  echo "[!] Could not parse CUDA driver version from nvidia-smi. Continuing with safe defaults."
else
  echo "[*] Detected CUDA driver version: $CUDA_DRIVER_VER"
fi

### Decide on PyTorch CUDA wheel
# Strategy:
#  - If driver CUDA >= 12.1 -> try cu121 wheels
#  - else -> fall back to cu118 wheels
# PyTorch publishes wheels per toolkit version; driver just needs to support that level. [web:61][web:67]
PYTORCH_VERSION=""
if [[ -n "${CUDA_DRIVER_VER:-}" ]]; then
  # crude numeric comparison: take major.minor
  DRV_MAJOR=${CUDA_DRIVER_VER%%.*}
  DRV_MINOR=${CUDA_DRIVER_VER#*.}
  DRV_MINOR=${DRV_MINOR%%.*}

  if (( DRV_MAJOR > 12 )) || (( DRV_MAJOR == 12 && DRV_MINOR >= 1 )); then
    PYTORCH_VERSION="cu121"
    echo "[*] Choosing PyTorch wheels for CUDA 12.1 (cu121)."
  else
    PYTORCH_VERSION="cu118"
    echo "[*] Driver CUDA < 12.1, using cu118 wheels."
  fi
else
  PYTORCH_VERSION="cu118"
  echo "[*] Falling back to cu118 wheels."
fi

$PYTORCH_INDEX_URL="https://download.pytorch.org/whl/$PYTORCH_VERSION"

echo "[*] Installing Python, venv, and basic build tools..."
sudo apt update
sudo apt install -y python3 python3-venv python3-pip build-essential

if [[ ! -d "$VENV_DIR" ]]; then
  echo "[*] Creating Python virtual environment at $VENV_DIR..."
  python3 -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

echo "[*] Upgrading pip..."
pip install --upgrade pip

echo "[*] Installing PyTorch with GPU support from $PYTORCH_INDEX_URL ..."
pip install torch torchvision torchaudio --index-url "$PYTORCH_INDEX_URL"

echo "[*] Verifying PyTorch CUDA availability..."
python - <<'EOF'
import torch
print("torch.version:", torch.__version__)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
else:
    raise SystemExit("CUDA is not available in PyTorch; check driver/toolkit/wheel.")
EOF

echo "[*] Installing vLLM..."
pip install vllm

echo "[*] vLLM installed in virtualenv $VENV_DIR."

echo
echo "Manual server start example:"
echo "  source \"$VENV_DIR/bin/activate\""
echo "  python -m vllm.entrypoints.openai_api_server \\"
echo "    --model \"$DEFAULT_MODEL\" \\"
echo "    --port $SERVICE_PORT"

### Create systemd user service for vLLM
echo "[*] Setting up systemd user service for vLLM..."
mkdir -p "$SYSTEMD_UNIT_DIR"

# We use a small wrapper to ensure the venv is activated in the service.
WRAPPER="$VENV_DIR/run-vllm-server.sh"
cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
source "$VENV_DIR/bin/activate"
exec python -m vllm.entrypoints.openai_api_server \\
  --model "$DEFAULT_MODEL" \\
  --port $SERVICE_PORT --host 0.0.0.0
EOF
chmod +x "$WRAPPER"

cat > "$SYSTEMD_UNIT_DIR/$SERVICE_NAME" <<EOF
[Unit]
Description=vLLM OpenAI-compatible server
After=network.target

[Service]
Type=simple
ExecStart=$WRAPPER
Restart=on-failure
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin

[Install]
WantedBy=default.target
EOF

echo "[*] systemd unit created at $SYSTEMD_UNIT_DIR/$SERVICE_NAME"
echo
echo "You can manage it with (user services):"
echo "  systemctl --user daemon-reload"
echo "  systemctl --user start $SERVICE_NAME"
echo "  systemctl --user status $SERVICE_NAME"

systemctl --user daemon-reload || true

read -r -p "Enable and start vllm-server.service now? (y/N) " ans
case "$ans" in
  y|Y)
    systemctl --user enable --now "$SERVICE_NAME"
    echo "[*] vllm-server.service enabled and started."
    ;;
  *)
    echo "[*] Skipping enable/start. You can start it later with:"
    echo "    systemctl --user start $SERVICE_NAME"
    ;;
esac


echo "[*] Done. vLLM is installed in $VENV_DIR."
