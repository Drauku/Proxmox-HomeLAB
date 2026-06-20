#!/usr/bin/env bash
set -euo pipefail

### CONFIG
LLAMA_DIR="$HOME/llama.cpp"
MODEL_DIR="$HOME/models"
MODEL_URL="https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/TinyLlama-1.1B-Chat-v1.0.Q4_K_M.gguf"
MODEL_FILE="$MODEL_DIR/TinyLlama-1.1B-Chat-v1.0.Q4_K_M.gguf"
SYSTEMD_UNIT_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="llama-server.service"
SERVICE_PORT="8080"

echo "[*] Updating APT sources to enable contrib, non-free, non-free-firmware..."

DEBIAN_SOURCES="/etc/apt/sources.list.d/debian.sources"
if [[ ! -f "$DEBIAN_SOURCES" ]]; then
  echo "[-] $DEBIAN_SOURCES not found. This script assumes Debian 13 with deb822 sources."
  exit 1
fi

# Ensure Components includes contrib non-free non-free-firmware
sudo awk '
BEGIN { in_stanza=0 }
/^[[:space:]]*$/ { in_stanza=0 }
{
  if ($1 == "Types:" || $1 == "URIs:" || $1 == "Suites:" || $1 == "Components:" || $1 == "Signed-By:" ) in_stanza=1
}
$1 == "Components:" {
  has_contrib=index($0,"contrib")>0
  has_nonfree=index($0,"non-free ")>0 || match($0,/non-free$/)
  has_nffw=index($0,"non-free-firmware")>0
  if (!has_contrib || !has_nonfree || !has_nffw) {
    print "Components: main contrib non-free non-free-firmware"
    next
  }
}
{ print }
' "$DEBIAN_SOURCES" | sudo tee "$DEBIAN_SOURCES.tmp" >/dev/null

sudo mv "$DEBIAN_SOURCES.tmp" "$DEBIAN_SOURCES"

echo "[*] Updating package lists..."
sudo apt update

echo "[*] Installing kernel headers, build tools, and basic NVIDIA driver..."
sudo apt install -y linux-headers-$(uname -r) build-essential dkms

if ! command -v nvidia-smi >/dev/null 2>&1; then
  sudo apt install -y nvidia-driver
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "[-] nvidia-smi still not available. Check GPU passthrough / driver issues."
  exit 1
fi

echo "[*] nvidia-smi output:"
nvidia-smi || true

### Install NVIDIA CUDA Toolkit from NVIDIA repo (for best performance)
if ! dpkg -l | grep -q "cuda-keyring"; then
  echo "[*] Adding NVIDIA CUDA repository..."
  # This follows NVIDIA's CUDA Linux installation guide for Debian-like systems.
  # Docs: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/  [web:60]
  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb -o /tmp/cuda-keyring.deb
  sudo dpkg -i /tmp/cuda-keyring.deb
  rm /tmp/cuda-keyring.deb
  sudo apt update
fi

echo "[*] Installing CUDA toolkit from NVIDIA repo..."
sudo apt install -y cuda-toolkit

### Build llama.cpp with CUDA
echo "[*] Cloning llama.cpp into $LLAMA_DIR..."
if [[ ! -d "$LLAMA_DIR" ]]; then
  git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
else
  echo "[*] $LLAMA_DIR already exists, pulling latest changes..."
  git -C "$LLAMA_DIR" pull --ff-only
fi

echo "[*] Building llama.cpp with CUDA support..."
mkdir -p "$LLAMA_DIR/build"
cd "$LLAMA_DIR/build"

cmake .. -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
make -j"$(nproc)" llama-cli llama-server

echo "[*] llama.cpp build completed."

### Download tiny GGUF model for testing
echo "[*] Creating model directory at $MODEL_DIR..."
mkdir -p "$MODEL_DIR"

if [[ ! -f "$MODEL_FILE" ]]; then
  echo "[*] Downloading TinyLlama GGUF test model..."
  curl -L "$MODEL_URL" -o "$MODEL_FILE"
else
  echo "[*] Model file already exists at $MODEL_FILE, skipping download."
fi

echo "[*] Quick test command (manual):"
echo "  $LLAMA_DIR/build/bin/llama-cli -m \"$MODEL_FILE\" -p \"Hello from llama.cpp on Debian 13\""

### Create systemd user service
echo "[*] Setting up systemd user service for llama-server..."
mkdir -p "$SYSTEMD_UNIT_DIR"

cat > "$SYSTEMD_UNIT_DIR/$SERVICE_NAME" <<EOF
[Unit]
Description=llama.cpp HTTP server (TinyLlama test)
After=network.target

[Service]
Type=simple
ExecStart=$LLAMA_DIR/build/bin/llama-server -m $MODEL_FILE --port $SERVICE_PORT --host 0.0.0.0
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

read -r -p "Enable and start llama-server.service now? (y/N) " ans
case "$ans" in
  y|Y)
    systemctl --user enable --now "$SERVICE_NAME"
    echo "[*] llama-server.service enabled and started."
    ;;
  *)
    echo "[*] Skipping enable/start. You can start it later with:"
    echo "    systemctl --user start $SERVICE_NAME"
    ;;
esac

echo "[*] Done. llama.cpp is installed in $LLAMA_DIR and a tiny model is at $MODEL_FILE."
