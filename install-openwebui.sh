#!/usr/bin/env bash
set -euo pipefail

### CONFIG
OWUI_DIR="$HOME/openwebui-env"
SERVICE_NAME="openwebui.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
PYTHON_BIN="python3"

echo "[*] Updating package lists..."
sudo apt update

echo "[*] Installing OpenWebUI dependencies (Python, build tools)..."
sudo apt install -y \
  $PYTHON_BIN python3-venv python3-pip \
  build-essential

### Create Python venv for OpenWebUI
if [[ ! -d "$OWUI_DIR" ]]; then
  echo "[*] Creating Python virtual environment at $OWUI_DIR..."
  $PYTHON_BIN -m venv "$OWUI_DIR"
else
  echo "[*] Virtualenv $OWUI_DIR already exists, reusing."
fi

# shellcheck disable=SC1090
source "$OWUI_DIR/bin/activate"

echo "[*] Upgrading pip inside venv..."
pip install --upgrade pip

echo "[*] Installing OpenWebUI into venv..."
pip install --upgrade open-webui

deactivate

### Create systemd service
echo "[*] Creating systemd service $SERVICE_NAME ..."

OWUI_USER="$USER"
OWUI_HOME="$HOME"

sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=OpenWebUI Server
After=network.target

[Service]
Type=simple
User=$OWUI_USER
WorkingDirectory=$OWUI_HOME
ExecStart=$OWUI_DIR/bin/open-webui serve
Restart=always
Environment=PATH=$OWUI_DIR/bin:/usr/local/bin:/usr/bin

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "[*] Enabling OpenWebUI service to start at boot..."
sudo systemctl enable "$SERVICE_NAME"

echo "[*] Starting OpenWebUI service..."
sudo systemctl start "$SERVICE_NAME"

echo "[*] Checking OpenWebUI service status..."
sudo systemctl status "$SERVICE_NAME" --no-pager || true

echo
echo "[*] If status is active (running), OpenWebUI should be available at:"
echo "    http://$(hostname -I | awk '{print $1}'):8080"
echo
echo "[*] You can manage the service with:"
echo "    sudo systemctl stop $SERVICE_NAME"
echo "    sudo systemctl start $SERVICE_NAME"
echo "    sudo systemctl restart $SERVICE_NAME"
